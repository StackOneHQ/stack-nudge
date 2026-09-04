import XCTest

@testable import StackNudgePanelCore

final class SlackDirectoryTests: XCTestCase {

    private func data(_ json: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: json)
    }

    func test_parsesASuccessfulLookup() {
        let payload: [String: Any] = [
            "ok": true,
            "user": [
                "id": "U012ABCDEF",
                "name": "hisku",
                "real_name": "Hiskias Dingeto",
                "profile": ["display_name": "Hisku", "real_name": "Hiskias Dingeto"],
            ],
        ]
        XCTAssertEqual(SlackDirectory.parse(data(payload)),
                       .found(id: "U012ABCDEF", label: "Hisku"))
    }

    // Slack returns display_name as "" for people who never set one, so an
    // emptiness check is needed rather than plain nil-coalescing — otherwise the
    // row would name the user as blank.
    func test_fallsBackThroughTheNameFields() {
        func label(_ user: [String: Any]) -> String? {
            guard case .found(_, let label) =
                SlackDirectory.parse(data(["ok": true, "user": user])) else { return nil }
            return label
        }
        XCTAssertEqual(label(["id": "U1", "profile": ["display_name": "", "real_name": "Real Name"]]),
                       "Real Name")
        XCTAssertEqual(label(["id": "U1", "real_name": "Top Level", "profile": ["display_name": ""]]),
                       "Top Level")
        XCTAssertEqual(label(["id": "U1", "name": "handle"]), "handle")
        // Nothing usable at all — the id is still better than an empty row.
        XCTAssertEqual(label(["id": "U1"]), "U1")
    }

    // These two need to stay distinguishable: one means "paste your member ID",
    // the other means "the bot token needs another scope".
    func test_distinguishesNotFoundFromMissingScope() {
        XCTAssertEqual(SlackDirectory.parse(data(["ok": false, "error": "users_not_found"])),
                       .notFound)
        XCTAssertEqual(SlackDirectory.parse(data(["ok": false, "error": "missing_scope"])),
                       .missingScope)
        XCTAssertEqual(SlackDirectory.parse(data(["ok": false, "error": "not_allowed_token_type"])),
                       .missingScope)
    }

    func test_otherErrorsArePassedThrough() {
        XCTAssertEqual(SlackDirectory.parse(data(["ok": false, "error": "ratelimited"])),
                       .failed("ratelimited"))
    }

    // Slack answers 200 with ok:false, so a success path that ignored `ok` would
    // read every failure as a match.
    func test_okTrueWithNoUserIsAFailureNotAMatch() {
        XCTAssertEqual(SlackDirectory.parse(data(["ok": true])), .failed("no user in response"))
        XCTAssertEqual(SlackDirectory.parse(data(["ok": true, "user": ["id": ""]])),
                       .failed("no user in response"))
    }

    func test_rejectsGarbage() {
        XCTAssertEqual(SlackDirectory.parse(Data("not json".utf8)), .failed("bad json"))
    }
}
