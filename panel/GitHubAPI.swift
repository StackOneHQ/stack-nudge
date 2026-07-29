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

    // Branches per batched request. GraphQL is charged by query complexity rather
    // than by request, so the ceiling here is about keeping any one failed
    // round-trip cheap to lose, not about cost.
    static let maxBranchesPerQuery = 25

    // Split a repo's branches into batch-sized groups, order preserved.
    static func branchChunks(_ branches: [String]) -> [[String]] {
        guard !branches.isEmpty else { return [] }
        return stride(from: 0, to: branches.count, by: maxBranchesPerQuery).map {
            Array(branches[$0..<min($0 + maxBranchesPerQuery, branches.count)])
        }
    }

    // One round-trip for many branches in the same repo: the same pullRequests
    // field aliased once per branch (b0, b1, …), each branch name passed as its
    // own variable so a name with quotes or braces can't break the query. Index
    // aliases rather than branch-derived ones because a GraphQL alias must match
    // /[_A-Za-z][_0-9A-Za-z]*/ and branch names routinely don't (`ENG-1/x`).
    static func batchQuery(owner: String, repo: String, branches: [String]) -> String {
        let selection = """
        nodes{number url state isDraft \
        commits(last:1){nodes{commit{statusCheckRollup{state}}}}}
        """
        let declarations = branches.indices.map { ",$b\($0):String!" }.joined()
        let fields = branches.indices.map { index in
            "b\(index):pullRequests(headRefName:$b\(index),first:1,"
                + "orderBy:{field:CREATED_AT,direction:DESC}){\(selection)}"
        }.joined()
        let graphql = "query($owner:String!,$repo:String!\(declarations))"
            + "{repository(owner:$owner,name:$repo){\(fields)}}"

        var variables: [String: Any] = ["owner": owner, "repo": repo]
        for (index, branch) in branches.enumerated() { variables["b\(index)"] = branch }
        let body: [String: Any] = ["query": graphql, "variables": variables]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Fetch every branch's newest PR through the injected runner
    // (`run(graphQLBody) -> json?`), batching to keep the round-trip count down.
    // Returns branch -> info for the branches that have a PR; a branch with none,
    // or a chunk whose request failed, is simply absent. Requests are issued
    // serially on purpose: GitHub's secondary rate limits penalise concurrency.
    static func pullRequests(owner: String, repo: String, branches: [String],
                             run: (String) -> String?) -> [String: PullRequestInfo] {
        var result: [String: PullRequestInfo] = [:]
        for chunk in branchChunks(branches) {
            guard let response = run(batchQuery(owner: owner, repo: repo, branches: chunk))
            else { continue }
            result.merge(parse(response, branches: chunk)) { _, new in new }
        }
        return result
    }

    // Unpack an aliased batch response. `branches` must be the same slice, in the
    // same order, that built the query: the b<index> aliases are what map a
    // response field back to its branch.
    static func parse(_ json: String, branches: [String]) -> [String: PullRequestInfo] {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        // GraphQL returns HTTP 200 with {"errors":[…]} on failures (unreadable
        // repo, rate limit, field errors). Surface them instead of silently
        // treating the response as "no PR found", but keep reading: GraphQL can
        // report an error for one field and still return data for the others, and
        // a batch covers up to maxBranchesPerQuery branches. Bailing out here
        // would throw away every good node because of one bad one, which the
        // per-branch queries this replaced could never do. A wholesale failure
        // (unreadable repo) nulls `repository` and falls out below anyway.
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            FileHandle.standardError.write(Data("stack-nudge: GitHub GraphQL errors: \(messages)\n".utf8))
        }
        guard let repository = (root["data"] as? [String: Any])?["repository"] as? [String: Any]
        else { return [:] }
        var result: [String: PullRequestInfo] = [:]
        for (index, branch) in branches.enumerated() {
            guard let node = firstPRNode(repository, alias: "b\(index)"),
                  let info = info(fromNode: node)
            else { continue }
            result[branch] = info
        }
        return result
    }

    static func info(fromNode node: [String: Any]) -> PullRequestInfo? {
        guard let number = node["number"] as? Int,
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

    private static func firstPRNode(_ repository: [String: Any], alias: String) -> [String: Any]? {
        let pullRequests = repository[alias] as? [String: Any]
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
