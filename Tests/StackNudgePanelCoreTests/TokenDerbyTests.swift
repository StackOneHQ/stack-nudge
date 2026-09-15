import XCTest

@testable import StackNudgePanelCore

// Payloads are shaped like the ones the live service returns, so the parser and
// the wire format can't drift apart unnoticed — the derby is a third party and
// we find out about its changes by breaking.
final class TokenDerbyTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    private let raceJSON = """
    {"race_id":"r1","name":"StackOne Token League","join_code":"AEGEMQ","status":"live",
     "start_time":"2026-09-15T05:00:00.000Z","end_time":"2026-09-15T17:00:00.000Z",
     "time_left_seconds":21600,"server_time":"2026-09-15T11:00:00.000Z",
     "league_division_names":["Premier Division","Token Munchers","Claude Casuals"],
     "horses":[
       {"horse_id":"h1","name":"black & white","user_name":"Yashika","rank":1,
        "current_tokens":15379466,"scored_tokens":13735759,"pace_15m":76210,"division":1,
        "colors":{"body":"#FFFFFF","mane":"#000000","tail":"#000000","saddle":"#000000"},
        "primary_model":"claude"},
       {"horse_id":"h2","name":"gandalf","user_name":"Kenneth","rank":4,
        "current_tokens":9505493,"scored_tokens":6282480,"pace_15m":39784,"division":3,
        "colors":{"body":"#C8A165"},"primary_model":"claude"},
       {"horse_id":"h3","name":"half","user_name":"Chandrajeet","rank":2,
        "current_tokens":7710910.5,"scored_tokens":7710912,"division":1,
        "colors":{"body":"#E8C89A"},"primary_model":"claude"}
     ]}
    """

    func testParsesALiveRace() {
        let race = DerbyParse.race(from: data(raceJSON))
        XCTAssertEqual(race?.joinCode, "AEGEMQ")
        XCTAssertTrue(race?.isLive == true)
        XCTAssertEqual(race?.timeLeftSeconds, 21600)
        XCTAssertEqual(race?.horses.count, 3)
        XCTAssertEqual(race?.divisionNames.first, "Premier Division")
    }

    // The bar is drawn from what the race is scored on. Using current_tokens put
    // this 4th-placed horse (9.5M raw, 6.3M scored) ahead of 2nd place on screen.
    func testScoredTokensDriveTheBarNotRawUsage() {
        let horses = DerbyParse.race(from: data(raceJSON))?.horses ?? []
        guard let gandalf = horses.first(where: { $0.name == "gandalf" }) else {
            return XCTFail("missing horse")
        }
        XCTAssertEqual(gandalf.tokens, 6282480)
        XCTAssertEqual(gandalf.rawTokens, 9505493)
        XCTAssertEqual(gandalf.rank, 4)
        XCTAssertEqual(DerbyParse.race(from: data(raceJSON))?.leaderTokens, 13735759)
    }

    // current_tokens is an int for some horses and a half-token double for others.
    func testToleratesFractionalTokenCounts() {
        let horses = DerbyParse.race(from: data(raceJSON))?.horses ?? []
        XCTAssertEqual(horses.first(where: { $0.name == "half" })?.rawTokens, 7710910.5)
    }

    func testMissingPaceAndColoursDoNotDropTheHorse() {
        let horses = DerbyParse.race(from: data(raceJSON))?.horses ?? []
        let half = horses.first(where: { $0.name == "half" })
        XCTAssertNotNil(half)
        XCTAssertNil(half?.pace15m)
        XCTAssertEqual(horses.first(where: { $0.name == "black & white" })?.bodyColor, "#FFFFFF")
    }

    func testRejectsPayloadsThatArentARace() {
        XCTAssertNil(DerbyParse.race(from: data("{}")))
        XCTAssertNil(DerbyParse.race(from: data("not json")))
        XCTAssertNil(DerbyParse.race(from: data("[]")))
    }

    // MARK: - Track position

    // Leader-relative alone pinned the front-runner to the finish line from the
    // first minute. Scaling by elapsed time makes the leader's position the
    // race's progress, so the field runs the track instead of sitting on it.
    func testLeaderSitsAtTheRaceProgressNotTheFinishLine() {
        guard let race = DerbyParse.race(from: data(raceJSON)) else { return XCTFail("no race") }
        XCTAssertEqual(race.durationSeconds ?? 0, 12 * 3600, accuracy: 1)
        XCTAssertEqual(race.elapsedFraction, 0.5, accuracy: 0.0001)  // 6h left of 12h
        let leader = race.horses.first { $0.rank == 1 }!
        XCTAssertEqual(race.position(leader), 0.5, accuracy: 0.0001)
    }

    func testTrailingHorsesKeepTheirGapToTheLeader() {
        guard let race = DerbyParse.race(from: data(raceJSON)) else { return XCTFail("no race") }
        let gandalf = race.horses.first { $0.name == "gandalf" }!
        // 6282480 / 13735759 of the way to the leader, at half-distance.
        XCTAssertEqual(race.position(gandalf),
                       (6282480.0 / 13735759.0) * 0.5, accuracy: 0.0001)
    }

    // A finished race is fully run whatever the clock says, and a pending one
    // hasn't started — the field belongs at the gate, not scattered.
    func testFinishedRaceRunsTheFullTrackAndPendingRunsNone() {
        let finished = raceJSON.replacingOccurrences(of: "\"status\":\"live\"", with: "\"status\":\"finished\"")
        XCTAssertEqual(DerbyParse.race(from: data(finished))?.elapsedFraction, 1)
        let pending = raceJSON.replacingOccurrences(of: "\"status\":\"live\"", with: "\"status\":\"pending\"")
        XCTAssertEqual(DerbyParse.race(from: data(pending))?.elapsedFraction, 0)
    }

    // No usable timestamps: don't scatter the field on a guess.
    func testMissingTimestampsLeaveTheFieldAtTheGate() {
        let noTimes = raceJSON
            .replacingOccurrences(of: "\"start_time\":\"2026-09-15T05:00:00.000Z\",", with: "")
            .replacingOccurrences(of: "\"end_time\":\"2026-09-15T17:00:00.000Z\",", with: "")
        let race = DerbyParse.race(from: data(noTimes))
        XCTAssertNil(race?.durationSeconds)
        XCTAssertEqual(race?.elapsedFraction, 0)
    }

    // MARK: - Which race to show

    private let listJSON = """
    {"org_name":"StackOne","races":[
      {"race_id":"a","join_code":"NEW1","name":"Race 8","status":"pending","start_time":"2026-09-16T05:00:00.000Z"},
      {"race_id":"b","join_code":"LIVE1","name":"Race 7","status":"live","start_time":"2026-09-15T05:00:00.000Z"},
      {"race_id":"c","join_code":"OLD1","name":"Race 6","status":"finished","start_time":"2026-09-14T05:00:00.000Z"}
    ]}
    """

    func testPrefersTheLiveRaceOverANewerPendingOne() {
        let picked = DerbyParse.pick(DerbyParse.summaries(from: data(listJSON)))
        XCTAssertEqual(picked?.joinCode, "LIVE1")
    }

    // Nothing running: show the most recent, which the service lists first.
    func testFallsBackToTheNewestRace() {
        let json = listJSON.replacingOccurrences(of: "\"status\":\"live\"", with: "\"status\":\"finished\"")
        XCTAssertEqual(DerbyParse.pick(DerbyParse.summaries(from: data(json)))?.joinCode, "NEW1")
    }

    func testEmptyOrUnparseableListPicksNothing() {
        XCTAssertNil(DerbyParse.pick(DerbyParse.summaries(from: data("{\"races\":[]}"))))
        XCTAssertNil(DerbyParse.pick(DerbyParse.summaries(from: data("nonsense"))))
    }
}

