import Foundation

// PR lifecycle as GitHub reports it. `merged` is authoritative for "did it
// ship?" — it closes the squash-merge gap the local OutcomeWatcher can't see.
enum PRState: String, Equatable {
    case open = "OPEN"
    case closed = "CLOSED"
    case merged = "MERGED"
}

// Collapsed CI signal for a PR (from the GraphQL statusCheckRollup).
enum CIStatus: String, Equatable {
    case pending
    case passing
    case failing
}

struct PullRequestInfo: Equatable {
    let number: Int
    let url: String
    let state: PRState
    let isDraft: Bool
    let ci: CIStatus?   // nil when the PR has no checks
}

// gh-free GitHub reads: query a branch's newest PR (+ CI rollup) via the GraphQL
// API using our own token (see GitHubAuth). GraphQL `headRefName` matches by
// branch name regardless of which fork the head lives on, and statusCheckRollup
// gives the CI state in the same round-trip — both awkward over REST. The HTTP
// runner is injected so the query building + response parsing stay unit-testable.
enum GitHubAPI {

    static let graphQLEndpoint = URL(string: "https://api.github.com/graphql")!

    // owner/repo from a remote URL — https (`https://github.com/o/r.git`) or
    // ssh (`git@github.com:o/r.git`). nil when it isn't a github.com remote.
    static func repoSlug(fromRemoteURL url: String) -> (owner: String, repo: String)? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let marker = trimmed.range(of: "github.com") else { return nil }
        var path = String(trimmed[marker.upperBound...])
        path = String(path.drop(while: { $0 == ":" || $0 == "/" }))   // strip ssh ':' / https '/'
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    // GraphQL request body (JSON string) for the newest PR on `branch`.
    static func query(owner: String, repo: String, branch: String) -> String {
        let graphql = """
        query($owner:String!,$repo:String!,$branch:String!){\
        repository(owner:$owner,name:$repo){\
        pullRequests(headRefName:$branch,first:1,orderBy:{field:CREATED_AT,direction:DESC}){\
        nodes{number url state isDraft \
        commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}
        """
        let body: [String: Any] = [
            "query": graphql,
            "variables": ["owner": owner, "repo": repo, "branch": branch],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Fetch a branch's PR via the injected runner (`run(graphQLBody) -> json?`).
    static func pullRequest(owner: String, repo: String, branch: String,
                            run: (String) -> String?) -> PullRequestInfo? {
        guard let response = run(query(owner: owner, repo: repo, branch: branch)) else { return nil }
        return parse(response)
    }

    static func parse(_ json: String) -> PullRequestInfo? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // GraphQL returns HTTP 200 with {"data":null,"errors":[…]} on failures
        // (bad token, rate limit, field errors). Surface them instead of
        // silently treating the response as "no PR found".
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            FileHandle.standardError.write(Data("stack-nudge: GitHub GraphQL errors: \(messages)\n".utf8))
            return nil
        }
        guard let node = firstPRNode(root),
              let number = node["number"] as? Int,
              let url = node["url"] as? String,
              let stateRaw = node["state"] as? String,
              let state = PRState(rawValue: stateRaw)
        else { return nil }
        return PullRequestInfo(
            number: number,
            url: url,
            state: state,
            isDraft: node["isDraft"] as? Bool ?? false,
            ci: ciStatus(fromNode: node))
    }

    private static func firstPRNode(_ root: [String: Any]) -> [String: Any]? {
        let data = root["data"] as? [String: Any]
        let repository = data?["repository"] as? [String: Any]
        let pullRequests = repository?["pullRequests"] as? [String: Any]
        let nodes = pullRequests?["nodes"] as? [[String: Any]]
        return nodes?.first
    }

    // statusCheckRollup.state on the PR's latest commit → one CI signal.
    static func ciStatus(fromNode node: [String: Any]) -> CIStatus? {
        guard let commitNodes = (node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]],
              let commit = commitNodes.first?["commit"] as? [String: Any],
              let rollup = commit["statusCheckRollup"] as? [String: Any],
              let state = (rollup["state"] as? String)?.uppercased()
        else { return nil }
        switch state {
        case "SUCCESS":            return .passing
        case "FAILURE", "ERROR":   return .failing
        case "PENDING", "EXPECTED": return .pending
        default:                   return nil
        }
    }
}
