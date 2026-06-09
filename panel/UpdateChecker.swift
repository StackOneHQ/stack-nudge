import Foundation

// Polls the GitHub Releases API for stack-nudge and surfaces the latest tag
// when it's newer than this bundle's CFBundleShortVersionString. The result
// is published back to PanelNav (on the main thread) so the tab badge and
// "Update available" row react automatically.
//
// Checks fire on app launch and then every `interval` seconds while the app
// runs. Network failures are swallowed silently — auto-update is a soft
// signal, not a critical path.
final class UpdateChecker {

    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/latest"
    )!
    static let releasesPageURL = URL(
        string: "https://github.com/StackOneHQ/stack-nudge/releases/latest"
    )!
    static let latestGHPath = "repos/StackOneHQ/stack-nudge/releases/latest"

    // Build URL + gh CLI API path for a specific tag like "1.4.2". Both
    // endpoints return the same JSON shape as /latest, so callers can reuse
    // the same parsing path.
    static func tagReleaseURL(for version: String) -> URL {
        URL(string: "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/tags/v\(version)")!
    }
    static func tagGHPath(for version: String) -> String {
        "repos/StackOneHQ/stack-nudge/releases/tags/v\(version)"
    }

    private let interval: TimeInterval
    private weak var nav: PanelNav?
    private var timer: Timer?
    private let session: URLSession

    init(nav: PanelNav, interval: TimeInterval = 2 * 60 * 60) {
        self.nav = nav
        self.interval = interval
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
    }

    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // Result of a one-shot check — surfaced to the user-triggered
    // "Check for updates…" action so the Settings row can flash
    // status feedback. Background polls ignore it.
    enum CheckResult { case upToDate, updateAvailable(String), failed }

    // Public so a "Check for updates now" action can force a refresh.
    // completion fires on the main thread when supplied; background
    // polls call with no completion and rely on the nav side effect.
    func check(completion: ((CheckResult) -> Void)? = nil) {
        guard let current = Self.currentVersion() else {
            DispatchQueue.main.async { completion?(.failed) }
            return
        }
        fetchReleaseJSON(url: Self.latestReleaseURL, ghAPIPath: Self.latestGHPath) { [weak self] json in
            guard let tag = json?["tag_name"] as? String else {
                DispatchQueue.main.async { completion?(.failed) }
                return
            }
            let latest = Self.stripV(tag)
            let newer = Self.isNewer(latest, than: current)
            let body = json?["body"] as? String
            // release-please creates the GitHub Release the moment its PR
            // merges, but release.yml takes 5–15 min more to build, sign,
            // notarize, and upload the per-arch .tar.gz. Without an artifact
            // present, clicking "Update" downstream fails with
            // noArtifactForArch. Suppress the badge until the matching
            // artifact actually exists on the release.
            let artifactReady = newer && Self.hasArtifactForThisHost(in: json)
            DispatchQueue.main.async {
                self?.nav?.updateAvailable = artifactReady ? latest : nil
                self?.nav?.updateReleaseNotes = artifactReady ? body : nil
                if newer && !artifactReady {
                    // upToDate from the user's perspective right now —
                    // they'll see the badge once CI finishes uploading.
                    completion?(.upToDate)
                } else {
                    completion?(artifactReady ? .updateAvailable(latest) : .upToDate)
                }
            }
        }
    }

    // True when the release JSON's `assets[]` includes a `.tar.gz` matching
    // this host's architecture. Mirrors Updater.currentArch — we look for
    // "-macos-arm64.tar.gz" or "-macos-x86_64.tar.gz" depending on uname.
    private static func hasArtifactForThisHost(in json: [String: Any]?) -> Bool {
        guard let assets = json?["assets"] as? [[String: Any]] else { return false }
        let arch = currentHostArch()
        let suffix = "-macos-\(arch).tar.gz"
        return assets.contains { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasSuffix(suffix) && !name.hasSuffix(".sha256")
        }
    }

    private static func currentHostArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let m = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // uname returns "arm64" / "x86_64" on macOS.
        return m == "x86_64" ? "x86_64" : "arm64"
    }

    // One-shot fetch of release notes for the update-confirm view. Used when
    // the user clicks the update row before the background check has cached
    // notes. Calls completion on the main thread with the body string or nil.
    func fetchReleaseNotes(completion: @escaping (String?) -> Void) {
        fetchReleaseJSON(url: Self.latestReleaseURL, ghAPIPath: Self.latestGHPath) { json in
            DispatchQueue.main.async { completion(json?["body"] as? String) }
        }
    }

    // Fetch release notes for a specific version tag — used by the post-update
    // view to surface exactly what shipped, even if a newer release lands in
    // between the install and the relaunch. Same gh-fallback path as the
    // /latest case.
    func fetchReleaseNotes(for version: String, completion: @escaping (String?) -> Void) {
        fetchReleaseJSON(
            url: Self.tagReleaseURL(for: version),
            ghAPIPath: Self.tagGHPath(for: version)
        ) { json in
            DispatchQueue.main.async { completion(json?["body"] as? String) }
        }
    }

    // MARK: - Fetch with gh fallback

    // Tries the unauthenticated GitHub API first. When that returns no usable
    // payload (404 because the repo is private, or any other failure), falls
    // back to `gh api <path>` which uses the user's locally-authenticated gh
    // CLI. For org members who already have gh set up, this is invisible —
    // same ergonomics as a public repo.
    private func fetchReleaseJSON(
        url: URL,
        ghAPIPath: String,
        completion: @escaping ([String: Any]?) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("stack-nudge", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            if let data,
               http?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                completion(json)
                return
            }
            // Public path didn't work — try the local gh CLI.
            self?.fetchViaGH(apiPath: ghAPIPath, completion: completion)
        }.resume()
    }

    // Spawn `gh api <path>` and parse stdout as JSON. Launchd-launched apps
    // have a minimal PATH, so search the common homebrew locations directly
    // rather than relying on env. Any failure (missing binary, gh not
    // authenticated, network issue, repo not accessible) yields a nil result
    // and a no-op upstream.
    private func fetchViaGH(apiPath: String, completion: @escaping ([String: Any]?) -> Void) {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let ghPath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            completion(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: ghPath)
            task.arguments = ["api", apiPath]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()
            do { try task.run() } catch {
                completion(nil); return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(nil); return
            }
            completion(json)
        }
    }

    // MARK: - Helpers

    static func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    // Compare dotted-numeric versions component-wise. Returns true when
    // `latest` is strictly greater than `current`. Non-numeric components
    // (pre-release suffixes) are treated as 0 — good enough for our release
    // cadence; can be revisited if we adopt pre-releases.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let l = latest.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, c.count)
        for i in 0..<count {
            let li = i < l.count ? l[i] : 0
            let ci = i < c.count ? c[i] : 0
            if li != ci { return li > ci }
        }
        return false
    }
}
