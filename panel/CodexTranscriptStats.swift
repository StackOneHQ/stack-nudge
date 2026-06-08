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

    // Read the whole file and scan newest-first, same approach (and same
    // tens-of-MB caveat) as the Claude reader. The latest token_count gives
    // current context occupancy; the latest model-bearing line gives the
    // active model. Returns nil for unreadable files or rollouts with no
    // token_count event yet.
    static func read(path: String) -> TranscriptStats? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)

        var tokens: Int?
        var model: String?

        for line in lines.reversed() {
            if tokens != nil && model != nil { break }
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

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
        }

        guard let tokens else { return nil }
        return TranscriptStats(tokens: tokens, model: model)
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
