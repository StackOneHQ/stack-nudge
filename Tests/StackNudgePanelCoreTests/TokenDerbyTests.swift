import XCTest

@testable import StackNudgePanelCore

// Payloads are shaped like the ones the live service returns, so the parser and
// the wire format can't drift apart unnoticed — the derby is a third party and
// we find out about its changes by breaking.
final class TokenDerbyTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    private let raceJSON = """
    {"race_id":"r1","name":"StackOne Token League","join_code":"AEGEMQ","status":"live",
     "time_left_seconds":22157,"server_time":"2026-09-15T10:50:42.199Z",
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
        XCTAssertEqual(race?.timeLeftSeconds, 22157)
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
