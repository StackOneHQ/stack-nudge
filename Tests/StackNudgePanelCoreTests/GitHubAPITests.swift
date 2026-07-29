import XCTest

@testable import StackNudgePanelCore

// GitHubAPI builds the GraphQL PR query and parses the response (PR state +
// CI rollup), plus owner/repo extraction from a remote URL. Pure; no network.
final class GitHubAPITests: XCTestCase {

    func test_repoSlug_https() {
        let actual = GitHubAPI.repoSlug(fromRemoteURL: "https://github.com/StackOneHQ/stack-nudge.git")
        XCTAssertEqual(actual?.owner, "StackOneHQ")
        XCTAssertEqual(actual?.repo, "stack-nudge")
    }

    func test_repoSlug_ssh() {
        let actual = GitHubAPI.repoSlug(fromRemoteURL: "git@github.com:StackOneHQ/stack-nudge.git")
        XCTAssertEqual(actual?.owner, "StackOneHQ")
        XCTAssertEqual(actual?.repo, "stack-nudge")
    }

    func test_repoSlug_noGitSuffix() {
        let actual = GitHubAPI.repoSlug(fromRemoteURL: "https://github.com/o/r")
        XCTAssertEqual(actual?.owner, "o")
        XCTAssertEqual(actual?.repo, "r")
    }

    func test_repoSlug_nonGitHub_isNil() {
        XCTAssertNil(GitHubAPI.repoSlug(fromRemoteURL: "https://gitlab.com/o/r.git"))
    }

