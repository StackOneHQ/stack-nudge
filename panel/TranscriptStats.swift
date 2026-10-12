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

    private static func parse(path: String) -> TranscriptStats? {
        if path.contains("/.pi/agent/sessions/") {
            return PiTranscriptReader.read(path: path)
        }
        if path.contains("/.codex/")
            || (path as NSString).lastPathComponent.hasPrefix("rollout-") {
            return CodexTranscriptReader.read(path: path)
        }
        return readClaude(path: path)
    }

    // MARK: - Unchanged-file memoisation

    private struct Fingerprint: Equatable {
        let size: Int
        let mtime: Date
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
                               _ parse: (String) -> TranscriptStats?) -> TranscriptStats? {
        guard let current = fingerprint(path: path) else {
            // Cannot stat it: fall through to the parse, which will fail the
            // same way the stat did, rather than serve a possibly stale hit.
            return parse(path)
        }

        cacheLock.lock()
        let hit = cache[path]
        cacheLock.unlock()
        if let hit, hit.print == current { return hit.stats }

        let stats = parse(path)

        cacheLock.lock()
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[path] = (current, stats)
        cacheLock.unlock()
        return stats
    }

    private static func fingerprint(path: String) -> Fingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int,
              let mtime = attrs[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(size: size, mtime: mtime)
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
    private static func readClaude(path: String) -> TranscriptStats? {
        var found: TranscriptStats?
        TranscriptTail.scanLinesBackwards(path: path) { line in
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
        return found
    }
}
