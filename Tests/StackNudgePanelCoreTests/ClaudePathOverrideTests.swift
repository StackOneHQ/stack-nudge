import XCTest

@testable import StackNudgePanelCore

// A launchd-spawned .app has a minimal PATH, so the claude binary is resolved
// from absolute candidates. Version managers put it outside that list, and the
// failure surfaced as "run `claude /usage` to check your session" — which reads
// as wrong to anyone whose terminal runs it fine.
final class ClaudePathOverrideTests: XCTestCase {

    func testOverridePointingAtSomethingExecutableIsUsed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        _ = chmod(binary.path, 0o755)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
    }

    // A path that isn't executable must fall through to nil rather than being
    // handed to Process, which would fail at spawn time instead.
    func testNonExecutableOverrideIsRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-override-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let notExecutable = dir.appendingPathComponent("claude")
        try "not a binary".write(to: notExecutable, atomically: true, encoding: .utf8)

        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: notExecutable.path))
    }
}
