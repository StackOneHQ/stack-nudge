import XCTest

@testable import StackNudgePanelCore

final class SlackCredentialsTests: XCTestCase {

    // MARK: - Paste classification

    func test_classifiesABareBotToken() {
        XCTAssertEqual(SlackCredentials.classify("xoxb-EXAMPLE-NOT-A-REAL-TOKEN"),
                       .botToken("xoxb-EXAMPLE-NOT-A-REAL-TOKEN"))
    }

    // Clipboards pick up trailing newlines constantly — from a terminal, a
    // password manager, a docs page.
    func test_tolerantOfSurroundingWhitespace() {
        XCTAssertEqual(SlackCredentials.classify("  xoxb-EXAMPLE-NOT-A-REAL-TOKEN\n"),
                       .botToken("xoxb-EXAMPLE-NOT-A-REAL-TOKEN"))
        XCTAssertEqual(SlackCredentials.classify("\nU012ABCDEF  "),
                       .memberID("U012ABCDEF"))
    }

    // A user token would store fine and then fail at send time with an error
    // that explains nothing. This whole design exists *because* user tokens
    // can't notify, so refusing one at the door is the honest place to say so.
    func test_rejectsAUserToken() {
        XCTAssertEqual(SlackCredentials.classify("xoxp-EXAMPLE-NOT-A-REAL-TOKEN"), .unrecognised)
        XCTAssertNil(SlackCredentials.validBotToken("xoxp-EXAMPLE-NOT-A-REAL-TOKEN"))
    }

    func test_classifiesMemberIDs() {
        XCTAssertEqual(SlackCredentials.classify("U012ABCDEF"), .memberID("U012ABCDEF"))
        // Enterprise Grid ids start with W.
        XCTAssertEqual(SlackCredentials.classify("W012ABCDEF"), .memberID("W012ABCDEF"))
    }

    func test_rejectsThingsThatOnlyLookLikeMemberIDs() {
        // Lowercase, too short, and a leading letter that isn't U or W.
        for candidate in ["u012abcdef", "U012", "X012ABCDEF", "Ubcdefghij"] {
            XCTAssertEqual(SlackCredentials.classify(candidate), .unrecognised, candidate)
        }
    }

    // The point of the JSON form: one password-manager entry, one paste.
    func test_classifiesAJSONBlobCarryingBoth() {
        let blob = #"{"bot_token": "xoxb-EXAMPLE-NOT-A-REAL-TOKEN", "member_id": "U012ABCDEF"}"#
        XCTAssertEqual(SlackCredentials.classify(blob),
                       .both(token: "xoxb-EXAMPLE-NOT-A-REAL-TOKEN", memberID: "U012ABCDEF"))
    }

