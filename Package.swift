// swift-tools-version:5.9
//
// SPM manifest used ONLY for `swift test`. The shipping binaries are still
// built by `swiftc` directly via build.sh — no Xcode, no SPM dependencies.
// Keeping SPM here lets us run a `swift test` suite over the testable bits
// (Hotkey parsing, ConfigFile, NudgeKind, EventStore) without restructuring
// the repo into Sources/<TargetName>/.

import PackageDescription

let package = Package(
    name: "StackNudge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "StackNudgePanelCore", targets: ["StackNudgePanelCore"]),
    ],
    targets: [
        .target(
            name: "StackNudgePanelCore",
            path: ".",
            exclude: [
                // App entry points / resources are not library code.
                "panel/main.swift",
                "panel/Info.plist",
                "panel/entitlements.plist",
                "notifier",

                // Top-level scripts, docs, and build artefacts.
                "Makefile",
                "build.sh",
                "install.sh",
                "uninstall.sh",
                "notify.sh",
                "notify.conf.example",
                "README.md",
                "LICENSE",
                "NOTICE",
                "PRIVACY.md",
                "CONTRIBUTING.md",
                "CODE_OF_CONDUCT.md",
                "SECURITY.md",
                "CHANGELOG.md",
                "ui_improvements.md",

                // Directories not part of the testable surface.
                "build",
                "assets",
                "phrases",
                "hooks",

                // Tests own this directory; declare here so SPM doesn't
                // sweep the test sources into the library target.
                "Tests",
            ],
            sources: ["panel", "shared"]
        ),
        .testTarget(
            name: "StackNudgePanelCoreTests",
            dependencies: ["StackNudgePanelCore"],
            path: "Tests/StackNudgePanelCoreTests"
        ),
    ]
)
