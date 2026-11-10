import AppKit
import SwiftUI

// Dev-only: renders the panel from fixture state into PNGs: the README's
// pictures (`readme`) and the Extensions pages (`extensions`), for reviewers
// to see each screen without installing anything.
//
//     StackNudge.app/Contents/MacOS/stack-nudge --render-screenshots <dir> [readme|extensions]
//
// The real SwiftUI views, at the panel's default size, in dark appearance, in
// an offscreen window captured with cacheDisplay, which needs no Screen
// Recording permission. Everything shown is a fixture: it never reads the
// config file or the extensions directory, and every write path is stubbed,
// so nothing it does can reach the user's setup. scripts/render-screenshots.sh
// builds the app and runs this.
enum ScreenshotRenderer {

    static let flag = "--render-screenshots"
    // The panel's default size (600 x 320) less its tab strip, which is what
    // Settings and the browser get.
    static let size = NSSize(width: 600, height: 283)

    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag) else { return }
        let directory = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath
        // Both sets unless one is named.
        let set = i + 2 < args.count ? args[i + 2] : nil
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for scenario in scenarios where set == nil || scenario.set == set {
                let path = (directory as NSString).appendingPathComponent(scenario.name + ".png")
                try render(scenario, to: path)
                print(path)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("render-screenshots: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Scenarios

    struct Scenario {
        let name: String
        var set = "extensions"
        // Taller than the panel's default where the point of the picture is
        // below the fold (the "N more" line under ten rows).
        var height: CGFloat = ScreenshotRenderer.size.height
        var width: CGFloat = ScreenshotRenderer.size.width
        // Builds the view; the second closure, run once it is on screen, puts
        // it in the state the picture is of (a pick started, a row selected).
        let make: () -> (AnyView, () -> Void)
    }

    static let scenarios: [Scenario] = readmeScenarios + [
        Scenario(name: "extensions-none") {
            let nav = fixtureNav(installed: [])
            return (settings(nav), { enterExtensions(nav) })
        },
        Scenario(name: "extensions-installed") {
            let nav = fixtureNav(installed: installedRows)
            return (settings(nav), { enterExtensions(nav, select: "away") })
        },
        Scenario(name: "extension-page-away") {
            let nav = fixtureNav(installed: installedRows)
            return (settings(nav), { enterExtensions(nav); nav.openExtensionPage("away") })
        },
        Scenario(name: "extension-page-picking") {
            let nav = fixtureNav(installed: installedRows)
            return (settings(nav), {
                enterExtensions(nav)
                nav.openExtensionPage("away")
                nav.selectedSettingIndex = nav.index(of: .extensionSetting("away", "STACKNUDGE_EXT_AWAY_IDLE"))
                nav.activate()
                nav.cycleForward()
            })
        },
        Scenario(name: "browse-default") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), { catalog.selection = .row("away") })
        },
        Scenario(name: "browse-more") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), {
                // The tenth row, as ↓ to the end would leave it.
                let rows = ExtensionCatalog.browseRows(
                    ExtensionCatalog.rows(catalogue: catalog.entries, installed: host.manifests,
                                          refused: host.refused), query: "").shown
                if let last = rows.last { catalog.selection = .row(last.id) }
            })
        },
        Scenario(name: "browse-search") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), { catalog.query = "slack" })
        },
        Scenario(name: "browse-confirm") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), {
                catalog.selection = .row("away")
                catalog.requestInstall(catalog.entries.first { $0.id == "away" }!)
            })
        },
    ]

    // MARK: - Fixtures

    private static let installedRows = [
        row("away", "Away", "Locks the Mac when your phone leaves"),
        row("derby", "Token Derby", "A horse race where each runner advances on the tokens its owner burns."),
        row("pylon", "Pylon", "Customer issues waiting on a response, and a nudge before the SLA runs out.",
            available: "1.2.0"),
        row("radar", "Radar", "Watches your open pull requests for review requests."),
    ]

    private static func row(_ id: String, _ name: String, _ description: String,
                            available: String? = nil) -> ExtensionRow {
        ExtensionRow(id: id, name: name, description: description, installedVersion: "1.1.0",
                     availableVersion: available ?? "1.1.0", refusedReason: nil, requires: [], config: [])
    }

    private static let awayKeys: [ExtensionManifest.ConfigKey] = {
        let json = #"""
            {"id":"away","name":"Away","version":"1.1.0","schema":2,"mode":"service",
             "surfaces":["settings"],"capabilities":["bluetooth","signal:presence"],
             "config":[
               {"key":"STACKNUDGE_EXT_AWAY_PHONE","label":"Phone","type":"dynamic",
                "help":"Your phone, from the paired devices Away can hear nearby."},
               {"key":"STACKNUDGE_EXT_AWAY_IDLE","label":"Idle for","type":"number",
                "options":[10,15,20,30,45,60,90,120],"unit":"seconds","default":30,
                "help":"How long the Mac must go untouched before you can count as away."},
               {"key":"STACKNUDGE_EXT_AWAY_SILENCE","label":"Phone silent for","type":"number",
                "options":[90,120,180,300,600],"unit":"seconds","default":120,
                "help":"How long the phone must go unheard before you can count as away."}]}
            """#
        guard case .success(let m) = ExtensionManifest.parse(Data(json.utf8)) else { return [] }
        return m.config
    }()

    private static func fixtureNav(installed: [ExtensionRow]) -> PanelNav {
        let nav = PanelNav()
        // Every write path stubbed: this must never touch the real config.
        nav.persistExtensionValue = { _, _ in }
        nav.onExtensionConfigChanged = { _ in }
        nav.onUpdateExtension = { _ in }
        nav.onRemoveExtension = { _ in }
        nav.mode = .settings
        nav.installedExtensions = installed
        nav.browseExtensionsValue = installed.isEmpty ? "14 available" : "10 available · 1 update"
        nav.extensionListStatus = ["away": "Present", "derby": "Tab ⌘6", "pylon": "Update 1.2.0",
                                   "radar": "Broken"]
        nav.extensionSettingsPages = installed.isEmpty ? [] : [
            ExtensionSettingsPage(id: "away", name: "Away", keys: awayKeys,
                                  allowed: ["Bluetooth", "Tell StackNudge you're away"], tab: nil),
            ExtensionSettingsPage(id: "derby", name: "Token Derby", keys: [], tab: "Tab ⌘6"),
            ExtensionSettingsPage(id: "pylon", name: "Pylon", keys: [], tab: "Tab ⌘7"),
            ExtensionSettingsPage(id: "radar", name: "Radar", keys: []),
        ]
        nav.presenceHolderID = installed.isEmpty ? nil : "away"
        nav.extensionStatus = ["away": "Present · Alex's Pixel 9 · \u{2212}74 dBm · 3 s ago"]
        nav.extensionChoices = ["away": ["STACKNUDGE_EXT_AWAY_PHONE": [
            ConfigOption(value: "Alex's Pixel 9", label: "Alex's Pixel 9 · \u{2212}74 dBm"),
            ConfigOption(value: "Headphones", label: "Headphones · \u{2212}43 dBm"),
        ]]]
        nav.extensionConfigValues = ["STACKNUDGE_EXT_AWAY_PHONE": "Alex's Pixel 9"]
        return nav
    }

    private static func enterExtensions(_ nav: PanelNav, select id: String? = nil) {
        nav.settingsCategory = .extensions
        nav.settingsDetailFocused = true
        nav.selectFirstCategoryRow()
        if let id { nav.selectedSettingIndex = nav.index(of: .installedExtension(id)) }
    }

    private static func fixtureCatalog() -> (ExtensionCatalog, ExtensionHost) {
        let published: [(String, String, String, String?, [String])] = [
            ("away", "Away", "Locks the Mac when your phone leaves", "trusted", []),
            ("derby", "Token Derby", "A horse race where each runner advances on the tokens its owner burns.", nil, ["python3"]),
            ("pylon", "Pylon", "Customer issues waiting on a response, and a nudge before the SLA runs out.", nil, ["python3"]),
            ("system", "System", "CPU, memory and disk usage at a glance.", nil, []),
            ("radar", "Radar", "Watches your open pull requests for review requests.", "trusted", []),
            ("standup", "Standup", "Yesterday's merged work, ready to paste into standup.", nil, []),
            ("slack-status", "Slack Status", "Sets your Slack status while an agent is working.", "service", []),
            ("slack-digest", "Slack Digest", "A morning digest of threads that mention you.", nil, []),
            ("calendar", "Calendar", "Your next meeting, and how long until it starts.", nil, []),
            ("ci", "CI", "Failing builds on your branches, newest first.", nil, []),
            ("focus", "Focus", "Holds nudges while a Focus mode is on.", "service", []),
            ("linear", "Linear", "Issues assigned to you, by cycle.", nil, []),
            ("weather", "Weather", "Rain in the next hour, if any.", nil, []),
            ("pomodoro", "Pomodoro", "A 25-minute timer in the widget.", nil, []),
        ]
        let capabilities = ["away": ["bluetooth", "signal:presence"], "slack-status": ["event:idle"],
                            "focus": ["event:panel", "feed"]]
        let entries = published.map { id, name, description, tier, requires in
            ExtensionInstaller.IndexEntry(id: id, name: name, version: id == "derby" ? "1.2.0" : "1.1.0",
                                          description: description, asset: "extension-\(id)-1.1.0.tar.gz",
                                          sha256: "ab", requires: requires, config: [], tier: tier,
                                          capabilities: capabilities[id] ?? [],
                                          mode: capabilities[id] == nil ? "view" : "service")
        }
        let catalog = ExtensionCatalog(fetchCatalogue: { .success(entries) },
                                       performInstall: { .success($0.id) },
                                       performRemove: { .success($0) },
                                       background: { $0() }, toMain: { $0() },
                                       probeRequirement: { $0 != "python3" },
                                       recordedTiers: { [:] })
        catalog.reload()
        let host = ExtensionHost(background: { _ in }, toMain: { $0() },
                                 runner: { _, _, _ in .transient("fixture") },
                                 tiers: { [:] },
                                 makeSupervisor: { _, _, _ in fatalError("no services in fixtures") })
        let installed = ["derby", "system"].compactMap { id -> ExtensionManifest? in
            guard case .success(let m) = ExtensionManifest.parse(Data("""
                {"id":"\(id)","name":"\(id == "derby" ? "Token Derby" : "System")","version":"1.1.0","schema":1}
                """.utf8)) else { return nil }
            return m
        }
        host.load(.init(installed: installed))
        return (catalog, host)
    }

    private static func settings(_ nav: PanelNav) -> AnyView {
        AnyView(SettingsView(nav: nav, runsOnAppear: false))
    }

    private static func browser(_ catalog: ExtensionCatalog, _ host: ExtensionHost) -> AnyView {
        AnyView(ExtensionsView(catalog: catalog, host: host, onConfigure: { _ in }, onBack: {}))
    }

    // MARK: - README

    // The whole panel, tab strip and all, at its default 600 x 320.
    private static let panelHeight: CGFloat = 320

    private static let readmeScenarios: [Scenario] = [
        Scenario(name: "events", set: "readme", height: panelHeight) {
            let f = PanelFixture(mode: .events)
            return (f.view, { f.store.selectedID = f.store.events.first?.id })
        },
        Scenario(name: "sessions", set: "readme", height: panelHeight) {
            let f = PanelFixture(mode: .sessions)
            return (f.view, {})
        },
        Scenario(name: "usage", set: "readme", height: panelHeight) {
            let f = PanelFixture(mode: .usage)
            return (f.view, {})
        },
        Scenario(name: "outcomes", set: "readme", height: panelHeight) {
            let f = PanelFixture(mode: .outcomes)
            return (f.view, {})
        },
        Scenario(name: "settings", set: "readme", height: panelHeight) {
            let f = PanelFixture(mode: .settings)
            return (f.view, {
                f.nav.settingsCategory = .notifications
                f.nav.settingsDetailFocused = true
                f.nav.selectFirstCategoryRow()
            })
        },
        Scenario(name: "widget", set: "readme", height: 56, width: 290) {
            let f = PanelFixture(mode: .events)
            f.nav.compactMode = true
            return (AnyView(CompactView(store: f.store, sessions: f.sessions, nav: f.nav,
                                        onExpand: {}, onExitCompact: {})), {})
        },
    ]

    // Every store the panel reads, filled with made-up work in made-up repos.
    // The ledger and session names live in a scratch directory, the session
    // list is never scanned, and Settings never runs its appear-time probes,
    // so nothing on the machine rendering these reaches a picture.
    private final class PanelFixture {
        let nav = PanelNav()
        let store = EventStore()
        let persistence: SessionPersistence
        let sessions: SessionStore
        let scratch: URL

        init(mode: PanelMode) {
            scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("stack-nudge-screenshots-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            persistence = SessionPersistence(path: scratch.appendingPathComponent("sessions.json"))
            sessions = SessionStore(persistence: persistence)
            nav.sessionPersistence = persistence
            nav.handoffLedger = HandoffLedger(path: scratch.appendingPathComponent("handoffs.jsonl"))
            nav.persistExtensionValue = { _, _ in }
            nav.onExtensionConfigChanged = { _ in }
            nav.mode = mode
            // The pill is the default; the panel pictures want the panel.
            nav.compactMode = false
            fillEvents()
            fillSessions()
            fillUsage()
            fillOutcomes()
        }

        var view: AnyView {
            AnyView(PanelContentView(
                store: store, sessions: sessions, nav: nav, phrases: PhrasesViewModel(),
                permissions: PermissionsModel(),
                extensions: ExtensionHost(background: { _ in }, toMain: { $0() },
                                          runner: { _, _, _ in .transient("fixture") },
                                          tiers: { [:] },
                                          makeSupervisor: { _, _, _ in fatalError("no services in fixtures") }),
                extensionCatalog: ExtensionCatalog(fetchCatalogue: { .success([]) },
                                                   performInstall: { .success($0.id) },
                                                   performRemove: { .success($0) },
                                                   background: { $0() }, toMain: { $0() },
                                                   probeRequirement: { _ in true },
                                                   recordedTiers: { [:] }),
                onConfigureExtension: { _ in }, onCloseExtensionsBrowser: {},
                onGrantPermissions: {}, runsOnAppear: false
            ).environmentObject(persistence))
        }

        private func path(_ repo: String) -> String { "/Users/dev/code/\(repo)" }

        private func fillEvents() {
            let now = Date()
            // A prompt that can still be answered: its FIFO exists and its hook
            // is alive, which is what makes the footer offer Approve. The FIFO is
            // a plain file nobody writes to, and the hook is this process.
            let fifo = scratch.appendingPathComponent("prompt.fifo")
            FileManager.default.createFile(atPath: fifo.path, contents: nil)
            // Oldest first: each append goes on top.
            store.append(NudgeEvent(agent: "codex", kind: .stop, title: "Codex", message: "Done",
                                    projectPath: path("infra"), timestamp: now.addingTimeInterval(-41 * 60)))
            store.append(NudgeEvent(agent: "github", kind: .other, title: "Review requested",
                                    message: "Add rate limiting to the public endpoints",
                                    timestamp: now.addingTimeInterval(-12 * 60),
                                    source: .github, tag: "review-request", severity: .action,
                                    url: URL(string: "https://github.com/acme/api/pull/318"),
                                    repo: "acme/api", pr: 318))
            store.append(NudgeEvent(agent: "claude", kind: .stop, title: "Claude Code", message: "Done",
                                    projectPath: path("docs"), timestamp: now.addingTimeInterval(-3 * 60)))
            store.append(NudgeEvent(agent: "claude", kind: .permission, title: "Claude Code",
                                    message: "npm test -- --coverage", projectPath: path("web-app"),
                                    hasActionButton: true, timestamp: now.addingTimeInterval(-20),
                                    fifoPath: fifo.path, hookPID: Int(getpid())))
        }

        private func fillSessions() {
            let now = Date()
            func session(_ pid: Int, _ agent: String, _ repo: String, _ elapsed: String,
                         busy: Bool, name: String? = nil, quietFor: TimeInterval) -> Session {
                var s = Session(id: pid, pid: pid, agent: agent, projectPath: path(repo), projectName: repo,
                                terminalPID: nil, terminalApp: "iTerm2", elapsed: elapsed,
                                customName: name, status: .active)
                s.liveStatus = busy ? "busy" : "idle"
                s.lastActivityAt = now.addingTimeInterval(-quietFor)
                return s
            }
            sessions.showFixture([
                session(4101, "claude", "web-app", "42:10", busy: true, quietFor: 6),
                session(4102, "claude", "api", "1:12:03", busy: false, name: "rate limits", quietFor: 4 * 60),
                session(4103, "codex", "infra", "18:44", busy: true, quietFor: 12),
                session(4104, "gemini", "docs", "05:31", busy: false, quietFor: 2 * 60),
            ])
        }

        private func fillUsage() {
            let now = Date()
            nav.quota = QuotaSnapshot(
                fiveHour: QuotaTier(utilization: 38, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60),
                                    windowLength: 5 * 3600),
                sevenDay: QuotaTier(utilization: 61, resetsAt: now.addingTimeInterval(3 * 86_400 + 5 * 3600),
                                    windowLength: 7 * 86_400),
                // Two bars, so the pane fits the default height without scrolling.
                sevenDayOpus: nil, sevenDaySonnet: nil,
                planType: "max")
            nav.codexQuota = CodexQuotaSnapshot(
                primary: QuotaTier(utilization: 22, resetsAt: now.addingTimeInterval(3 * 3600),
                                   windowLength: 5 * 3600),
                secondary: QuotaTier(utilization: 47, resetsAt: now.addingTimeInterval(4 * 86_400),
                                     windowLength: 7 * 86_400),
                planType: "plus")
            nav.quotaUpdatedAt = [.claude: now.addingTimeInterval(-40), .codex: now.addingTimeInterval(-40)]
        }

        private func fillOutcomes() {
            let ledger = nav.handoffLedger
            // (session, agent, repo, branch, ticket, tokens, outcome)
            let work: [(String, String, String, String, String?, Int, OutcomeStatus)] = [
                ("s1", "claude", "web-app", "feat/app-142-checkout", "APP-142", 182_000, .merged),
                ("s2", "claude", "web-app", "feat/app-142-checkout", "APP-142", 64_000, .merged),
                ("s3", "codex", "api", "feat/app-151-rate-limits", "APP-151", 121_000, .pushed),
                ("s4", "claude", "api", "fix/app-149-timeouts", "APP-149", 48_000, .merged),
                ("s5", "codex", "infra", "chore/upgrade-terraform", nil, 37_000, .committed),
                ("s6", "claude", "docs", "docs/getting-started", nil, 22_000, .needsReview),
            ]
            for (id, agent, repo, branch, ticket, tokens, outcome) in work {
                ledger.upsert(id: id + "\n" + branch, agent: agent) { r in
                    r.repoRoot = path(repo)
                    r.branch = branch
                    r.ticket = ticket
                    r.model = agent == "claude" ? "claude-sonnet-5-5" : "gpt-5.5-codex"
                    r.contextTokens = tokens
                }
                nav.outcomeByBranch[PanelNav.outcomeKey(path(repo), branch)] = outcome
            }
            nav.handoffsRevision += 1
        }
    }

    // MARK: - Capture

    private static func render(_ scenario: Scenario, to path: String) throws {
        let (view, settle) = scenario.make()
        let size = NSSize(width: scenario.width, height: scenario.height)
        let hosting = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderBack(nil)
        spin()
        settle()
        spin()
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "render-screenshots", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "render-screenshots", code: 2)
        }
        try png.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }

    private static func spin() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }
}
