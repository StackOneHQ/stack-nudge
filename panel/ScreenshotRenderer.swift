import AppKit
import SwiftUI

// Dev-only: renders the Extensions pages from fixture state into PNGs, for
// reviewers to see each screen without installing anything.
//
//     StackNudge.app/Contents/MacOS/stack-nudge --render-screenshots <dir>
//
// The real SwiftUI views, at the panel's default size, in dark appearance, in
// an offscreen window captured with cacheDisplay, which needs no Screen
// Recording permission. Everything shown is a fixture: it never reads the
// config file or the extensions directory, and every write path is stubbed,
// so nothing it does can reach the user's setup. scripts/render-screenshots.sh
// builds the app and runs this.
enum ScreenshotRenderer {

    static let flag = "--render-screenshots"
    static let size = NSSize(width: 600, height: 340)

    static func runIfAsked() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag) else { return }
        let directory = i + 1 < args.count ? args[i + 1] : FileManager.default.currentDirectoryPath
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for scenario in scenarios {
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
        // Taller than the panel's default where the point of the picture is
        // below the fold (the "N more" line under ten rows).
        var height: CGFloat = ScreenshotRenderer.size.height
        // Builds the view; the second closure, run once it is on screen, puts
        // it in the state the picture is of (a pick started, a row selected).
        let make: () -> (AnyView, () -> Void)
    }

    static let scenarios: [Scenario] = [
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
        Scenario(name: "browse-default", height: 620) {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), { catalog.selection = .row("away") })
        },
        Scenario(name: "browse-search") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), { catalog.query = "slack" })
        },
        Scenario(name: "browse-confirm") {
            let (catalog, host) = fixtureCatalog()
            return (browser(catalog, host), {
                catalog.selection = .row("radar")
                catalog.requestInstall(catalog.entries.first { $0.id == "radar" }!)
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
        let entries = published.map { id, name, description, tier, requires in
            ExtensionInstaller.IndexEntry(id: id, name: name, version: id == "derby" ? "1.2.0" : "1.1.0",
                                          description: description, asset: "extension-\(id)-1.1.0.tar.gz",
                                          sha256: "ab", requires: requires, config: [], tier: tier)
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

    // MARK: - Capture

    private static func render(_ scenario: Scenario, to path: String) throws {
        let (view, settle) = scenario.make()
        let size = NSSize(width: Self.size.width, height: scenario.height)
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