    func test_partialJSONYieldsWhicheverHalfIsValid() {
        XCTAssertEqual(SlackCredentials.classify(#"{"bot_token": "xoxb-EXAMPLE-NOT-A-REAL-TOKEN"}"#),
                       .botToken("xoxb-EXAMPLE-NOT-A-REAL-TOKEN"))
        XCTAssertEqual(SlackCredentials.classify(#"{"member_id": "U012ABCDEF"}"#),
                       .memberID("U012ABCDEF"))
        // A blob whose fields are present but junk shouldn't half-configure.
        XCTAssertEqual(SlackCredentials.classify(#"{"bot_token": "nope", "member_id": "nope"}"#),
                       .unrecognised)
    }

    func test_rejectsEmptyAndGarbage() {
        XCTAssertEqual(SlackCredentials.classify(""), .unrecognised)
        XCTAssertEqual(SlackCredentials.classify("   \n "), .unrecognised)
        XCTAssertEqual(SlackCredentials.classify("hello world"), .unrecognised)
        XCTAssertEqual(SlackCredentials.classify("{not json"), .unrecognised)
    }

    // MARK: - Provisioning migration

    // The riskiest path a secret takes here, and previously untested because it
    // hardcoded the real config file and the real Keychain.

    func test_adoptMovesTheTokenAndScrubsTheLine() {
        var stored: String?
        var scrubbed: [String] = []
        let adopted = SlackCredentials.adoptFromConfig(
            read: { [SlackCredentials.configTokenKey: "  xoxb-EXAMPLE-NOT-A-REAL-TOKEN\n"] },
            store: { stored = $0; return true },
            scrub: { scrubbed.append($0) })

        XCTAssertTrue(adopted)
        XCTAssertEqual(stored, "xoxb-EXAMPLE-NOT-A-REAL-TOKEN")  // trimmed
        XCTAssertEqual(scrubbed, [SlackCredentials.configTokenKey])
    }

    // The bug this guards: store used to be fire-and-forget, so a locked
    // keychain at launch deleted the plaintext while failing to save it, leaving
    // the token in neither place and Settings reading a bland "not configured".
    func test_aFailedStoreLeavesTheConfigLineAlone() {
        var scrubbed: [String] = []
        let adopted = SlackCredentials.adoptFromConfig(
            read: { [SlackCredentials.configTokenKey: "xoxb-EXAMPLE-NOT-A-REAL-TOKEN"] },
            store: { _ in false },          // e.g. errSecInteractionNotAllowed
            scrub: { scrubbed.append($0) })

        XCTAssertFalse(adopted)
        XCTAssertTrue(scrubbed.isEmpty, "a failed store must not destroy the only copy")
    }

    func test_adoptIsANoOpWithNothingToMigrate() {
        var touched = false
        for contents in [[:], [SlackCredentials.configTokenKey: "   "]] as [[String: String]] {
            XCTAssertFalse(SlackCredentials.adoptFromConfig(
                read: { contents },
                store: { _ in touched = true; return true },
                scrub: { _ in touched = true }))
        }
        XCTAssertFalse(touched)
    }

    // MARK: - Config scrubbing

    // The provisioning promise: a token planted for a setup script must not
    // survive in plaintext, and nothing around it may be disturbed.
    func test_stripRemovesOnlyTheNamedKey() {
        let before = """
            # StackNudge config
            STACKNUDGE_BANNER=true
            STACKNUDGE_SLACK_BOT_TOKEN=xoxb-secret
            STACKNUDGE_SLACK_MEMBER_ID=U012ABCDEF
            """
        let after = ConfigFile.strip(before, key: "STACKNUDGE_SLACK_BOT_TOKEN")
        XCTAssertFalse(after.contains("xoxb-secret"))
        XCTAssertTrue(after.contains("STACKNUDGE_BANNER=true"))
        XCTAssertTrue(after.contains("STACKNUDGE_SLACK_MEMBER_ID=U012ABCDEF"))
        XCTAssertTrue(after.contains("# StackNudge config"))
    }

    func test_stripIsIdempotentAndSafeOnAMissingKey() {
        let contents = "STACKNUDGE_BANNER=true\n"
        let once = ConfigFile.strip(contents, key: "STACKNUDGE_SLACK_BOT_TOKEN")
        XCTAssertEqual(ConfigFile.strip(once, key: "STACKNUDGE_SLACK_BOT_TOKEN"), once)
        XCTAssertTrue(once.contains("STACKNUDGE_BANNER=true"))
    }

    // A commented-out example line isn't an assignment and shouldn't be eaten.
    func test_stripLeavesCommentsAlone() {
        let contents = "# STACKNUDGE_SLACK_BOT_TOKEN=xoxb-example\nSTACKNUDGE_BANNER=true\n"
        XCTAssertTrue(ConfigFile.strip(contents, key: "STACKNUDGE_SLACK_BOT_TOKEN")
            .contains("# STACKNUDGE_SLACK_BOT_TOKEN=xoxb-example"))
    }

    // The config file carries secrets during provisioning and is read by anything
    // the user runs, so it must not be world-readable. Writes to a temp path
    // rather than the real config — a test has no business mutating the user's
    // settings, and CI has no ~/.stack-nudge at all.
    func test_configFileIsWrittenOwnerOnly() throws {
        let dir = NSTemporaryDirectory() + "sn-cfg-\(UUID().uuidString)"
        let path = dir + "/config"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        ConfigFile.persist("STACKNUDGE_BANNER=true\n", to: path)

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
    }

    // The parent directory won't exist before Bootstrap has run, and a write that
    // silently no-ops there would lose a provisioned token.
    func test_persistCreatesTheDirectory() throws {
        let dir = NSTemporaryDirectory() + "sn-cfg-\(UUID().uuidString)"
        let path = dir + "/nested/config"
        defer { try? FileManager.default.removeItem(atPath: dir) }

        ConfigFile.persist("A=1\n", to: path)

        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "A=1\n")
    }
}
