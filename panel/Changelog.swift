import Foundation

// One released version's entry, lifted out of the bundled CHANGELOG.md.
struct ChangelogEntry: Equatable {
    let version: String
    let date: String?
    // Markdown, ready for MarkdownNotesView. The `## [version]` heading is not
    // part of it — About draws its own, so the body starts at "### Features".
    let body: String
}

// Reads the CHANGELOG.md that build.sh copies into the app bundle.
//
// Bundled rather than fetched: the About tab describes the build the user is
// running, and a network round-trip would give it a spinner, a failure state
// and a rate limit for something that is already on disk and can never be out
// of step with the binary beside it. The updater still fetches notes for
// versions the user does not have yet — that is the case bundling can't serve.
enum Changelog {

    static func bundledSource() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    // The entry for `version`, or the newest entry when there is no section for
    // it. A locally built panel reports a version that was never released, and
    // showing the most recent released notes beats showing nothing.
    static func entry(for version: String, in source: String) -> ChangelogEntry? {
        let all = entries(in: source)
        return all.first { $0.version == version } ?? all.first
    }

    // Every `## [x.y.z](...) (date)` section, newest first — release-please
    // writes them in that order and we don't re-sort, so a hand-edited file
    // renders in the order its author chose.
    static func entries(in source: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var current: (version: String, date: String?)?
        var body: [String] = []

        func flush() {
            guard let current else { return }
            entries.append(ChangelogEntry(
                version: current.version,
                date: current.date,
                body: cleaned(body)))
        }

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            if let heading = parseVersionHeading(raw) {
                flush()
                current = heading
                body = []
            } else if current != nil {
                body.append(raw)
            }
        }
        flush()
        return entries
    }

    // `## [1.34.1](compare-url) (2026-09-17)` or a plain `## 1.34.1 (2026-09-17)`.
    //
    // The prefix carries its own trailing space, which is what excludes `###`
    // ("Bug Fixes" and friends): those are sections within an entry, and taking
    // one for a version would cut the entry in half. The leading-digit check is
    // what excludes `## Unreleased`.
    private static func parseVersionHeading(_ line: String) -> (version: String, date: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { return nil }
        let rest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)

        let version: String
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            version = String(rest[rest.index(after: rest.startIndex)..<close])
        } else {
            version = String(rest.prefix { !$0.isWhitespace })
        }
        guard !version.isEmpty, version.first?.isNumber == true else { return nil }

        return (version, trailingDate(in: rest))
    }

    // The `(YYYY-MM-DD)` release-please appends. Absent on a hand-written entry,
    // so About has to render without one.
    private static func trailingDate(in heading: String) -> String? {
        guard let open = heading.lastIndex(of: "("),
              let close = heading.lastIndex(of: ")"),
              open < close
        else { return nil }
        let candidate = String(heading[heading.index(after: open)..<close])
        let parts = candidate.split(separator: "-")
        guard parts.count == 3, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return candidate
    }

    // Trim the blank lines release-please leaves around each section, and drop
    // the trailing commit-sha link from every bullet. The PR link stays — it is
    // the one a reader follows — but both together wrap a one-line bullet onto
    // three in a pane this narrow.
    private static func cleaned(_ lines: [String]) -> String {
        var kept = lines.map(stripCommitLink)
        while kept.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeFirst() }
        while kept.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { kept.removeLast() }
        return kept.joined(separator: "\n")
    }

    private static func stripCommitLink(_ line: String) -> String {
        // ` ([5b99f59](https://github.com/.../commit/5b99f59...))` at end of line.
        let pattern = #"\s*\(\[[0-9a-f]{7,40}\]\([^)]*/commit/[^)]*\)\)\s*$"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return line }
        return String(line[line.startIndex..<range.lowerBound])
    }
}
