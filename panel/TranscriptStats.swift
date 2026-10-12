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

        // st_mtimespec, as the kernel's own two integers.
        //
        // Not a Date and not a Double of seconds, because neither can hold a
        // nanosecond timestamp at this epoch: a Double has about 16 significant
        // digits and 10 go on the epoch seconds, leaving a resolution of
        // 120 ns (measured) — so two mtimes a nanosecond apart compare equal,
        // and only 1 of 6 sample nanosecond values round-trips exactly. Keeping
        // the integers makes the comparison exact with no float arithmetic in
        // it at all.
        //
        // Separately, and not the reason for this choice: `setAttributes`
        // truncates to the microsecond on the WRITE path, which is why the
        // tests freeze a whole-second constant instead of capturing and
        // restoring the file's own mtime. The read path is not lossy.
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int

        // Identity of the file itself, not of the name. (size, mtime) alone is
        // reproducible by an atomic replace — rename-over with the byte length
        // matching and the times preserved, which `cp -p`, `rsync -t`,
        // `touch -r` and a Time Machine restore all do. The device and inode
        // make such a replace visible, and close two related holes for free: a
        // path recycled for a different session's transcript, and an APFS
        // clone. Both come out of the fstat already being paid for.
        let device: UInt64
        let inode: UInt64
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

        guard isCacheable(stats: result.stats, complete: result.complete) else {
            return nil
        }

        cacheLock.lock()
        // Only when the table would actually grow. Clearing on an *update* at
        // the limit discards 511 live entries to make room for one that needs
        // none, forcing a cold parse of every active transcript on the next
        // poll — and a steady state of exactly `cacheLimit` live sessions would
        // do it on every single read.
        if cache[path] == nil && cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
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
    // Whether a parse result is worth remembering: only if the scan actually
    // ran to a conclusion.
    //
    // A result from a scan that failed part-way is not evidence about the
    // file's contents, in either direction, and nothing about such a file has
    // to change before the read would succeed — so caching it would make the
    // failure permanent. That holds for a partial success as much as for a nil:
    // the Codex reader gathers tokens and a model separately, so an I/O error
    // after the tokens but before the model returns real stats with a nil
    // model, and memoising those would freeze the missing model in place.
    // A nil from a *complete* read IS evidence, and heals on the next turn
    // because the file grows.
    //
    // Note that finding everything and stopping early counts as complete —
    // `scanLinesBackwards` returns true when the caller stops it — so this
    // rejects only genuine read failures, which is why it needs no clause
    // about `stats`.
    //
    // Reachable because the fingerprint and the read open the file separately:
    // the fingerprint can succeed and the read's own open then fail, which
    // under the per-session read fan-out means EMFILE. That window is hard to
    // force in a test, which is the reason this rule is a pure function rather
    // than a condition inline in `cached` — a mutation of it survived the suite
    // when it was inline.
    static func isCacheable(stats: TranscriptStats?, complete: Bool) -> Bool {
        complete
    }

    private static func fingerprint(path: String) -> Fingerprint? {
        guard let opened = TranscriptTail.openRegularFile(path) else { return nil }
        try? opened.handle.close()
        let info = opened.info
        return Fingerprint(size: Int(info.st_size),
                           mtimeSeconds: Int(info.st_mtimespec.tv_sec),
                           mtimeNanoseconds: Int(info.st_mtimespec.tv_nsec),
                           device: UInt64(info.st_dev),
                           inode: UInt64(info.st_ino))
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
