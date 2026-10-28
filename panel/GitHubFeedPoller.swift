import Foundation

// Runs GitHubFeed on a timer: one GraphQL round-trip every few minutes while
// "GitHub activity" is on and a GitHub token exists, new events into the queue,
// state saved between launches so a relaunch announces nothing twice.
final class GitHubFeedPoller {

    static let statePath = ("~/.stack-nudge/github-feed.json" as NSString).expandingTildeInPath
    static let interval: TimeInterval = 3 * 60

    private let token: () -> String?               // read each poll: a sign-in can change it
    private let run: (String, String) -> String?   // (body, token) -> response
    private let deliver: ([NudgeEvent]) -> Void     // called on main
    // Every successful poll's lists, for the PRs tab; called on main.
    private let snapshot: (GitHubFeed.Snapshot, String) -> Void
    private let queue = DispatchQueue(label: "stack-nudge.github-feed", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var login: String?
    private var polling = false

    init(token: @escaping () -> String?, run: @escaping (String, String) -> String?, deliver: @escaping ([NudgeEvent]) -> Void,
         snapshot: @escaping (GitHubFeed.Snapshot, String) -> Void) {
        self.token = token
        self.run = run
        self.deliver = deliver
        self.snapshot = snapshot
    }

    // Idempotent: the settings sink calls it on every change.
    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if enabled, self.timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 2, repeating: Self.interval, leeway: .seconds(20))
                timer.setEventHandler { [weak self] in self?.poll() }
                timer.resume()
                self.timer = timer
            } else if !enabled, let timer = self.timer {
                timer.cancel()
                self.timer = nil
            }
        }
    }

    func pollNow() { queue.async { [weak self] in self?.poll() } }

    private func poll() {
        guard !polling, let token = token() else { return }
        polling = true
        defer { polling = false }
        if login == nil { login = run(GitHubFeed.viewerQuery, token).flatMap(GitHubFeed.parseViewer) }
        guard let login,
              let response = run(GitHubFeed.query(login: login), token),
              let snapshot = GitHubFeed.parse(response)
        else { return }
        let result = GitHubFeed.diff(snapshot, previous: Self.loadState(), login: login, now: Date())
        Self.saveState(result.state)
        DispatchQueue.main.async { [self] in self.snapshot(snapshot, login) }
        guard !result.events.isEmpty else { return }
        // Oldest first, so the newest ends up on top of the queue.
        let events = Array(result.events.reversed())
        DispatchQueue.main.async { [deliver] in deliver(events) }
    }

    // nil when there is no file yet: the next poll seeds silently.
    static func loadState(path: String = statePath) -> GitHubFeed.State? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(GitHubFeed.State.self, from: data)
    }

    static func saveState(_ state: GitHubFeed.State, path: String = statePath) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(state) else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Repo names and PR numbers you work on; same 0600 as the rest of ~/.stack-nudge.
        if (try? data.write(to: url, options: .atomic)) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
