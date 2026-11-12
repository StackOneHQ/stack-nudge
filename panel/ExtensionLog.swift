import Foundation

// What an extension can put in app.log. Several host log lines repeat text the
// extension sent (a refused signal's name and value, an undeclared config key),
// and app.log is launchd's stderr file, which nothing rotates. Unchecked, a
// service under its message rate limit could still write a long line per
// message, around a gigabyte an hour, and with a newline in a value it could
// write lines that look like the app's own. So every line is cleaned and
// capped, and each extension gets a few lines a minute; past that its lines
// are counted, and the count is said with its next line once the minute is up.
struct ExtensionLog {
    static let maxLength = 300
    static let linesPerMinute = 10

    private struct Window {
        var start: TimeInterval
        var written = 0
        var dropped = 0
    }

    private var windows: [String: Window] = [:]

    // The lines to write for `message` from `id` at `now`: none while it is
    // over its allowance, and otherwise the line, after a count of what was
    // dropped if anything was.
    mutating func lines(for id: String, _ message: String, at now: TimeInterval) -> [String] {
        var window = windows[id] ?? Window(start: now)
        var out: [String] = []
        if now - window.start >= 60 || now < window.start {
            if window.dropped > 0 {
                let n = window.dropped
                out.append(Self.line(id, n == 1 ? "1 more line from it was dropped"
                                                : "\(n) more lines from it were dropped"))
            }
            window = Window(start: now)
        }
        if window.written < Self.linesPerMinute {
            window.written += 1
            out.append(Self.line(id, message))
        } else {
            window.dropped += 1
        }
        windows[id] = window
        return out
    }

    static func line(_ id: String, _ message: String) -> String {
        "stack-nudge: extension \"\(clean(id))\" \(clean(message))\n"
    }

    // One line of plain text: control and formatting characters (newlines,
    // escapes, bidi overrides) are written out as escapes rather than acted
    // on, and anything past maxLength is cut. Counted in scalars, not
    // Characters: a letter followed by any number of combining marks is one
    // Character, so a count of those would never cut it. An escape is added
    // whole or not at all.
    static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let piece: String.UnicodeScalarView
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                piece = (scalar == "\n" ? "\\n" : "\\u{\(String(scalar.value, radix: 16))}").unicodeScalars
            default:
                piece = String(scalar).unicodeScalars
            }
            guard out.count + piece.count <= maxLength else {
                return String(out) + "\u{2026}"
            }
            out.append(contentsOf: piece)
        }
        return String(out)
    }
}
