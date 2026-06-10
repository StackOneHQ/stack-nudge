import Foundation
import Security

// GitHub OAuth device-flow response: the user enters `userCode` at
// `verificationURI`, we poll every `interval` seconds until `expiresIn` lapses.
struct DeviceCodeResponse: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let interval: Int
    let expiresIn: Int
}

// One poll outcome. `slowDown` carries GitHub's requested new interval.
enum DevicePollResult: Equatable {
    case token(String)
    case pending
    case slowDown(Int)
    case expired
    case denied
    case failed(String)
}

// In-panel GitHub sign-in via the OAuth device flow, plus Keychain token
// storage. No client secret (device flow needs none); the public client_id
// comes from STACKNUDGE_GITHUB_CLIENT_ID so it can be set without a rebuild.
// Networking is thin; the response parsers are pure for unit testing.
enum GitHubAuth {

    static let keychainService = "stack-nudge-github"
    static let keychainAccount = "oauth-token"
    static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!
    static let scope = "repo"

    // The app's public OAuth client_id — identical for every user (device flow
    // needs no secret), so it ships embedded like `gh` does and end users
    // configure nothing. Paste the StackNudge OAuth app's Client ID here.
    static let defaultClientID = "Ov23li9cyzCK1T0evP0a"

    // Embedded id, overridable by STACKNUDGE_GITHUB_CLIENT_ID (testing / a
    // different app, no rebuild). nil ⇒ not configured yet.
    static func clientID() -> String? {
        if let override = ConfigFile.read()["STACKNUDGE_GITHUB_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        {
            return override
        }
        return defaultClientID.isEmpty ? nil : defaultClientID
    }

    // MARK: - Keychain

    static func token() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(baseQuery(returningData: true) as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static func store(token: String) {
        SecItemDelete(baseQuery(returningData: false) as CFDictionary)  // replace any existing
        var add = baseQuery(returningData: false)
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func clearToken() {
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

    // MARK: - Device flow networking

    static func requestDeviceCode(
        clientID: String,
        session: URLSession = .shared,
        completion: @escaping (DeviceCodeResponse?) -> Void
    ) {
        let request = formPOST(deviceCodeURL, ["client_id": clientID, "scope": scope])
        session.dataTask(with: request) { data, _, _ in
            completion(data.flatMap(parseDeviceCode))
        }.resume()
    }

    static func poll(
        clientID: String,
        deviceCode: String,
        session: URLSession = .shared,
        completion: @escaping (DevicePollResult) -> Void
    ) {
        let request = formPOST(
            tokenURL,
            [
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
        session.dataTask(with: request) { data, _, _ in
            completion(data.map(parsePoll) ?? .failed("no response"))
        }.resume()
    }

    // MARK: - Pure parsers (testable)

    static func parseDeviceCode(_ data: Data) -> DeviceCodeResponse? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let deviceCode = json["device_code"] as? String,
            let userCode = json["user_code"] as? String,
            let verificationURI = json["verification_uri"] as? String
        else { return nil }
        return DeviceCodeResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            interval: json["interval"] as? Int ?? 5,
            expiresIn: json["expires_in"] as? Int ?? 900)
    }

    static func parsePoll(_ data: Data) -> DevicePollResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("bad json")
        }
        if let token = json["access_token"] as? String, !token.isEmpty { return .token(token) }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(json["interval"] as? Int ?? 5)
        case "expired_token": return .expired
        case "access_denied": return .denied
        case let other?: return .failed(other)
        case nil: return .failed("unknown")
        }
    }

    // MARK: - Helpers

    private static func formPOST(_ url: URL, _ params: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody =
            params
            .map {
                "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
        return request
    }
}
