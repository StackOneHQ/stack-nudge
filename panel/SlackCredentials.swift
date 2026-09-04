import Foundation
import Security

// What a single clipboard paste turned out to contain. One paste can carry
// either half of the setup or both, so an org can keep one JSON entry in its
// password manager and onboarding is a single paste rather than a form.
enum PastedSecret: Equatable {
    case botToken(String)
    case memberID(String)
    case both(token: String, memberID: String)
    case unrecognised
}

// The Slack bot token, and the paste parsing that gets it here.
//
// Unlike the client ID this branch briefly embedded, a bot token is a real
// secret: anyone holding it can send messages as StackNudge to anyone in the
// workspace. So there is deliberately no default, no fallback baked into the
// binary, and nothing for a commit to leak — the only ways in are a paste or a
// config line that gets migrated and scrubbed.
enum SlackCredentials {

    static let keychainService = "stack-nudge-slack"
    static let keychainAccount = "bot-token"
    static let configTokenKey = "STACKNUDGE_SLACK_BOT_TOKEN"
    static let configMemberKey = "STACKNUDGE_SLACK_MEMBER_ID"

    // MARK: - Keychain

    static func botToken() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(returningData: true) as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    // Reports whether the Keychain actually took it. Callers must not treat a
    // store as done on faith: if the login keychain is locked SecItemAdd fails
    // with errSecInteractionNotAllowed, and a caller that then scrubbed the
    // plaintext source would leave the token existing nowhere at all.
    @discardableResult
    static func store(botToken: String) -> Bool {
        let previous = self.botToken()
        SecItemDelete(baseQuery(returningData: false) as CFDictionary)
        var add = baseQuery(returningData: false)
        add[kSecValueData as String] = Data(botToken.utf8)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            // The delete already happened, so a failed add would otherwise also
            // destroy a token that was working a moment ago. Put it back.
            if let previous {
                var restore = baseQuery(returningData: false)
                restore[kSecValueData as String] = Data(previous.utf8)
                SecItemAdd(restore as CFDictionary, nil)
            }
            return false
        }
        return true
    }

    static func clear() {
        SecItemDelete(baseQuery(returningData: false) as CFDictionary)
    }

    private static func baseQuery(returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    // MARK: - Provisioning

    // Move a token planted in the config file (MDM, dotfiles, a setup script)
    // into the Keychain and delete the line. Called at launch and idempotent, so
    // a redeployed config just re-migrates. The point is that plaintext exists
    // for the minutes between provisioning and first launch rather than forever
    // — the config file is shared with non-secret settings and is read by
    // anything the user runs.
    @discardableResult
    static func adoptFromConfig() -> Bool {
        let raw = ConfigFile.read()[configTokenKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return false }
        // Only scrub once the Keychain has it. Deleting the line on a failed
        // store would leave the token in neither place, with Settings reporting
        // a bland "not configured" and re-provisioning the only way back.
        guard store(botToken: raw) else { return false }
        ConfigFile.remove(key: configTokenKey)
        return true
    }

    // MARK: - Paste parsing (pure)

    // Slack member IDs are U… for ordinary accounts and W… on Enterprise Grid.
    private static let memberIDPattern = "^[UW][A-Z0-9]{6,}$"

    static func classify(_ raw: String) -> PastedSecret {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unrecognised }

        // A JSON object can carry both halves, which is what makes one-paste
        // setup possible.
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let token = (json["bot_token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let member = (json["member_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch (validBotToken(token), validMemberID(member)) {
            case let (token?, member?): return .both(token: token, memberID: member)
            case let (token?, nil):     return .botToken(token)
            case let (nil, member?):    return .memberID(member)
            case (nil, nil):            return .unrecognised
            }
        }

        if let token = validBotToken(trimmed) { return .botToken(token) }
        if let member = validMemberID(trimmed) { return .memberID(member) }
        return .unrecognised
    }

    // Only xoxb-. A user token (xoxp-) would be accepted by the Keychain and
    // then fail at send time with a scope error that says nothing useful — and
    // this whole rework exists because user tokens can't do the job, so
    // rejecting one here is the honest place to say so.
    static func validBotToken(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("xoxb-"), value.count > 10 else { return nil }
        return value
    }

    static func validMemberID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              value.range(of: memberIDPattern, options: .regularExpression) != nil
        else { return nil }
        return value
    }
}