// The tab strip, ⌘-number and ←/→ all read one ordered list. They used to be
// written out separately, which put Derby fifth on screen and on ⌘6.
@MainActor
final class DerbyTabOrderTests: XCTestCase {

    func testDerbySitsBeforeSettingsWhenEnabled() {
        let nav = PanelNav()
        nav.derbyOrg = "StackOne"
        XCTAssertEqual(nav.orderedTabs, [.events, .sessions, .usage, .outcomes, .derby, .settings])
        // ⌘5 is whatever is drawn fifth.
        XCTAssertEqual(nav.orderedTabs[4], .derby)
        XCTAssertEqual(nav.orderedTabs[5], .settings)
    }

    func testSettingsKeepsItsPositionWithoutTheDerby() {
        let nav = PanelNav()
        nav.derbyOrg = nil
        XCTAssertEqual(nav.orderedTabs, [.events, .sessions, .usage, .outcomes, .settings])
        XCTAssertEqual(nav.orderedTabs[4], .settings)
    }

    func testAnEmptyOrgDoesNotConjureATab() {
        let nav = PanelNav()
        nav.derbyOrg = ""
        XCTAssertFalse(nav.derbyEnabled)
        XCTAssertFalse(nav.orderedTabs.contains(.derby))
    }

    // Six digits, so the list must never outgrow them.
    func testTabCountFitsTheNumberRow() {
        let nav = PanelNav()
        nav.derbyOrg = "StackOne"
        XCTAssertLessThanOrEqual(nav.orderedTabs.count, 6)
    }
}
