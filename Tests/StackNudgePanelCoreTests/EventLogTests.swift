import XCTest

@testable import StackNudgePanelCore

final class EventLogTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    private func record(_ message: String,
                        at: Date? = nil,
                        agent: String = "claude-code",
                        kind: String = "stop",
                        project: String? = "/Users/x/Workspace/attack-lib") -> EventRecord {
        EventRecord(at: at ?? now, agent: agent, kind: kind,
                    title: "Claude Code — attack-lib", message: message,
                    project: project, session: "sess-1")
    }

    // MARK: - Round trip

    func test_encodeDecodeRoundTrip() {
        let original = record("Bash(rm -rf build/)")
        guard let line = EventLog.encode(original) else { return XCTFail("encode failed") }
        XCTAssertEqual(EventLog.parse(line), [original])
    }

    // One record per line is the format's only invariant — a pretty-printed
    // encoder would silently corrupt every subsequent read.
    func test_encodeProducesASingleLine() {
        guard let line = EventLog.encode(record("a\nb")) else { return XCTFail("encode failed") }
        XCTAssertFalse(line.contains("\n"))
    }

    func test_parseReadsMultipleRecordsInFileOrder() {
        let lines = [record("first", at: ago(300)), record("second", at: ago(100))]
            .compactMap(EventLog.encode).joined(separator: "\n")
        XCTAssertEqual(EventLog.parse(lines).map(\.message), ["first", "second"])
    }

    // A crash mid-write, or a hand-edit, must cost one line and not the whole
    // history.
    func test_parseSkipsCorruptLinesWithoutLosingGoodOnes() {
        let good = EventLog.encode(record("kept"))!
        let text = "{ this is not json\n\(good)\n\n{\"at\":1}\n"
        XCTAssertEqual(EventLog.parse(text).map(\.message), ["kept"])
    }

    func test_parseEmptyText() {
        XCTAssertTrue(EventLog.parse("").isEmpty)
        XCTAssertTrue(EventLog.parse("\n\n").isEmpty)
    }

    // MARK: - Retention

    func test_trimDropsRecordsPastMaxAge() {
        let records = [record("old", at: ago(EventLog.maxAge + 60)),
                       record("fresh", at: ago(60))]
        XCTAssertEqual(EventLog.trim(records, now: now).map(\.message), ["fresh"])
    }

    func test_trimKeepsARecordExactlyOnTheCutoff() {
        let records = [record("edge", at: ago(EventLog.maxAge))]
        XCTAssertEqual(EventLog.trim(records, now: now).count, 1)
    }

    // Newest wins once the count ceiling binds, and input stays oldest-first.
    func test_trimEnforcesTheRecordCeilingKeepingNewest() {
        let records = (0..<(EventLog.maxRecords + 50)).map {
            record("m\($0)", at: ago(TimeInterval(EventLog.maxRecords + 50 - $0)))
        }
        let kept = EventLog.trim(records, now: now)
        XCTAssertEqual(kept.count, EventLog.maxRecords)
        XCTAssertEqual(kept.last?.message, "m\(EventLog.maxRecords + 49)")
    }

    // Age is applied before the ceiling, so a burst inside the window can't
    // evict older records that are still inside it until the cap truly binds.
    func test_trimAppliesAgeBeforeTheCeiling() {
        let stale = (0..<10).map { record("stale\($0)", at: ago(EventLog.maxAge + 1000)) }
        let fresh = (0..<10).map { record("fresh\($0)", at: ago(60)) }
        XCTAssertEqual(EventLog.trim(stale + fresh, now: now).count, 10)
    }

    // MARK: - File I/O

    func test_appendThenLoadReturnsNewestFirst() {
        let path = NSTemporaryDirectory() + "sn-log-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let log = EventLog(path: path)
        log.append(record("older", at: ago(300)))
        log.append(record("newer", at: ago(60)))
        log.flush()  // appends are async on the log's private queue

        XCTAssertEqual(log.load(now: now).map(\.message), ["newer", "older"])
    }

    // Retention has to be written back, not just filtered on the way out —
    // otherwise the file grows forever while every load looks clean.
    func test_loadPersistsTheTrim() {
        let path = NSTemporaryDirectory() + "sn-trim-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let log = EventLog(path: path)
        log.append(record("ancient", at: ago(EventLog.maxAge + 5000)))
        log.append(record("fresh", at: ago(60)))
        log.flush()

        XCTAssertEqual(log.load(now: now).map(\.message), ["fresh"])
        log.flush()  // the rewrite is queued behind the load
        XCTAssertEqual(EventLog(path: path).load(now: now).map(\.message), ["fresh"])
    }

    func test_loadOnMissingFileIsEmptyNotAnError() {
        XCTAssertTrue(EventLog(path: NSTemporaryDirectory() + "sn-absent-\(UUID().uuidString)")
            .load(now: now).isEmpty)
    }

    // The log carries prompt and tool text, so it must be no more readable
    // than the config beside it.
    func test_createdFileIsOwnerOnly() {
        let path = NSTemporaryDirectory() + "sn-perm-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let log = EventLog(path: path)
        log.append(record("secret"))
        log.flush()

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attrs?[.posixPermissions] as? NSNumber, 0o600)
    }

    // append() used to treat "couldn't open for writing" as "doesn't exist" and
    // fall through to createFile, which unlinks and replaces — and succeeds
    // whenever the *directory* is writable. A log that ended up read-only (root
    // owned after a sudo run, restored from backup, or chmod'ed by a user who
    // read the note about prompt text) lost a month of history on the next nudge.
    func test_appendNeverReplacesAnUnwritableLog() throws {
        let path = NSTemporaryDirectory() + "sn-ro-\(UUID().uuidString).jsonl"
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                    ofItemAtPath: path)
            try? FileManager.default.removeItem(atPath: path)
        }

        let log = EventLog(path: path)
        log.append(record("kept", at: ago(60)))
        log.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o400],
                                               ofItemAtPath: path)

        log.append(record("should not clobber", at: ago(30)))
        log.flush()

        // The new record is lost — unavoidable on a read-only file — but the
        // existing history must survive.
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("kept"))
    }

    // MARK: - Search

    func test_matchesAcrossMessageAgentAndProject() {
        let r = record("Bash(rm -rf build/)")
        XCTAssertTrue(r.matches("rm -rf"))
        XCTAssertTrue(r.matches("claude"))
        XCTAssertTrue(r.matches("attack-lib"))
        XCTAssertFalse(r.matches("gemini"))
    }

    func test_matchesIsCaseAndDiacriticInsensitive() {
        XCTAssertTrue(record("Café Build").matches("cafe"))
        XCTAssertTrue(record("Café Build").matches("BUILD"))
    }

    func test_emptyQueryMatchesEverything() {
        XCTAssertTrue(record("anything").matches(""))
    }

    // The project field holds a full path; users search by the repo name.
    func test_projectNameIsTheBasename() {
        XCTAssertEqual(record("x").projectName, "attack-lib")
        XCTAssertNil(record("x", project: nil).projectName)
        XCTAssertNil(record("x", project: "").projectName)
    }
}
