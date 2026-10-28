import Foundation

// Activity on your pull requests, as feed events: review feedback, decisions,
// CI, merge conflicts, ready to merge, and requests for your review. Ported
// from Hounder's prs.ts and review-requests.ts.
//
// One GraphQL round-trip per poll returns both lists; `diff` compares it with
// what the last poll saw and returns only what is new. Pure over its inputs,
// so the rules are testable from fixtures; GitHubFeedPoller does the I/O.
enum GitHubFeed {

    // MARK: - The query

    // Searches by login across GitHub, with no org filter: your PRs and the
    // reviews asked of you are yours wherever they live.
    // `user-review-requested` matches direct requests only; team requests land
    // on nearly every PR and would drown the rest.
    static func query(login: String) -> String {
        let pr = """
        number title url isDraft reviewDecision mergeable \
        repository{nameWithOwner} \
        commits(last:1){nodes{commit{oid statusCheckRollup{state}}}} \
        reviewThreads(last:30){nodes{id comments(first:1){nodes{author{login __typename} body url}}}} \
        comments(last:20){nodes{id author{login __typename} body url}} \
        reviews(last:20){nodes{id state author{login __typename} body url}}
        """
        let requested = """
        number title url author{login} repository{nameWithOwner} \
        viewerLatestReview{submittedAt} \
        timelineItems(itemTypes:[REVIEW_REQUESTED_EVENT],last:20){nodes{...on ReviewRequestedEvent{createdAt actor{login} requestedReviewer{...on User{login}}}}}
        """
        let graphql = "query($mine:String!,$requested:String!){"
            + "mine:search(query:$mine,type:ISSUE,first:50){nodes{...on PullRequest{\(pr)}}} "
            + "requested:search(query:$requested,type:ISSUE,first:50){nodes{...on PullRequest{\(requested)}}}}"
        let body: [String: Any] = [
            "query": graphql,
            "variables": [
                "mine": "is:pr is:open author:\(login) archived:false",
                "requested": "is:pr is:open user-review-requested:\(login) archived:false",
            ],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static let viewerQuery = #"{"query":"{viewer{login}}"}"#

    static func parseViewer(_ json: String) -> String? {
        struct Root: Decodable { struct D: Decodable { struct V: Decodable { let login: String }; let viewer: V }; let data: D? }
        return (try? JSONDecoder().decode(Root.self, from: Data(json.utf8)))?.data?.viewer.login
    }

    // MARK: - Response shapes

    struct Author: Decodable, Equatable {
        let login: String
        let __typename: String?
        var isBot: Bool { __typename == "Bot" }
        var display: String { isBot ? "\(login) (bot)" : login }
    }

    struct Comment: Decodable, Equatable {
        let id: String?
        let author: Author?
        let body: String
        let url: String
    }

    struct Review: Decodable, Equatable {
        let id: String
        let state: String
        let author: Author?
        let body: String
        let url: String
    }

    struct Thread: Decodable, Equatable {
        let id: String
        let comments: Nodes<Comment>
    }

    struct Nodes<T: Decodable & Equatable>: Decodable, Equatable { let nodes: [T] }
    struct Repo: Decodable, Equatable { let nameWithOwner: String }
    struct Rollup: Decodable, Equatable { let state: String }
    struct Commit: Decodable, Equatable { let oid: String; let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable, Equatable { let commit: Commit }

    struct MyPR: Decodable, Equatable {
        let number: Int
        let title: String
        let url: String
        let isDraft: Bool
        let reviewDecision: String?
        let mergeable: String?
        let repository: Repo
        let commits: Nodes<CommitNode>
        let reviewThreads: Nodes<Thread>
        let comments: Nodes<Comment>
        let reviews: Nodes<Review>
    }

    struct RequestEvent: Decodable, Equatable {
        struct Login: Decodable, Equatable { let login: String? }
        let createdAt: String?
        let actor: Login?
        let requestedReviewer: Login?
    }

    struct RequestedPR: Decodable, Equatable {
        struct Login: Decodable, Equatable { let login: String }
        struct LatestReview: Decodable, Equatable { let submittedAt: String? }
        let number: Int
        let title: String
        let url: String
        let author: Login?
        let repository: Repo
        let viewerLatestReview: LatestReview?
        let timelineItems: Nodes<RequestEvent>?
    }

    struct Snapshot: Equatable {
        var mine: [MyPR]
        var requested: [RequestedPR]
    }

    // Search returns {} for an issue that isn't a PR; those decode to nil and
    // are skipped rather than failing the whole page.
    private struct Loose<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    static func parse(_ json: String) -> Snapshot? {
        struct Root: Decodable {
            struct Search<T: Decodable>: Decodable { let nodes: [Loose<T>] }
            struct D: Decodable { let mine: Search<MyPR>; let requested: Search<RequestedPR> }
            let data: D?
        }
        guard let root = try? JSONDecoder().decode(Root.self, from: Data(json.utf8)), let data = root.data
        else { return nil }
        return Snapshot(mine: data.mine.nodes.compactMap(\.value),
                        requested: data.requested.nodes.compactMap(\.value))
    }

    // MARK: - What the last poll saw

    struct PRState: Codable, Equatable {
        var decision: String?
        var ci: String?
        var mergeable: String?
        var ready = false
        // The commit whose green checks were last announced, so a commit is
        // announced once however many polls see it green.
        var checksSha: String?
    }

    struct State: Codable, Equatable {
        var prs: [String: PRState] = [:]
        // Ids already announced, with when they were first seen; trimmed to 30 days.
        var seen: [String: Date] = [:]
    }

    // MARK: - Diffing

    // Link-back and housekeeping bots comment on every PR and say nothing
    // about the review.
    static let noisyBots: Set<String> = ["linear-code", "github-actions"]

    // An older re-request isn't worth a nudge; it also keeps the first poll
    // after this shipped from replaying history.
    static let recentRequest: TimeInterval = 7 * 86_400
    static let seenRetention: TimeInterval = 30 * 86_400

    struct Result {
        let events: [NudgeEvent]
        let state: State
    }

    // With no previous state this is the first poll: everything already there
    // is recorded and nothing is announced.
    static func diff(_ snapshot: Snapshot, previous: State?, login: String, now: Date) -> Result {
        let seeding = previous == nil
        var state = previous ?? State()
        var events: [NudgeEvent] = []
        func fresh(_ id: String) -> Bool {
            guard state.seen[id] == nil else { return false }
            state.seen[id] = now
            return !seeding
        }

        for pr in snapshot.mine {
            let repo = pr.repository.nameWithOwner
            let key = "\(repo)#\(pr.number)"
            let label = "\(shortRepo(repo))#\(pr.number)"
            let prev = state.prs[key]
            let isMine = { (a: Author?) in a?.login == login }
            func feed(_ tag: String, _ severity: EventSeverity, _ title: String, _ message: String,
                      url: String, key eventKey: String?) -> NudgeEvent {
                .feed(source: .github, tag: tag, severity: severity, title: title, message: message,
                      url: URL(string: url), repo: repo, pr: pr.number, key: eventKey, timestamp: now)
            }

            // Feedback: every new thread, comment and review on the PR this poll.
            var feedback: [(author: Author?, body: String, severity: EventSeverity, url: String)] = []
            for thread in pr.reviewThreads.nodes {
                guard let first = thread.comments.nodes.first, !isMine(first.author),
                      fresh("thread:\(thread.id)") else { continue }
                feedback.append((first.author, first.body, .action, first.url))
            }
            for comment in pr.comments.nodes {
                guard let id = comment.id, !isMine(comment.author),
                      !noisyBots.contains(comment.author?.login ?? ""),
                      fresh("comment:\(id)") else { continue }
                feedback.append((comment.author, comment.body, .info, comment.url))
            }
            for review in pr.reviews.nodes {
                guard !isMine(review.author), review.state != "PENDING", review.state != "DISMISSED",
                      // An empty COMMENTED review wraps threads already counted above.
                      !(review.state == "COMMENTED" && review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                      fresh("review:\(review.id)") else { continue }
                feedback.append((review.author, review.body, review.state == "CHANGES_REQUESTED" ? .action : .info, review.url))
            }
            if let first = feedback.first {
                let severity: EventSeverity = feedback.contains { $0.severity == .action } ? .action : .info
                if feedback.count == 1 {
                    events.append(feed("review", severity, "\(first.author?.display ?? "Someone") commented on \(label)",
                                       snippet(first.body), url: first.url, key: nil))
                } else {
                    let names = orderedUnique(feedback.map { $0.author?.display ?? "someone" })
                    let latest = feedback.last { !($0.author?.isBot ?? false) && !$0.body.isEmpty } ?? feedback[feedback.count - 1]
                    events.append(feed("review", severity, "\(feedback.count) new comments on \(label) from \(names.joined(separator: ", "))",
                                       snippet(latest.body), url: pr.url, key: nil))
                }
            }

            let head = pr.commits.nodes.first?.commit
            let ci = head?.statusCheckRollup?.state
            // UNKNOWN is GitHub still working it out; keep the last answer rather than flap.
            let mergeable = pr.mergeable == "UNKNOWN" ? prev?.mergeable : pr.mergeable
            var next = PRState(decision: pr.reviewDecision, ci: ci, mergeable: mergeable,
                               ready: prev?.ready ?? false, checksSha: prev?.checksSha)
            var coveredGreen = false

            if let prev, !seeding {
                if pr.reviewDecision != prev.decision,
                   pr.reviewDecision == "APPROVED" || pr.reviewDecision == "CHANGES_REQUESTED" {
                    let approved = pr.reviewDecision == "APPROVED"
                    events.append(feed("review", approved ? .info : .action,
                                       approved ? "\(label) approved" : "\(label) has changes requested",
                                       pr.title, url: pr.url, key: "decision:\(key)"))
                }
                if ci != prev.ci {
                    if isFailing(ci) {
                        events.append(feed("ci", .alert, "CI failing on \(label)", pr.title, url: pr.url, key: "ci:\(key)"))
                    } else if ci == "SUCCESS", isFailing(prev.ci) {
                        events.append(feed("ci", .info, "CI passing again on \(label)", pr.title, url: pr.url, key: "ci:\(key)"))
                        coveredGreen = true
                    }
                }
                if mergeable == "CONFLICTING", prev.mergeable != "CONFLICTING" {
                    events.append(feed("ci", .alert, "Merge conflict on \(label)", pr.title, url: pr.url, key: "conflict:\(key)"))
                }
            }

            let ready = !pr.isDraft && pr.reviewDecision == "APPROVED" && ci == "SUCCESS" && mergeable == "MERGEABLE"
            if ready, !next.ready {
                next.ready = true
                if prev != nil, !seeding {
                    events.append(feed("ready", .action, "\(label) is ready to merge", pr.title, url: pr.url, key: "ready:\(key)"))
                    coveredGreen = true
                }
            } else if !ready {
                // Re-armed only once it stops being ready, so a later green run can fire again.
                next.ready = false
            }

            // Green checks on a new commit, once per commit, unless something
            // above already said so.
            if ci == "SUCCESS", !pr.isDraft, let sha = head?.oid, prev?.checksSha != sha {
                next.checksSha = sha
                if prev != nil, !seeding, !coveredGreen {
                    events.append(feed("ci", .info, "Checks passed on \(label)", pr.title, url: pr.url, key: "checks:\(key)"))
                }
            }
            state.prs[key] = next
        }

        for pr in snapshot.requested {
            let repo = pr.repository.nameWithOwner
            let label = "\(shortRepo(repo))#\(pr.number)"
            let request = latestRequest(pr, login: login, now: now)
            // A first request has one id per PR; each re-request after a review
            // gets its own, so it notifies once.
            let id = request?.again == true
                ? "review-requested:\(repo)#\(pr.number):again:\(request?.at ?? "")"
                : "review-requested:\(repo)#\(pr.number)"
            guard fresh(id) else { continue }
            let who = request?.requester ?? pr.author?.login ?? "Someone"
            let title = request?.again == true
                ? "\(who) asked for your review again on \(label)"
                : "\(who) asked for your review on \(label)"
            events.append(.feed(source: .github, tag: "review-request", severity: .action, title: title,
                                message: pr.title, url: URL(string: pr.url), repo: repo, pr: pr.number,
                                key: "review-request:\(repo)#\(pr.number)", timestamp: now))
        }

        // PRs no longer open are dropped from state; their ids age out of `seen`.
        let open = Set(snapshot.mine.map { "\($0.repository.nameWithOwner)#\($0.number)" })
        state.prs = state.prs.filter { open.contains($0.key) }
        state.seen = state.seen.filter { now.timeIntervalSince($0.value) < seenRetention }
        return Result(events: events, state: state)
    }

    static func latestRequest(_ pr: RequestedPR, login: String, now: Date)
        -> (at: String, requester: String?, again: Bool)? {
        let mine = (pr.timelineItems?.nodes ?? []).filter { $0.requestedReviewer?.login == login }
        guard let last = mine.last, let at = last.createdAt, let requestedAt = isoDate(at) else { return nil }
        let reviewedAt = pr.viewerLatestReview?.submittedAt.flatMap(isoDate)
        let again = reviewedAt.map { $0 < requestedAt } == true && now.timeIntervalSince(requestedAt) < recentRequest
        return (at, last.actor?.login, again)
    }

    // MARK: - Helpers

    static func isFailing(_ state: String?) -> Bool { state == "FAILURE" || state == "ERROR" }

    static func shortRepo(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    // First line of a comment, whitespace collapsed, cut to fit a row.
    static func snippet(_ body: String, limit: Int = 140) -> String {
        let flat = body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
    }

    static func orderedUnique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func isoDate(_ raw: String) -> Date? { iso.date(from: raw) }
}
