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
// The active model is stamped on `turn_context` lines. `session_meta` does NOT
// carry it — its payload has `model_provider`, not `model` — so a rollout with
// no `turn_context` line has no model to find anywhere. Verified across the 293
// rollouts on this machine: 40 of them resolve tokens with no model at all.
// `turn_context` is emitted when the turn context changes (model, effort,
// approval), not once per turn: a long interactive session has thousands, a
// short one has exactly one near the head, and a `codex exec` run has none.
enum CodexTranscriptReader {

    // How deep to keep looking for the model once the tokens are in hand.
    static let modelSearchBudget = 4 * 1024 * 1024

    // Scan the tail newest-first, same approach as the Claude reader. The
    // latest token_count gives current context occupancy; the latest
    // model-bearing line gives the active model. Returns nil for unreadable
    // files or rollouts with no token_count event yet.
    //
    // Only the tail is read (see TranscriptTail for why), and the search for
    // the model is capped separately and much lower than the search for the
    // tokens. The two are found at very different depths: measured over the
    // rollouts on this machine (293 at the time of measuring), tokens need at
    // most 28 KB, while the model runs to 2.5 MB at worst (p50 21 KB,
    // p99 1.9 MB) and on some rollouts is absent altogether. Past
    // `modelSearchBudget` the tokens alone are enough; the model is left nil
    // and Sessions omits the model clause.
    //
    // Three different counts live here and it is easy to quote the wrong one,
    // so all three, bucketed by what `scan` actually returns:
    //
    //   226  tokens + model      deepest 2.47 MB, median 0.02 MB
    //    40  tokens, no model    deepest 4.00 MB, median 2.40 MB   <- nil model
    //    27  no tokens at all    deepest 0.16 MB, median 0.02 MB
    //
    // 54 rollouts have no model anywhere; 40 of those still resolve tokens and
    // so return stats carrying a nil model, which is the number that matters
    // to PanelController.mergedModel; and of those 40, **15** are the ones the
    // budget actually stops — the other 25 reach the start of the file first.
    // 15 is the count that justifies this cap existing, and before it those 15
    // walked 8 MB on every read instead of 4.
    //
    // 4 MB clears every model depth observed with room to spare while halving
    // the worst case. Tighten it with fresh measurements rather than by
    // guessing — the only cost of it being too low is a missing model label.
    static func read(path: String) -> TranscriptStats? { scan(path: path).stats }

    // As `read`, but also reporting whether the file could be read at all —
    // TranscriptReader.cached needs the two apart to decide whether a nil is
    // safe to memoise.
    static func scan(path: String) -> (stats: TranscriptStats?, complete: Bool) {
        var tokens: Int?
        var model: String?

        var depth = 0

        let complete = TranscriptTail.scanLinesBackwards(path: path) { line in
            depth += line.count + 1
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { return stop(tokens: tokens, model: model, depth: depth) }

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
            return stop(tokens: tokens, model: model, depth: depth)
        }

        guard let tokens else { return (nil, complete) }
        return (TranscriptStats(tokens: tokens, model: model), complete)
    }

    // When to stop scanning: once the tokens are known, keep going only while
    // the model might still turn up within its budget. Pure and exposed so the
    // rule is testable without a rollout — it is the decision that governs how
    // much of a 24 MB file gets read.
    static func stop(tokens: Int?, model: String?, depth: Int) -> Bool {
        guard tokens != nil else { return false }
        return model != nil || depth > modelSearchBudget
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