    func test_batchQuery_carriesEachBranchAsItsOwnVariable() {
        let actual = GitHubAPI.batchQuery(owner: "o", repo: "r", branches: ["ENG-1/x", "ENG-2/y"])
        XCTAssertTrue(actual.contains("headRefName"))
        XCTAssertTrue(actual.contains("statusCheckRollup"))
        // One alias + one declared variable per branch.
        XCTAssertTrue(actual.contains("b0:pullRequests(headRefName:$b0"))
        XCTAssertTrue(actual.contains("b1:pullRequests(headRefName:$b1"))
        XCTAssertTrue(actual.contains("$b0:String!"))
        XCTAssertTrue(actual.contains("$b1:String!"))
        // Branch names travel as variables, never interpolated into the query, so
        // a name that isn't a legal GraphQL alias (or contains a quote) is safe.
        XCTAssertTrue(actual.contains(#""b0":"ENG-1\/x""#) || actual.contains(#""b0":"ENG-1/x""#))
        XCTAssertTrue(actual.contains(#""b1":"ENG-2\/y""#) || actual.contains(#""b1":"ENG-2/y""#))
        XCTAssertFalse(actual.contains("b2:"))
    }

    func test_branchChunks_splitsAtTheBatchCeiling_preservingOrder() {
        let branches = (0..<(GitHubAPI.maxBranchesPerQuery + 3)).map { "b/\($0)" }
        let chunks = GitHubAPI.branchChunks(branches)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.first?.count, GitHubAPI.maxBranchesPerQuery)
        XCTAssertEqual(chunks.last?.count, 3)
        XCTAssertEqual(chunks.flatMap { $0 }, branches)
    }

    func test_branchChunks_emptyAndExactMultiple() {
        XCTAssertEqual(GitHubAPI.branchChunks([]).count, 0)
        let exact = (0..<GitHubAPI.maxBranchesPerQuery).map { "b/\($0)" }
        XCTAssertEqual(GitHubAPI.branchChunks(exact).count, 1)
    }

    private func node(number: Int = 86, state: String, isDraft: Bool = false, ci: String?) -> String {
        let rollup = ci.map { "{\"state\":\"\($0)\"}" } ?? "null"
        return """
        {"nodes":[{"number":\(number),"url":"https://github.com/o/r/pull/\(number)",
          "state":"\(state)","isDraft":\(isDraft),
          "commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollup)}}]}}]}
        """
    }

    private func response(state: String, isDraft: Bool = false, ci: String?) -> String {
        #"{"data":{"repository":{"b0":"# + node(state: state, isDraft: isDraft, ci: ci) + "}}}"
    }

    // Single-branch parse, which is what most cases below exercise.
    private func parseOne(_ json: String) -> PullRequestInfo? {
        GitHubAPI.parse(json, branches: ["b"])["b"]
    }

    func test_parse_openWithPassingCI() {
        let actual = parseOne(response(state: "OPEN", ci: "SUCCESS"))
        XCTAssertEqual(actual, PullRequestInfo(number: 86, url: "https://github.com/o/r/pull/86",
                                               state: .open, isDraft: false, ci: .passing))
    }

    func test_parse_mergedNoCI() {
        let actual = parseOne(response(state: "MERGED", ci: nil))
        XCTAssertEqual(actual?.state, .merged)
        XCTAssertNil(actual?.ci)
    }

    func test_parse_draftPendingCI() {
        let actual = parseOne(response(state: "OPEN", isDraft: true, ci: "PENDING"))
        XCTAssertEqual(actual?.isDraft, true)
        XCTAssertEqual(actual?.ci, .pending)
    }

    func test_parse_failingCI() {
        XCTAssertEqual(parseOne(response(state: "OPEN", ci: "FAILURE"))?.ci, .failing)
    }

    func test_parse_noPRNodes_isNil() {
        XCTAssertNil(parseOne(#"{"data":{"repository":{"b0":{"nodes":[]}}}}"#))
    }

    func test_parse_malformed_isNil() {
        XCTAssertNil(parseOne("not json"))
        XCTAssertNil(parseOne(#"{"data":{"repository":null}}"#))
    }

    // GraphQL reports failures as HTTP 200 with an errors array. A wholesale
    // failure nulls `repository`, so nothing is read as "no PR found".
    func test_parse_graphQLErrors_yieldsNothing() {
        let json = #"{"data":null,"errors":[{"message":"Bad credentials"}]}"#
        XCTAssertEqual(GitHubAPI.parse(json, branches: ["a", "b"]).count, 0)
    }

    // A per-field error must not cost the rest of the batch its results. GraphQL
    // can error on one alias and still return data for the others, and one batch
    // stands in for up to maxBranchesPerQuery separate queries.
    func test_parse_partialResponse_keepsTheBranchesThatResolved() {
        let json = #"{"data":{"repository":{"b0":"#
            + node(number: 5, state: "OPEN", ci: nil)
            + #","b1":null}},"errors":[{"message":"Something went wrong"}]}"#
        let actual = GitHubAPI.parse(json, branches: ["good", "bad"])
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual["good"]?.number, 5)
        XCTAssertNil(actual["bad"])
    }

    // The aliases are positional, so a branch keeps its own PR and a branch with
    // no PR drops out without shifting the others.
    func test_parse_mapsEachAliasBackToItsBranch() {
        let json = #"{"data":{"repository":{"b0":"#
            + node(number: 11, state: "OPEN", ci: "SUCCESS")
            + #","b1":{"nodes":[]},"b2":"#
            + node(number: 33, state: "MERGED", ci: nil) + "}}}"
        let actual = GitHubAPI.parse(json, branches: ["first", "second", "third"])
        XCTAssertEqual(actual.count, 2)
        XCTAssertEqual(actual["first"]?.number, 11)
        XCTAssertEqual(actual["first"]?.ci, .passing)
        XCTAssertNil(actual["second"])
        XCTAssertEqual(actual["third"]?.number, 33)
        XCTAssertEqual(actual["third"]?.state, .merged)
    }

    func test_pullRequests_nilRunYieldsEmpty() {
        XCTAssertEqual(GitHubAPI.pullRequests(owner: "o", repo: "r", branches: ["b"]) { _ in nil }.count, 0)
    }

    func test_pullRequests_emptyBranchesIssuesNoRequest() {
        var calls = 0
        let actual = GitHubAPI.pullRequests(owner: "o", repo: "r", branches: []) { _ in
            calls += 1
            return nil
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(actual.count, 0)
    }

    // One request per batch, not one per branch: that ratio is the whole point of
    // the batched query.
    func test_pullRequests_batchesRequests() {
        let branches = (0..<(GitHubAPI.maxBranchesPerQuery + 1)).map { "b/\($0)" }
        var calls = 0
        _ = GitHubAPI.pullRequests(owner: "o", repo: "r", branches: branches) { _ in
            calls += 1
            return nil
        }
        XCTAssertEqual(calls, 2)
    }

    // A failed chunk loses only its own branches; later chunks still resolve.
    func test_pullRequests_oneFailedChunkDoesNotLoseTheRest() {
        let branches = (0..<(GitHubAPI.maxBranchesPerQuery + 1)).map { "b/\($0)" }
        var calls = 0
        let actual = GitHubAPI.pullRequests(owner: "o", repo: "r", branches: branches) { _ in
            calls += 1
            guard calls > 1 else { return nil }  // first chunk fails
            return #"{"data":{"repository":{"b0":"# + node(number: 7, state: "OPEN", ci: nil) + "}}}"
        }
        XCTAssertEqual(actual.count, 1)
        XCTAssertEqual(actual["b/\(GitHubAPI.maxBranchesPerQuery)"]?.number, 7)
    }
}
