import Foundation

// Derives the Linear/Jira ticket key for a session from the git context the
// handoff already captures, using this monorepo's conventions (root CLAUDE.md):
//   branch  <TICKET-NUMBER>/<desc>     e.g. ENG-12142/fix-idp-logout
//   commit  <type>(<TICKET-NUMBER>):   e.g. fix(ENG-12142): clear cookie
// Pure string work — no git, no network.
enum TicketAttribution {

    // A key like ENG-123 / PROJ-87: an uppercase, letter-first alphanumeric
    // project prefix, a hyphen, then digits.
    private static let key = #"[A-Z][A-Z0-9]+-[0-9]+"#

    /// Resolve a ticket key, first match wins by reliability:
    ///   1. `branch` anchored at the start — the convention puts the key first,
    ///      so an anchored hit is trusted as-is (no prefix filtering).
    ///   2. otherwise, the first key found *anywhere* in branch / commit subject
    ///      / PR head-ref-or-title.
    /// `allowedPrefixes` (e.g. `["ENG"]`) guards the fuzzier any-match fallback
    /// against shapes like `UTF-8`; `nil` accepts any prefix.
    /// Returns the bare key (e.g. `"ENG-12142"`) or `nil` when nothing matches.
    static func ticket(branch: String?,
                       commitSubject: String? = nil,
                       pr: String? = nil,
                       allowedPrefixes: Set<String>? = nil) -> String? {
        if let branch, let anchored = firstMatch(branch, anchored: true) {
            return anchored
        }
        for source in [branch, commitSubject, pr].compactMap({ $0 }) {
            if let hit = firstMatch(source, anchored: false), passes(hit, allowedPrefixes) {
                return hit
            }
        }
        return nil
    }

    private static func firstMatch(_ string: String, anchored: Bool) -> String? {
        let pattern = anchored ? "^(?:\(key))" : "\\b(?:\(key))\\b"
        guard let range = string.range(of: pattern, options: .regularExpression) else { return nil }
        return String(string[range])
    }

    // The prefix is the segment before the hyphen ("ENG" in "ENG-12142").
    private static func passes(_ ticketKey: String, _ allowed: Set<String>?) -> Bool {
        guard let allowed else { return true }
        return allowed.contains(String(ticketKey.prefix { $0 != "-" }))
    }
}
