import Foundation

// Answering a permission prompt by reacting to the Slack DM that announced it.
//
// Why reactions and not buttons: Block Kit interactivity POSTs to a public HTTPS
// URL, which a desktop app hasn't got. Slack's answer is Socket Mode, whose docs
// say "when multiple connections are active, each payload may be sent to any of
// the connections" — and stack-nudge is built around one bot token shared across
// a team, so with several people connected a button click lands on somebody
// else's machine while the right one waits out its timeout. Polling reactions
// needs no inbound endpoint and cannot cross-talk: each install reads only its
// own DM, addressed by its own member id.
//
// The policy below is pure so the whole decision matrix is testable without a
// token; only `fetch` touches the network.
enum SlackResponder {

    enum Decision: Equatable { case allow, deny }

    // What the user has allowed Slack to do. Off by default — this is the one
    // feature that lets a phone execute something on the machine.
    enum Mode: String, Equatable, CaseIterable {
        case off, denyOnly, allowAndDeny

        var label: String {
            switch self {
            case .off:          return "Off"
            case .denyOnly:     return "Deny only"
            case .allowAndDeny: return "Allow + deny"
            }
        }
    }

    // Slack sends reaction names without colons. Several spellings map to the
    // same intent because the emoji picker offers more than one tick and cross,
    // and a user reaching for "the tick" should not have to guess which.
    static let allowNames: Set<String> = [
        "white_check_mark", "heavy_check_mark", "ballot_box_with_check", "+1",
    ]
    static let denyNames: Set<String> = [
        "x", "heavy_multiplication_x", "negative_squared_cross_mark", "-1",
    ]

    // MARK: - Policy

    // The decision a set of reactions represents, or nil for "no answer yet".
    //
    // `reactions` is the array Slack returns on a message: each entry has a
    // `name` and a `users` array of member ids. Only reactions carrying
    // `memberID` count — honouring "a reaction exists" would let anyone else in
    // the conversation answer, and would also let the bot answer itself if it
    // ever posted a reaction of its own.
    //
    // Deny beats allow whenever both are present. Someone who ticked and then
    // crossed is correcting themselves, and the safe reading of an ambiguous
    // instruction to run a command is: don't.
    static func decision(fromReactions reactions: [[String: Any]],
                         memberID: String,
                         mode: Mode,
                         detailOn: Bool) -> Decision? {
        guard mode != .off, !memberID.isEmpty else { return nil }

        var sawAllow = false
        var sawDeny = false
        for reaction in reactions {
            guard let name = reaction["name"] as? String,
                  let users = reaction["users"] as? [String],
                  users.contains(memberID)
            else { continue }
            // Skinned/aliased names arrive as "name::skin-tone-3".
            let base = name.components(separatedBy: "::").first ?? name
            if denyNames.contains(base) { sawDeny = true }
            if allowNames.contains(base) { sawAllow = true }
        }

        if sawDeny { return .deny }
        guard sawAllow, canAllow(mode: mode, detailOn: detailOn) else { return nil }
        return .allow
    }

    // Allowing from Slack needs the mode *and* message detail. With detail off
    // the DM reads only "Claude Code in stackone needs permission" — ticking
    // that approves a command you cannot see. Denying blind is safe, so deny is
    // never gated this way.
    static func canAllow(mode: Mode, detailOn: Bool) -> Bool {
        mode == .allowAndDeny && detailOn
    }

    // What the Settings row should read, so it never claims a capability the
    // detail switch is currently withholding.
    static func rowLabel(mode: Mode, detailOn: Bool) -> String {
        guard mode == .allowAndDeny, !detailOn else { return mode.label }
        return "Deny only (needs detail)"
    }

    // Whether a retiring watch earns an "expired" DM. Only when we actually
    // announced it (so there is a message the user may have reacted to), we
    // never resolved it ourselves, and it aged out rather than being answered:
    // retiring early means somebody dealt with it at the machine, which needs no
    // DM. `margin` absorbs the tick granularity — the ticker runs every 5s, so a
    // watch can be a few seconds past the cap before anyone notices.
    static func shouldAnnounceExpiry(age: TimeInterval,
                                     lifetime: TimeInterval,
                                     announced: Bool,
                                     resolvedByUs: Bool,
                                     margin: TimeInterval = 10) -> Bool {
        guard announced, !resolvedByUs else { return false }
        return age >= lifetime - margin
    }

    // MARK: - Wire format

    // Pull the reactions array out of a reactions.get payload. The shape is
    // {"ok":true,"type":"message","message":{"reactions":[…]}} and every layer
    // is optional in practice: a message nobody has touched has no `reactions`
    // key at all, which is "no answer yet" rather than an error.
    static func reactions(fromPayload json: [String: Any]) -> [[String: Any]]? {
        guard json["ok"] as? Bool == true else { return nil }
        guard let message = json["message"] as? [String: Any] else { return nil }
        return message["reactions"] as? [[String: Any]] ?? []
    }

    // Slack answers 200 with {"ok":false,"error":…}, and for a scope failure it
    // also names what it wanted: {"error":"missing_scope","needed":"reactions:read"}.
    // Preferring `needed` over a hardcoded string means this keeps telling the
    // truth if the endpoint's requirements ever change.
    static func explain(payload json: [String: Any]) -> String? {
        if json["ok"] as? Bool == true { return nil }
        let error = json["error"] as? String ?? "unknown"
        if error == "missing_scope", let needed = json["needed"] as? String {
            return "Slack bot token is missing \(needed) — add the scope, reinstall, then re-paste if the token changed"
        }
        return SlackNotifier.explain(error)
    }
}
