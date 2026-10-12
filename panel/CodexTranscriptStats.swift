import Foundation

// Reads a Codex CLI rollout JSONL (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl)
// and returns the same TranscriptStats the Claude reader produces, so the
// Sessions/Compact UI shows context usage for Codex sessions identically.
//
// Codex differs from Claude Code's transcript in three ways that matter here:
//   • Usage lives in `event_msg` lines whose payload.type == "token_count",
//     not in assistant messages. `last_token_usage` is the latest turn's
//     snapshot; `total_token_usage` is cumulative across the whole session
//     (useful for cost, wrong for "how full is the window now").
//   • Context-window occupancy is `total_tokens - reasoning_output_tokens`,
//     mirroring Codex's own TokenUsage::tokens_in_context_window() — reasoning
//     tokens don't persist in the window between turns.
//   • `input_tokens` already includes `cached_input_tokens` (cached is a
//     subset, not additive), so we must not sum them — the mistake that
//     produces the well-known token-inflation bugs in third-party parsers.
//
// The active model is stamped on `turn_context` lines (and `session_meta`).
enum CodexTranscriptReader {

    // Scan the tail newest-first, same approach as the Claude reader. The
    // latest token_count gives current context occupancy; the latest
    // model-bearing line gives the active model. Returns nil for unreadable
    // files or rollouts with no token_count event yet.
    //
    // Only the tail is read (see TranscriptTail for why). Codex stamps the
    // model on a turn_context line every turn, so the tail carries it; a
    // rollout long enough to exhaust the scan budget with the model named
    // *only* in its opening session_meta resolves tokens without a model,
    // which renders as the model shown verbatim rather than as no stats.
    static func read(path: String) -> TranscriptStats? { scan(path: path).stats }

    // As `read`, but also reporting whether the file could be read at all —
    // TranscriptReader.cached needs the two apart to decide whether a nil is
    // safe to memoise.
    static func scan(path: String) -> (stats: TranscriptStats?, complete: Bool) {
        var tokens: Int?
        var model: String?

        let complete = TranscriptTail.scanLinesBackwards(path: path) { line in
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return false }

            let payload = obj["payload"] as? [String: Any]
            let payloadType = (payload?["type"] as? String) ?? (obj["type"] as? String)

            if tokens == nil,
               payloadType == "token_count",
               let info = payload?["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any] {
                let total = intValue(last["total_tokens"])
                let reasoning = intValue(last["reasoning_output_tokens"])
                if total > 0 { tokens = max(0, total - reasoning) }
            }

            if model == nil {
                model = modelFrom(obj: obj, payload: payload)
            }
            return tokens != nil && model != nil
        }

        guard let tokens else { return (nil, complete) }
        return (TranscriptStats(tokens: tokens, model: model), complete)
    }

    // Locate the rollout file for a Codex session id. Codex's Stop hook may send
    // `transcript_path: null`, but the rollout filename embeds the session id
    // (`rollout-<timestamp>-<session_id>.jsonl` under
    // ~/.codex/sessions/YYYY/MM/DD/), so we can derive the path and still read
    // token/model stats. Walks the date tree newest-first (the just-stopped
    // session's rollout is recent) and returns the first match. Disk I/O — call
    // off the main thread.
    static func rolloutPath(forSessionID sessionID: String,
                            root: String = "\(NSHomeDirectory())/.codex/sessions") -> String? {
        guard !sessionID.isEmpty else { return nil }
        let fileManager = FileManager.default
        let suffix = "-\(sessionID).jsonl"
        func namesDescending(_ path: String) -> [String] {
            ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >)
        }
        for year in namesDescending(root) {
            let yearPath = "\(root)/\(year)"
            for month in namesDescending(yearPath) {
                let monthPath = "\(yearPath)/\(month)"
                for day in namesDescending(monthPath) {
                    let dayPath = "\(monthPath)/\(day)"
                    if let match = namesDescending(dayPath).first(where: { $0.hasSuffix(suffix) }) {
                        return "\(dayPath)/\(match)"
                    }
                }
            }
        }
        return nil
    }

    // Codex stamps the active model on turn_context lines; session_meta carries
    // it for the session as a whole. Nesting has shifted across Codex versions,
    // so probe the few known shapes defensively and ignore anything else.
    private static func modelFrom(obj: [String: Any], payload: [String: Any]?) -> String? {
        if let model = payload?["model"] as? String, !model.isEmpty { return model }
        if let turnContext = payload?["turn_context"] as? [String: Any],
           let model = turnContext["model"] as? String, !model.isEmpty { return model }
        if let model = obj["model"] as? String, !model.isEmpty { return model }
        return nil
    }

    // Rollout numbers are emitted as JSON integers, but decode defensively in
    // case a writer or version serialises them as doubles.
    private static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let double = value as? Double { return Int(double) }
        return 0
    }
}
