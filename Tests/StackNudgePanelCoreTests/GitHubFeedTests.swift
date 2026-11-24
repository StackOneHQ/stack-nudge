import XCTest

@testable import StackNudgePanelCore

// The rules ported from Hounder's prs.ts and review-requests.ts, run over
// GitHub-shaped fixtures.
final class GitHubFeedTests: XCTestCase {

    private let login = "me"
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func later(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    // MARK: - Fixtures

    private func author(_ login: String, bot: Bool = false) -> [String: Any] {
        ["login": login, "__typename": bot ? "Bot" : "User"]
    }

    private func pr(number: Int = 1, decision: Any = NSNull(), ci: String? = "PENDING", sha: String = "a1",
                    mergeable: String = "MERGEABLE", draft: Bool = false,
                    threads: [[String: Any]] = [], comments: [[String: Any]] = [],
                    reviews: [[String: Any]] = []) -> [String: Any] {
        var commit: [String: Any] = ["oid": sha]
        commit["statusCheckRollup"] = ci.map { ["state": $0] } ?? NSNull()
        return [
            "number": number, "title": "Add the companion", "url": "https://github.com/acme/app/pull/\(number)",
            "isDraft": draft, "reviewDecision": decision, "mergeable": mergeable,
            "repository": ["nameWithOwner": "acme/app"],
            "commits": ["nodes": [["commit": commit]]],
            "reviewThreads": ["nodes": threads],
            "comments": ["nodes": comments],
            "reviews": ["nodes": reviews],
        ]
    }

    private func thread(_ id: String, by: String, body: String = "Can this be simpler?") -> [String: Any] {
        ["id": id, "comments": ["nodes": [["author": author(by), "body": body, "url": "https://github.com/acme/app/pull/1#\(id)"]]]]
    }

    private func comment(_ id: String, by: [String: Any], body: String = "LGTM overall") -> [String: Any] {
        ["id": id, "author": by, "body": body, "url": "https://github.com/acme/app/pull/1#\(id)"]
    }

    private func requested(number: Int = 7, requestedAt: String = "2027-01-15T08:00:00Z",
                           reviewedAt: String? = nil, team: String? = nil) -> [String: Any] {
        let reviewer: [String: Any] = team.map { ["__typename": "Team", "name": $0, "slug": $0.lowercased()] }
            ?? ["__typename": "User", "login": login]
        return [
            "number": number, "title": "Fix the thing", "url": "https://github.com/acme/api/pull/\(number)",
            "author": ["login": "alice"], "repository": ["nameWithOwner": "acme/api"],
            "viewerLatestReview": reviewedAt.map { ["submittedAt": $0] as Any } ?? NSNull(),
            "timelineItems": ["nodes": [["createdAt": requestedAt, "actor": ["login": "bob"],
                                         "requestedReviewer": ["login": login]]]],
            "reviewRequests": ["nodes": [["requestedReviewer": reviewer]]],
        ]
    }

    private func snapshot(mine: [[String: Any]] = [], requested: [[String: Any]] = []) -> GitHubFeed.Snapshot {
        let root: [String: Any] = ["data": ["mine": ["nodes": mine], "requested": ["nodes": requested]]]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return GitHubFeed.parse(String(data: data, encoding: .utf8)!)!
    }

    // Seeds on the first snapshot, then diffs the second.
    private func events(from first: GitHubFeed.Snapshot, to second: GitHubFeed.Snapshot) -> [NudgeEvent] {
        let seeded = GitHubFeed.diff(first, previous: nil, login: login, now: t0)
        return GitHubFeed.diff(second, previous: seeded.state, login: login, now: later(3)).events
    }

    // MARK: - Query and parsing

    func testTheQuerySearchesByLoginWithNoOrgFilter() {
        let body = GitHubFeed.query(login: "octocat")
        XCTAssertTrue(body.contains("author:octocat"))
        XCTAssertTrue(body.contains("review-requested:octocat"))
        XCTAssertFalse(body.contains("org:"))
    }

    // Search can return an issue, which comes back as {} in a PR fragment.
    func testNonPRResultsAreSkipped() {
        let parsed = snapshot(mine: [[:], pr()])
        XCTAssertEqual(parsed.mine.count, 1)
    }

    func testViewerLogin() {
        XCTAssertEqual(GitHubFeed.parseViewer(#"{"data":{"viewer":{"login":"octocat"}}}"#), "octocat")
        XCTAssertNil(GitHubFeed.parseViewer(#"{"errors":[{"message":"Bad credentials"}]}"#))
    }

    // MARK: - Seeding

    func testTheFirstPollAnnouncesNothing() {
        let first = snapshot(mine: [pr(ci: "FAILURE", threads: [thread("t1", by: "alice")])],
                             requested: [requested()])
        XCTAssertEqual(GitHubFeed.diff(first, previous: nil, login: login, now: t0).events.count, 0)
    }

    // MARK: - Feedback

    func testANewThreadIsOneEvent() {
        let got = events(from: snapshot(mine: [pr()]),
                         to: snapshot(mine: [pr(threads: [thread("t1", by: "alice")])]))
        XCTAssertEqual(got.map(\.title), ["alice commented on app#1"])
        XCTAssertEqual(got.first?.severity, .action)
        XCTAssertEqual(got.first?.tag, "review")
        XCTAssertEqual(got.first?.url?.fragment, "t1")
    }

    func testYourOwnCommentsAndNoisyBotsAreIgnored() {
        let got = events(from: snapshot(mine: [pr()]),
                         to: snapshot(mine: [pr(threads: [thread("t1", by: login)],
                                               comments: [comment("c1", by: author("github-actions", bot: true)),
                                                          comment("c2", by: author(login))])]))
        XCTAssertTrue(got.isEmpty, "\(got.map(\.title))")
    }

    func testSeveralNewItemsCollapseIntoOneRow() {
        let got = events(from: snapshot(mine: [pr()]),
                         to: snapshot(mine: [pr(threads: [thread("t1", by: "alice")],
                                               comments: [comment("c1", by: author("bob"), body: "One more thing")])]))
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.title, "2 new comments on app#1 from alice, bob")
        XCTAssertEqual(got.first?.message, "One more thing")
        XCTAssertEqual(got.first?.severity, .action, "a thread makes the group need action")
    }

    func testAnEmptyCommentedReviewIsNotNews() {
        let review: [String: Any] = ["id": "r1", "state": "COMMENTED", "author": author("alice"), "body": " ",
                                     "url": "https://github.com/acme/app/pull/1#r1"]
        let got = events(from: snapshot(mine: [pr()]), to: snapshot(mine: [pr(reviews: [review])]))
        XCTAssertTrue(got.isEmpty)
    }

    func testFeedbackIsAnnouncedOnce() {
        let withThread = snapshot(mine: [pr(threads: [thread("t1", by: "alice")])])
        let seeded = GitHubFeed.diff(snapshot(mine: [pr()]), previous: nil, login: login, now: t0)
        let once = GitHubFeed.diff(withThread, previous: seeded.state, login: login, now: later(3))
        let twice = GitHubFeed.diff(withThread, previous: once.state, login: login, now: later(6))
        XCTAssertEqual(once.events.count, 1)
        XCTAssertTrue(twice.events.isEmpty)
    }

    // MARK: - State changes

    func testDecisionsAreKeyedPerPR() {
        let got = events(from: snapshot(mine: [pr()]), to: snapshot(mine: [pr(decision: "CHANGES_REQUESTED")]))
        XCTAssertEqual(got.map(\.title), ["app#1 has changes requested"])
        XCTAssertEqual(got.first?.key, "decision:acme/app#1")
        XCTAssertEqual(got.first?.severity, .action)
    }

    func testCIFailingThenPassingAgain() {
        let failing = events(from: snapshot(mine: [pr(ci: "PENDING")]), to: snapshot(mine: [pr(ci: "FAILURE")]))
        XCTAssertEqual(failing.map(\.title), ["CI failing on app#1"])
        XCTAssertEqual(failing.first?.severity, .alert)
        XCTAssertEqual(failing.first?.key, "ci:acme/app#1", "passing again replaces the failure row")

        let recovered = events(from: snapshot(mine: [pr(ci: "FAILURE")]), to: snapshot(mine: [pr(ci: "SUCCESS", sha: "a2")]))
        XCTAssertEqual(recovered.map(\.title), ["CI passing again on app#1"], "no separate checks-passed row")
    }

    func testChecksPassedOncePerCommit() {
        let seeded = GitHubFeed.diff(snapshot(mine: [pr(ci: "PENDING")]), previous: nil, login: login, now: t0)
        let green = GitHubFeed.diff(snapshot(mine: [pr(ci: "SUCCESS")]), previous: seeded.state, login: login, now: later(3))
        XCTAssertEqual(green.events.map(\.title), ["Checks passed on app#1"])
        let again = GitHubFeed.diff(snapshot(mine: [pr(ci: "SUCCESS")]), previous: green.state, login: login, now: later(6))
        XCTAssertTrue(again.events.isEmpty)
        let newCommit = GitHubFeed.diff(snapshot(mine: [pr(ci: "SUCCESS", sha: "a2")]), previous: again.state, login: login, now: later(9))
        XCTAssertEqual(newCommit.events.map(\.title), ["Checks passed on app#1"])
    }

    func testReadyToMergeFiresOnceAndRearms() {
        let seeded = GitHubFeed.diff(snapshot(mine: [pr(decision: "APPROVED", ci: "PENDING")]), previous: nil, login: login, now: t0)
        let ready = GitHubFeed.diff(snapshot(mine: [pr(decision: "APPROVED", ci: "SUCCESS")]), previous: seeded.state, login: login, now: later(3))
        XCTAssertEqual(ready.events.map(\.title), ["app#1 is ready to merge"], "ready covers the green checks")
        let still = GitHubFeed.diff(snapshot(mine: [pr(decision: "APPROVED", ci: "SUCCESS")]), previous: ready.state, login: login, now: later(6))
        XCTAssertTrue(still.events.isEmpty)
        let broken = GitHubFeed.diff(snapshot(mine: [pr(decision: "APPROVED", ci: "FAILURE", sha: "a2")]), previous: still.state, login: login, now: later(9))
        let readyAgain = GitHubFeed.diff(snapshot(mine: [pr(decision: "APPROVED", ci: "SUCCESS", sha: "a3")]), previous: broken.state, login: login, now: later(12))
        XCTAssertTrue(readyAgain.events.map(\.title).contains("app#1 is ready to merge"))
    }

    func testAMergeConflictIsAnAlert() {
        let got = events(from: snapshot(mine: [pr()]), to: snapshot(mine: [pr(mergeable: "CONFLICTING")]))
        XCTAssertEqual(got.map(\.title), ["Merge conflict on app#1"])
        XCTAssertEqual(got.first?.severity, .alert)
    }

    // UNKNOWN means GitHub is still computing; it must not read as a change.
    func testAnUnknownMergeStateKeepsTheLastAnswer() {
        let got = events(from: snapshot(mine: [pr(mergeable: "CONFLICTING")]), to: snapshot(mine: [pr(mergeable: "UNKNOWN")]))
        XCTAssertTrue(got.isEmpty)
    }

    // MARK: - Review requests

    func testANewReviewRequest() {
        let got = events(from: snapshot(), to: snapshot(requested: [requested()]))
        XCTAssertEqual(got.map(\.title), ["bob asked for your review on api#7"])
        XCTAssertEqual(got.first?.tag, "review-request")
        XCTAssertEqual(got.first?.message, "Fix the thing")
    }

    // A re-request after you reviewed notifies once more.
    func testAReRequestAfterYourReview() {
        let now = GitHubFeed.isoDate("2027-01-15T09:00:00Z")!
        let first = snapshot(requested: [requested(requestedAt: "2027-01-14T08:00:00Z")])
        let seeded = GitHubFeed.diff(first, previous: nil, login: login, now: now)
        let again = snapshot(requested: [requested(requestedAt: "2027-01-15T08:00:00Z", reviewedAt: "2027-01-14T12:00:00Z")])
        let got = GitHubFeed.diff(again, previous: seeded.state, login: login, now: now)
        XCTAssertEqual(got.events.map(\.title), ["bob asked for your review again on api#7"])
    }

    // MARK: - Housekeeping

    func testClosedPRsLeaveTheState() {
        let seeded = GitHubFeed.diff(snapshot(mine: [pr(number: 1), pr(number: 2)]), previous: nil, login: login, now: t0)
        XCTAssertEqual(seeded.state.prs.count, 2)
        let after = GitHubFeed.diff(snapshot(mine: [pr(number: 2)]), previous: seeded.state, login: login, now: later(3))
        XCTAssertEqual(Array(after.state.prs.keys), ["acme/app#2"])
    }

    func testTheStateSurvivesARelaunch() {
        let path = NSTemporaryDirectory() + "github-feed-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let state = GitHubFeed.diff(snapshot(mine: [pr(threads: [thread("t1", by: "alice")])]), previous: nil, login: login, now: t0).state
        GitHubFeedPoller.saveState(state, path: path)
        XCTAssertEqual(GitHubFeedPoller.loadState(path: path), state)
        XCTAssertNil(GitHubFeedPoller.loadState(path: path + ".missing"), "no file means seed")
    }

    func testSnippetsAreOneLine() {
        XCTAssertEqual(GitHubFeed.snippet("Line one\n\n  line two"), "Line one line two")
        XCTAssertEqual(GitHubFeed.snippet(String(repeating: "x", count: 200)).count, 140)
    }

    // MARK: - The PRs tab

    func testRowsListMineThenToReviewWithStatusChips() {
        let snap = snapshot(mine: [pr(decision: "CHANGES_REQUESTED", ci: "FAILURE", mergeable: "CONFLICTING", draft: true)],
                            requested: [requested()])
        let rows = PRRows.rows(snap, login: login)
        XCTAssertEqual(rows.map(\.section), [.mine, .review])
        XCTAssertEqual(rows[0].label, "app#1")
        XCTAssertEqual(rows[0].chips.map(\.text), ["Changes requested", "CI failing", "Conflict"], "a decision outranks draft")
        XCTAssertEqual(rows[0].url?.absoluteString, "https://github.com/acme/app/pull/1")
        XCTAssertEqual(rows[1].chips.map(\.text), ["Requested", "from bob"])
    }

    func testAReRequestSaysSo() {
        let now = GitHubFeed.isoDate("2027-01-15T09:00:00Z")!
        let snap = snapshot(requested: [requested(requestedAt: "2027-01-15T08:00:00Z", reviewedAt: "2027-01-14T12:00:00Z")])
        XCTAssertEqual(PRRows.rows(snap, login: login, now: now).first?.chips.map(\.text), ["Requested", "asked again by bob"])
    }

    func testAPRWithNoDecisionIsInReviewOrDraft() {
        XCTAssertEqual(PRRows.rows(snapshot(mine: [pr()]), login: login).first?.chips.first?.text, "In review")
        XCTAssertEqual(PRRows.rows(snapshot(mine: [pr(draft: true)]), login: login).first?.chips.first?.text, "Draft")
    }

    func testAGreenApprovedPRReadsAsGood() {
        let rows = PRRows.rows(snapshot(mine: [pr(decision: "APPROVED", ci: "SUCCESS")]), login: login)
        XCTAssertEqual(rows.first?.chips.map(\.tone), [.good, .good])
    }

    // A request to one of your teams is listed, marked, but doesn't nudge.
    func testATeamRequestIsListedButNotAnnounced() {
        let got = events(from: snapshot(), to: snapshot(requested: [requested(team: "Platform")]))
        XCTAssertTrue(got.isEmpty, "\(got.map(\.title))")
        let rows = PRRows.rows(snapshot(requested: [requested(number: 8, team: "Platform"), requested(number: 7)]), login: login)
        XCTAssertEqual(rows.map(\.label), ["api#7", "api#8"], "direct requests first")
        XCTAssertEqual(rows[1].chips.map(\.text), ["Requested", "team: Platform", "by alice"])
    }
}

// Requests through the gh CLI: the body becomes `gh api graphql` arguments,
// so gh sends its own credential and the app never handles a token.
final class GitHubCLITests: XCTestCase {

    func testABodyBecomesGraphQLArguments() {
        let args = GitHubCLI.graphQLArguments(body: GitHubFeed.query(login: "octocat"))
        XCTAssertEqual(args?.prefix(2), ["api", "graphql"])
        XCTAssertTrue(args?.contains("mine=is:pr is:open author:octocat archived:false") == true)
        XCTAssertTrue(args?.contains("requested=is:pr is:open review-requested:octocat archived:false") == true)
        XCTAssertTrue(args?.contains { $0.hasPrefix("query=query(") } == true)
    }

    func testNumbersUseTypedFields() {
        let args = GitHubCLI.graphQLArguments(body: #"{"query":"q","variables":{"n":3}}"#)
        XCTAssertEqual(args, ["api", "graphql", "-f", "query=q", "-F", "n=3"])
    }

    // A first page sends `after: null`; refusing it failed every paged query.
    func testNullVariablesAreLeftOut() {
        let args = GitHubCLI.graphQLArguments(body: #"{"query":"q","variables":{"q":"x","after":null}}"#)
        XCTAssertEqual(args, ["api", "graphql", "-f", "query=q", "-f", "q=x"])
    }

    func testAnythingElseIsRefused() {
        XCTAssertNil(GitHubCLI.graphQLArguments(body: "not json"))
        XCTAssertNil(GitHubCLI.graphQLArguments(body: #"{"query":"q","variables":{"x":[1]}}"#))
    }
}
