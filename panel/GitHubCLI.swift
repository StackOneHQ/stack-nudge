import Foundation

// GitHub requests through the gh CLI, when it is installed and logged in. gh
// holds the credential and sends it; stack-nudge only passes the query and
// reads the response, so it never sees the user's gh token. It matters for an
// org that restricts third-party OAuth apps: the app's own device-flow token
// can't see the org's private repos until an owner approves the app, while a
// gh login usually can.
enum GitHubCLI {

    private static let lock = NSLock()
    private static var loggedIn: (value: Bool, at: Date)?

    // `gh auth status` exits 0 when logged in to github.com. Cached for a
    // minute: it is asked before every poll.
    static func isLoggedIn(now: Date = Date()) -> Bool {
        lock.lock()
        if let cached = loggedIn, now.timeIntervalSince(cached.at) < 60 {
            lock.unlock()
            return cached.value
        }
        lock.unlock()
        let value = ProcessOutput.gh().flatMap {
            ProcessOutput.run($0, ["auth", "status", "--hostname", "github.com"], timeout: 10)
        }?.status == 0
        lock.lock()
        loggedIn = (value, now)
        lock.unlock()
        return value
    }

    // A GraphQL request body ({"query": ..., "variables": {...}}) as
    // `gh api graphql` arguments: -f for strings, -F for numbers and booleans.
    static func graphQLArguments(body: String) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let query = object["query"] as? String
        else { return nil }
        // github.com always: gh otherwise takes its host from GH_HOST, which
        // the app inherits from whatever launched it.
        var args = ["api", "graphql", "--hostname", "github.com", "-f", "query=\(query)"]
        let variables = object["variables"] as? [String: Any] ?? [:]
        for key in variables.keys.sorted() {
            switch variables[key] {
            case let string as String:  args += ["-f", "\(key)=\(string)"]
            case let number as NSNumber: args += ["-F", "\(key)=\(number)"]
            // Omitted: GraphQL reads a missing nullable variable as null, and
            // gh has no flag for an explicit one (a first page's cursor).
            case is NSNull: continue
            default: return nil   // no query here passes anything else
            }
        }
        return args
    }

    // The response JSON, errors included (gh exits non-zero on GraphQL errors
    // but still prints the body, which the parsers report). nil when gh is
    // missing or printed nothing.
    static func graphQL(body: String) -> String? {
        guard let gh = ProcessOutput.gh(), let args = graphQLArguments(body: body),
              let completion = ProcessOutput.run(gh, args, timeout: 30),
              !completion.truncated, !completion.output.isEmpty
        else { return nil }
        return completion.output
    }

    // A REST GET (`gh api <path>`), for endpoints GraphQL lacks.
    static func get(path: String) -> String? {
        guard let gh = ProcessOutput.gh(),
              let completion = ProcessOutput.run(gh, ["api", path], timeout: 30),
              completion.status == 0, !completion.truncated
        else { return nil }
        return completion.output
    }
}
