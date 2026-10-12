import Foundation

// Per-session statistics derived from a Claude Code JSONL transcript.
// `tokens` is the context window usage at the last assistant turn:
// input_tokens + cache_creation_input_tokens + cache_read_input_tokens.
// Output tokens are excluded — they belong to the next turn's prompt.
// `model` is the assistant-reported model name (e.g.
// "claude-sonnet-4-7-20250606"); used by ModelLimits to look up the
// context limit, or shown verbatim when the model isn't recognised.
struct TranscriptStats: Equatable {
    let tokens: Int
    let model: String?
}

// Stable per-PID handle to an agent's transcript, learned from a hook event.
// Claude exposes a per-pid session sidecar so its sessions resolve stats
// directly; agents without one (Codex) have no such anchor, so we cache the
// (session id, transcript path) the first hook event carries, keyed by the
// agent PID. The Sessions/Compact views resolve stats through this — which
// survives EventStore pruning and panel navigation — and the poll refresh
// re-reads `path` to keep stats live.
struct TranscriptRef: Equatable {
    let sessionID: String
    let path: String
}

enum TranscriptReader {

    // Dispatch by transcript path. Codex rollout files live under
    // ~/.codex/sessions/.../rollout-*.jsonl and pi sessions under
    // ~/.pi/agent/sessions/, each using a different JSONL schema from Claude's
    // (token_count events / camelCase-wrapped messages rather than top-level
    // assistant-message usage blocks), so they route to their own readers.
    // Everything else is a Claude Code transcript. All return the same
    // TranscriptStats shape so the Sessions and Compact views render context
    // usage identically across agents.
    //
    // Results are memoised on (size, mtime) — see `cached`. Every caller comes
    // through here, so all three agents get the skip.
    static func read(path: String) -> TranscriptStats? {
        cached(path: path) { parse(path: $0) }
    }

    // `complete` is false when the file could not be opened or read at all, as
    // opposed to being read and found to hold no usage block. The distinction
    // decides whether a nil is cacheable — see `cached`.
    private static func parse(path: String) -> (stats: TranscriptStats?, complete: Bool) {
        if path.contains("/.pi/agent/sessions/") {
            return PiTranscriptReader.scan(path: path)
        }
        if path.contains("/.codex/")
            || (path as NSString).lastPathComponent.hasPrefix("rollout-") {
            return CodexTranscriptReader.scan(path: path)
        }
        return scanClaude(path: path)
    }

    // MARK: - Unchanged-file memoisation

    private struct Fingerprint: Equatable {
        let size: Int
        // Seconds since the epoch, from fstat's nanosecond-resolution
        // st_mtimespec. Kept as a Double rather than a Date so the comparison
        // is against the value the kernel reported, with no conversion in
        // between.
        let mtime: Double
    }

    private static let cacheLock = NSLock()
    private static var cache: [String: (print: Fingerprint, stats: TranscriptStats?)] = [:]

    // One entry per transcript path is tiny, but a long-lived panel sees a new
    // path per session, so cap the table rather than let it creep. Transcripts
    // are append-only: a stale entry can only be a path that stopped changing,
    // which is exactly what is cheapest to re-read, so clearing wholesale on
    // overflow costs one read per live session and needs no LRU bookkeeping.
    private static let cacheLimit = 512

    // The refresh poll re-reads every active session's transcript to keep stats
    // live, but a transcript only changes when its agent writes a turn. Skip the
    // read when neither size nor mtime has moved and replay the previous answer
    // — replay rather than skip, because the callers rely on a refresh to
    // repopulate stats after EventStore pruning or panel navigation.
    //
    // A nil result is memoised too: a transcript with no assistant turn yet is
    // the case most likely to be polled repeatedly to no effect.
    private static func cached(path: String,
                               _ parse: (String) -> (stats: TranscriptStats?, complete: Bool))
        -> TranscriptStats? {
        guard let current = fingerprint(path: path) else {
            // Cannot open it: fall through to the parse, which will fail the
            // same way, rather than serve a hit against a fingerprint we could
            // not confirm.
            return parse(path).stats
        }

        cacheLock.lock()
        let hit = cache[path]
        cacheLock.unlock()
        if let hit, hit.print == current { return hit.stats }

        // Fingerprint is taken BEFORE the parse deliberately. A transcript
        // appended to mid-parse then leaves a cached entry whose fingerprint
        // already looks stale, so the next poll re-reads. Taking it afterwards
        // would pair the new fingerprint with the older content and stick.
        let result = parse(path)

        // A nil from a read that never got off the ground is not evidence about
        // the file's contents, and nothing about such a file has to change
        // before the read would succeed — so caching it would make the failure
        // permanent. A nil from a complete read is evidence, and heals on the
        // next turn because the file grows.
        guard result.stats != nil || result.complete else { return nil }

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[path] = (current, result.stats)
        cacheLock.unlock()
        return result.stats
    }

    // Fingerprint the file we would actually read, by opening it and stat'ing
    // the descriptor.
    //
    // `FileManager.attributesOfItem` cannot be used here: it does not follow
    // symlinks, while the reader (FileHandle) does. A symlink's size is the
    // length of its target path and its mtime is when the link was made —
    // neither moves while the agent appends to the target, so a symlinked
    // transcript path would be fingerprinted once and then served from the
    // cache forever, freezing the session's token count at its first reading.
    // `~/.claude/projects` relocated to another volume or checked into a
    // dotfiles repo is exactly that shape.
    //
    // Opening also makes readability part of the fingerprint's precondition: a
    // file that stats but cannot be opened (mode 000, another uid, a dangling
    // symlink, EMFILE under fan-out) yields nil here rather than a fingerprint
    // that will never move again. mode changes touch ctime only, so size and
    // mtime are identical either side of a chmod — a nil memoised against that
    // fingerprint could never heal.
    private static func fingerprint(path: String) -> Fingerprint? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let mtime = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return Fingerprint(size: Int(info.st_size), mtime: mtime)
    }

    // Tests share process state with each other; drop the table so one test's
    // fixture cannot answer another's read.
    static func resetCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Claude Code transcripts

    // Read a Claude Code transcript at `path`, scanning from the end for the
    // most recent assistant message with a usage block. Returns nil for
    // unreadable files, empty transcripts, or transcripts that don't yet
    // contain an assistant message.
    //
    // Only the tail is read. This used to load the whole file and decode it to
    // a String, which cost a full in-memory copy — 249 MB resident and 3.07s of
    // CPU on a 241 MB transcript, per active session, per refresh. Sessions run
    // for days now and transcripts reach hundreds of MB, so that is the budget
    // TranscriptTail exists to avoid.
    private static func scanClaude(path: String) -> (stats: TranscriptStats?, complete: Bool) {
        var found: TranscriptStats?
        let complete = TranscriptTail.scanLinesBackwards(path: path) { line in
            // Claude Code transcript entries have type=assistant for model
            // turns; the usage block lives at .message.usage.
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage   = message["usage"] as? [String: Any]
            else { return false }
            let input   = usage["input_tokens"]                  as? Int ?? 0
            let cacheC  = usage["cache_creation_input_tokens"]   as? Int ?? 0
            let cacheR  = usage["cache_read_input_tokens"]       as? Int ?? 0
            found = TranscriptStats(tokens: input + cacheC + cacheR,
                                    model: message["model"] as? String)
            return true
        }
        return (found, complete)
    }
}
