import Foundation

enum DocKind: Equatable {
    case doc, sheet, slides, form, drive

    var symbol: String {
        switch self {
        case .doc: return "doc.text"
        case .sheet: return "tablecells"
        case .slides: return "rectangle.on.rectangle"
        case .form: return "list.bullet.rectangle"
        case .drive: return "folder"
        }
    }
}

struct DocLink: Equatable {
    let kind: DocKind
    let url: String
}

struct MeetingLinks: Equatable {
    var docs: [DocLink] = []
    var others: [String] = []
    var isEmpty: Bool { docs.isEmpty && others.isEmpty }
}

// Pure text helpers for a meeting's notes: to plain text, and link extraction.
enum MeetingText {
    private static let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]
    private static let tag = try? NSRegularExpression(pattern: "<[^>]+>")
    private static let entity = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    private static let urlPattern = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\])]+"#, options: [.caseInsensitive])
    // Calendar chrome Google appends to every invite; never worth a button.
    private static let noiseHosts: Set<String> = ["calendar.google.com", "support.google.com", "accounts.google.com"]

    // Notes with markup removed, entities decoded and whitespace collapsed (paragraph breaks survive).
    static func plain(_ notes: String) -> String {
        var s = notes.replacingOccurrences(of: "\r", with: "")
        s = s.replacingOccurrences(of: "<br\\s*/?>|</(p|div|li|tr|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<li[^>]*>", with: "- ", options: [.regularExpression, .caseInsensitive])
        s = replace(tag, in: s) { _ in "" }
        s = decode(s)
        s = s.replacingOccurrences(of: "[ \t\u{00A0}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " ?\n ?", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        replace(entity, in: s) { name in
            if name.hasPrefix("#x"), let n = UInt32(name.dropFirst(2), radix: 16), let u = Unicode.Scalar(n) { return String(Character(u)) }
            if name.hasPrefix("#"), let n = UInt32(name.dropFirst()), let u = Unicode.Scalar(n) { return String(Character(u)) }
            return entities[name.lowercased()]
        }
    }

    // Docs and other links from the texts, in order and without duplicates; `joinUrl` and conferencing links are left out.
    static func links(in texts: [String?], joinUrl: String = "") -> MeetingLinks {
        var out = MeetingLinks()
        var seen = Set<String>()
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            let decoded = decode(text)
            let range = NSRange(decoded.startIndex..., in: decoded)
            for m in urlPattern?.matches(in: decoded, range: range) ?? [] {
                guard let r = Range(m.range, in: decoded) else { continue }
                let raw = String(decoded[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
                let url = unwrap(raw)
                guard url != joinUrl, !MeetingDiff.isJoinUrl(url), seen.insert(url).inserted,
                      let host = URL(string: url)?.host?.lowercased(), !noiseHosts.contains(host) else { continue }
                if let kind = docKind(url) { out.docs.append(DocLink(kind: kind, url: url)) } else { out.others.append(url) }
            }
        }
        return out
    }

    // The target of a google.com/url?q= tracking redirect; any other URL is returned unchanged.
    static func unwrap(_ url: String) -> String {
        guard let c = URLComponents(string: url), c.host?.lowercased().hasSuffix("google.com") == true, c.path == "/url",
              let target = c.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
              target.lowercased().hasPrefix("http") else { return url }
        return target
    }

    static func docKind(_ url: String) -> DocKind? {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return nil }
        if host == "docs.google.com" {
            let path = u.path
            if path.hasPrefix("/document") { return .doc }
            if path.hasPrefix("/spreadsheets") { return .sheet }
            if path.hasPrefix("/presentation") { return .slides }
            if path.hasPrefix("/forms") { return .form }
            return .doc
        }
        return host == "drive.google.com" ? .drive : nil
    }

    private static func replace(_ re: NSRegularExpression?, in s: String, with f: (String) -> String?) -> String {
        guard let re else { return s }
        var out = ""
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s) else { continue }
            out += s[last..<whole.lowerBound]
            let name = m.numberOfRanges > 1 ? Range(m.range(at: 1), in: s).map { String(s[$0]) } ?? "" : ""
            out += f(name) ?? String(s[whole])
            last = whole.upperBound
        }
        return out + s[last...]
    }
}
