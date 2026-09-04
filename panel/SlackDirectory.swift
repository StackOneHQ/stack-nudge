import Foundation

enum SlackLookup: Equatable {
    case found(id: String, label: String)
    // Slack knows the address but nobody matches, or we had no address to try.
    case notFound
    // The bot token lacks users:read.email — worth distinguishing from
    // "you aren't in this workspace", because the fix is completely different.
    case missingScope
    case failed(String)
}

// Works out which Slack account to DM, so setup is a paste rather than a
// scavenger hunt for a member ID.
//
// The guess comes from `git config user.email`, which on a developer's machine
// is nearly always their work address. It is only ever a *suggestion*: a wrong
// id would send your prompts to a colleague, so the Settings row shows what was
// found and stays overridable by pasting an id directly.
enum SlackDirectory {

    static let lookupURL = "https://slack.com/api/users.lookupByEmail"

    // Global git config rather than the repo's — the panel isn't running inside
    // any particular checkout, and a per-repo override would be the wrong
    // identity anyway. Reuses the helper Panel.swift already uses for git.
    static func gitEmail() -> String? {
        let raw = ProcessOutput.read("/usr/bin/git", ["config", "--global", "--get", "user.email"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.contains("@") ? raw : nil
    }

    static func lookup(token: String,
                       email: String,
                       session: URLSession = .shared,
                       completion: @escaping (SlackLookup) -> Void) {
        guard var components = URLComponents(string: lookupURL) else {
            completion(.failed("bad url"))
            return
        }
        components.queryItems = [URLQueryItem(name: "email", value: email)]
        guard let url = components.url else {
            completion(.failed("bad url"))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, _, error in
            guard let data else {
                completion(.failed(error?.localizedDescription ?? "no response"))
                return
            }
            completion(parse(data))
        }.resume()
    }

    // MARK: - Pure

    // Slack answers 200 with {"ok": false, ...} on failure, so the status code
    // alone would read every error as success.
    static func parse(_ data: Data) -> SlackLookup {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed("bad json")
        }
        guard json["ok"] as? Bool == true else {
            switch json["error"] as? String {
            case "users_not_found":            return .notFound
            case "missing_scope", "not_allowed_token_type": return .missingScope
            case let other?:                   return .failed(other)
            case nil:                          return .failed("unknown")
            }
        }
        guard let user = json["user"] as? [String: Any],
              let id = user["id"] as? String, !id.isEmpty
        else { return .failed("no user in response") }

        // Prefer what a human would recognise, falling back through Slack's
        // increasingly technical name fields.
        let profile = user["profile"] as? [String: Any]
        let candidates: [String?] = [
            profile?["display_name"] as? String,
            profile?["real_name"] as? String,
            user["real_name"] as? String,
            user["name"] as? String,
        ]
        let label = candidates.compactMap { $0 }.first { !$0.isEmpty } ?? id
        return .found(id: id, label: label)
    }
}
