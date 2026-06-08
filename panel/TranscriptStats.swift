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
    // ~/.codex/sessions/.../rollout-*.jsonl and use a different JSONL schema
    // (token_count events rather than assistant-message usage blocks), so they
    // route to CodexTranscriptReader. Everything else is a Claude Code
    // transcript. Both return the same TranscriptStats shape so the Sessions
    // and Compact views render context usage identically across agents.
    static func read(path: String) -> TranscriptStats? {
        if path.contains("/.codex/")
            || (path as NSString).lastPathComponent.hasPrefix("rollout-") {
            return CodexTranscriptReader.read(path: path)
        }
        return readClaude(path: path)
    }

    // Read a Claude Code transcript at `path`, scan from the end for the most
    // recent assistant message with a usage block, and return its stats.
    // Returns nil for unreadable files, empty transcripts, or transcripts that
    // don't yet contain an assistant message.
    //
    // We read the whole file rather than tail-seeking — Claude Code
    // transcripts are typically a few MB even for long sessions, and
    // tail-seeking JSONL safely requires byte-by-byte reverse scanning
    // to find a newline boundary. If transcripts grow to tens of MB
    // in practice we can revisit.
    private static func readClaude(path: String) -> TranscriptStats? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8)
        else { return nil }

        // Iterate lines in reverse; first assistant entry with a usage
        // block wins. Reverse scan is cheap even on a few-thousand-line
        // transcript and means we don't pay to parse the whole file.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            // Claude Code transcript entries have type=assistant for model
            // turns; the usage block lives at .message.usage.
            guard (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage   = message["usage"] as? [String: Any]
            else { continue }
            let input   = usage["input_tokens"]                  as? Int ?? 0
            let cacheC  = usage["cache_creation_input_tokens"]   as? Int ?? 0
            let cacheR  = usage["cache_read_input_tokens"]       as? Int ?? 0
            let model   = message["model"] as? String
            return TranscriptStats(tokens: input + cacheC + cacheR, model: model)
        }
        return nil
    }
}
