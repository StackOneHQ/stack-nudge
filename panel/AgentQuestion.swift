import Foundation

// Whether an agent's turn ended on a question to you, read from the end of its
// last reply. The hook sends that tail on Stop (Claude Code and Codex both put
// the reply in `last_assistant_message`); an agent that sends nothing is done.
//
// Deliberately a heuristic on the closing line rather than a reading of the
// whole reply: an agent that asks something asks it last, and one that asked
// mid-reply and went on to finish the work is not waiting on you.
enum AgentQuestion {

    // Long enough for any closing question, short enough that the banner and
    // the row still read as one line or two.
    static let maxLength = 160

    // The question the reply ends on, ready to show in place of "Done", or nil
    // when the turn ended on anything else.
    static func question(in reply: String?) -> String? {
        guard let reply, let line = closingLine(of: reply) else { return nil }
        let text = strippedMarkup(line)
        guard text.hasSuffix("?") else { return nil }
        let sentence = lastSentence(of: text)
        guard sentence.count > 1 else { return nil }
        return truncated(sentence)
    }

    // The last line of prose. A trailing code block is skipped, since a reply
    // that asks "Shall I run this?" above the command still asks it.
    private static func closingLine(of reply: String) -> String? {
        var lines = reply.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while let last = lines.last {
            if last.isEmpty {
                lines.removeLast()
            } else if last.hasPrefix("```") {
                lines.removeLast()
                guard let opener = lines.lastIndex(where: { $0.hasPrefix("```") }) else { return nil }
                lines.removeSubrange(opener...)
            } else {
                return last
            }
        }
        return nil
    }

    // List markers, quote markers, emphasis and wrapping punctuation would hide
    // the closing "?" ("**Want me to raise it?**", "- Or wait for CI?)").
    private static func strippedMarkup(_ line: String) -> String {
        var text = line
        for marker in ["> ", "- ", "* ", "+ "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
        }
        if let range = text.range(of: #"^\d+[.)] "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let wrapping = CharacterSet(charactersIn: "*_`\"'“”‘’()[]").union(.whitespaces)
        return text.trimmingCharacters(in: wrapping)
    }

    // "Done, tests pass. Want me to raise the PR?" shows the question alone.
    private static func lastSentence(of text: String) -> String {
        let body = text.dropLast()
        guard let boundary = body.range(of: #"[.!?:]\s"#, options: [.regularExpression, .backwards])
        else { return text }
        return String(text[boundary.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func truncated(_ sentence: String) -> String {
        guard sentence.count > maxLength else { return sentence }
        return String(sentence.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
