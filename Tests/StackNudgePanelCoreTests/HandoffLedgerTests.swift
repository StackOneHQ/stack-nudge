import XCTest

@testable import StackNudgePanelCore

// HandoffLedger is the per-session store the ticket rollup reads. These pin the
// upsert-by-session-id semantics (one row per session, merge not append),
// reload-from-disk, and age/count retention.
final class HandoffLedgerTests: XCTestCase {

    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("handoffs-\(UUID().uuidString).jsonl")
    }

    func test_upsert_createsThenMergesBySessionId() {
        let url = tempURL()
        let ledger = HandoffLedger(path: url)
        ledger.upsert(id: "s1", agent: "codex") { $0.ticket = "ENG-1"; $0.contextTokens = 1000 }
        ledger.upsert(id: "s1", agent: "codex") { $0.contextTokens = 2500 }  // next turn

        let all = ledger.all()
        XCTAssertEqual(all.count, 1)                  // merged, not appended
        XCTAssertEqual(all.first?.ticket, "ENG-1")    // earlier-set field preserved
        XCTAssertEqual(all.first?.contextTokens, 2500) // latest usage wins
    }

    func test_separateSessionsAreSeparateRecords() {
        let ledger = HandoffLedger(path: tempURL())
        ledger.upsert(id: "s1", agent: "codex") { $0.ticket = "ENG-1" }
        ledger.upsert(id: "s2", agent: "claude") { $0.ticket = "ENG-2" }
        XCTAssertEqual(Set(ledger.all().map(\.id)), ["s1", "s2"])
    }

    func test_survivesReloadFromDisk() {
        let url = tempURL()
        let writer = HandoffLedger(path: url)
        writer.upsert(id: "s1", agent: "agy") { $0.ticket = "PROJ-9"; $0.contextTokens = 42 }

        let reader = HandoffLedger(path: url)   // fresh instance, same file
        XCTAssertEqual(reader.all().first?.ticket, "PROJ-9")
        XCTAssertEqual(reader.all().first?.contextTokens, 42)
    }

    func test_countRetention_keepsNewest() {
        let ledger = HandoffLedger(path: tempURL(), maxCount: 2)
        for i in 1...4 { ledger.upsert(id: "s\(i)", agent: "codex") { $0.contextTokens = i } }
        let ids = ledger.all().map(\.id)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids), ["s3", "s4"])  // oldest two pruned
    }

    func test_remove_dropsByID() {
        let ledger = HandoffLedger(path: tempURL())
        ledger.upsert(id: "s1", agent: "codex") { $0.ticket = "ENG-1" }
        ledger.upsert(id: "s2", agent: "claude") { $0.ticket = "ENG-2" }
        ledger.remove(ids: ["s1"])
        XCTAssertEqual(ledger.all().map(\.id), ["s2"])
    }

    func test_pruneOnInit_dropsStaleAtLoad() {
        let url = tempURL()
        // A 2020-dated record on disk should be gone after init, with no upsert.
        let old = #"{"id":"old","agent":"codex","createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}"# + "\n"
        try? old.write(to: url, atomically: true, encoding: .utf8)
        let ledger = HandoffLedger(path: url, maxAgeDays: 90)
        XCTAssertTrue(ledger.all().isEmpty)
    }

    func test_ageRetention_dropsStaleOnNextWrite() {
        let url = tempURL()
        // Pre-seed a 2020-dated record directly (the API always stamps
        // updatedAt = now, so we can't backdate through it).
        let old = #"{"id":"old","agent":"codex","createdAt":"2020-01-01T00:00:00Z","updatedAt":"2020-01-01T00:00:00Z"}"# + "\n"
        try? old.write(to: url, atomically: true, encoding: .utf8)

        let ledger = HandoffLedger(path: url, maxAgeDays: 90)
        ledger.upsert(id: "new", agent: "codex") { $0.contextTokens = 1 }  // triggers prune
        XCTAssertEqual(ledger.all().map(\.id), ["new"])  // 2020 record aged out
    }
}
