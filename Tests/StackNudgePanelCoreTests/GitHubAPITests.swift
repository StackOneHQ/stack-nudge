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

    func test_query_carriesVariables() {
        let actual = GitHubAPI.query(owner: "o", repo: "r", branch: "ENG-1/x")
        XCTAssertTrue(actual.contains("headRefName"))
        XCTAssertTrue(actual.contains("\"branch\":\"ENG-1\\/x\"") || actual.contains("\"branch\":\"ENG-1/x\""))
        XCTAssertTrue(actual.contains("statusCheckRollup"))
    }

    private func response(state: String, isDraft: Bool = false, ci: String?) -> String {
        let rollup = ci.map { "{\"state\":\"\($0)\"}" } ?? "null"
        return """
        {"data":{"repository":{"pullRequests":{"nodes":[{
          "number":86,"url":"https://github.com/o/r/pull/86","state":"\(state)","isDraft":\(isDraft),
          "commits":{"nodes":[{"commit":{"statusCheckRollup":\(rollup)}}]}}]}}}}
        """
    }

    func test_parse_openWithPassingCI() {
        let actual = GitHubAPI.parse(response(state: "OPEN", ci: "SUCCESS"))
        XCTAssertEqual(actual, PullRequestInfo(number: 86, url: "https://github.com/o/r/pull/86",
                                               state: .open, isDraft: false, ci: .passing))
    }

    func test_parse_mergedNoCI() {
        let actual = GitHubAPI.parse(response(state: "MERGED", ci: nil))
        XCTAssertEqual(actual?.state, .merged)
        XCTAssertNil(actual?.ci)
    }

    func test_parse_draftPendingCI() {
        let actual = GitHubAPI.parse(response(state: "OPEN", isDraft: true, ci: "PENDING"))
        XCTAssertEqual(actual?.isDraft, true)
        XCTAssertEqual(actual?.ci, .pending)
    }

    func test_parse_failingCI() {
        XCTAssertEqual(GitHubAPI.parse(response(state: "OPEN", ci: "FAILURE"))?.ci, .failing)
    }

    func test_parse_noPRNodes_isNil() {
        XCTAssertNil(GitHubAPI.parse(#"{"data":{"repository":{"pullRequests":{"nodes":[]}}}}"#))
    }

    func test_parse_malformed_isNil() {
        XCTAssertNil(GitHubAPI.parse("not json"))
        XCTAssertNil(GitHubAPI.parse(#"{"data":{"repository":null}}"#))
    }

    func test_pullRequest_nilRunYieldsNil() {
        XCTAssertNil(GitHubAPI.pullRequest(owner: "o", repo: "r", branch: "b") { _ in nil })
    }
}
