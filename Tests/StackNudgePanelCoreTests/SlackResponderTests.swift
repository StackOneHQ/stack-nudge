import XCTest

@testable import StackNudgePanelCore

// The decision matrix for answering a permission prompt from Slack. Every case
// here is reachable from a phone and ends in either running a command on this
// machine or refusing to — so the interesting tests are the ones about *not*
// acting.
final class SlackResponderTests: XCTestCase {

    private let me = "U0A8PS4B79D"
    private let someoneElse = "U9999999999"

    // Built the way Slack documents a reactions.get payload, so the parser and
    // the shape it expects stay pinned together. (#169 shipped a format string
    // and a parser tested only on one half; the format could then be broken
    // silently. Same trap, so the fixture goes through the real extractor.)
    private func payload(_ reactions: [(name: String, users: [String])]) -> [String: Any] {
        [
            "ok": true,
            "type": "message",
            "message": [
                "type": "message",
                "text": "Claude Code in stackone needs permission",
                "reactions": reactions.map { ["name": $0.name, "users": $0.users, "count": $0.users.count] },
            ],
        ]
    }

    private func decide(_ reactions: [(name: String, users: [String])],
                        mode: SlackResponder.Mode = .allowAndDeny,
                        detailOn: Bool = true,
                        memberID: String? = nil) -> SlackResponder.Decision? {
        // Deliberately goes through the real extractor rather than passing the
        // array straight in, so a change to the payload shape fails here too.
        let list = SlackResponder.reactions(fromPayload: payload(reactions)) ?? []
        return SlackResponder.decision(fromReactions: list,
                                       memberID: memberID ?? me,
                                       mode: mode, detailOn: detailOn)
    }

    // MARK: - Reading the reaction

    func test_tickAllows() {
        XCTAssertEqual(decide([("white_check_mark", [me])]), .allow)
    }

    func test_crossDenies() {
        XCTAssertEqual(decide([("x", [me])]), .deny)
    }

    func test_alternativeSpellingsAreAccepted() {
        for name in SlackResponder.allowNames {
            XCTAssertEqual(decide([(name, [me])]), .allow, "\(name) should allow")
        }
        for name in SlackResponder.denyNames {
            XCTAssertEqual(decide([(name, [me])]), .deny, "\(name) should deny")
        }
    }

    func test_noReactionsIsNoAnswer() {
        XCTAssertNil(decide([]))
    }

    // An unrelated emoji must not resolve a prompt — people react to things.
    func test_unrelatedEmojiIsIgnored() {
        XCTAssertNil(decide([("tada", [me]), ("eyes", [me])]))
    }

    // Slack appends a skin tone to the name; the base emoji still counts.
    func test_skinToneVariantsStillCount() {
        XCTAssertEqual(decide([("+1::skin-tone-4", [me])]), .allow)
    }

    // Deny wins: a tick then a cross is somebody correcting themselves, and the
    // safe reading of an ambiguous instruction to run a command is "don't".
    func test_bothPresentDenies() {
        XCTAssertEqual(decide([("white_check_mark", [me]), ("x", [me])]), .deny)
        XCTAssertEqual(decide([("x", [me]), ("white_check_mark", [me])]), .deny)
    }

    // MARK: - Who reacted

    // The whole point of checking the users array. Honouring "a reaction exists"
    // would let anyone else in the conversation approve a command here.
    func test_someoneElsesReactionIsIgnored() {
        XCTAssertNil(decide([("white_check_mark", [someoneElse])]))
        XCTAssertNil(decide([("x", [someoneElse])]))
    }

    func test_ourReactionCountsAlongsideOthers() {
        XCTAssertEqual(decide([("white_check_mark", [someoneElse, me])]), .allow)
    }

    // Someone else's cross must not deny on our behalf either — the asymmetry
    // would be defensible but it isn't what "only my reactions count" means.
    func test_someoneElsesCrossDoesNotDenyForUs() {
        XCTAssertNil(decide([("x", [someoneElse]), ("tada", [me])]))
    }

    func test_noMemberIDConfiguredResolvesNothing() {
        XCTAssertNil(decide([("x", [me])], memberID: ""))
    }

    // MARK: - Mode and the detail gate

    func test_offNeverResolves() {
        XCTAssertNil(decide([("x", [me])], mode: .off))
        XCTAssertNil(decide([("white_check_mark", [me])], mode: .off))
    }

    func test_denyOnlyDeniesButNeverAllows() {
        XCTAssertEqual(decide([("x", [me])], mode: .denyOnly), .deny)
        XCTAssertNil(decide([("white_check_mark", [me])], mode: .denyOnly))
    }

    // With detail off the DM says only "Claude Code in stackone needs
    // permission" — ticking that approves a command you cannot see.
    func test_allowRequiresMessageDetail() {
        XCTAssertNil(decide([("white_check_mark", [me])], detailOn: false))
        XCTAssertEqual(decide([("white_check_mark", [me])], detailOn: true), .allow)
    }

    // ...but denying blind is safe, so the gate must not take deny with it.
    func test_denyStillWorksWithoutDetail() {
        XCTAssertEqual(decide([("x", [me])], detailOn: false), .deny)
        XCTAssertEqual(decide([("x", [me])], mode: .denyOnly, detailOn: false), .deny)
    }

    func test_canAllow_matrix() {
        XCTAssertTrue(SlackResponder.canAllow(mode: .allowAndDeny, detailOn: true))
        XCTAssertFalse(SlackResponder.canAllow(mode: .allowAndDeny, detailOn: false))
        XCTAssertFalse(SlackResponder.canAllow(mode: .denyOnly, detailOn: true))
        XCTAssertFalse(SlackResponder.canAllow(mode: .off, detailOn: true))
    }

    // The row must not advertise a capability the detail switch is withholding.
    func test_rowLabelTellsTheTruthWhenDetailIsOff() {
        XCTAssertEqual(SlackResponder.rowLabel(mode: .allowAndDeny, detailOn: true), "Allow + deny")
        XCTAssertEqual(SlackResponder.rowLabel(mode: .allowAndDeny, detailOn: false),
                       "Deny only (needs detail)")
        XCTAssertEqual(SlackResponder.rowLabel(mode: .denyOnly, detailOn: false), "Deny only")
        XCTAssertEqual(SlackResponder.rowLabel(mode: .off, detailOn: true), "Off")
    }

    // Cycle rows index into allCases by value, so a reordering would make ←/→
    // jump and Off must stay the first (default) entry.
    func test_modeOrderIsStableWithOffFirst() {
        XCTAssertEqual(SlackResponder.Mode.allCases.first, .off)
        XCTAssertEqual(SlackResponder.Mode.allCases.count, 3)
        XCTAssertEqual(Set(SlackResponder.Mode.allCases.map(\.rawValue)).count, 3)
    }

    // MARK: - Payload handling

    func test_messageWithNoReactionsKeyIsNoAnswerNotAnError() {
        let json: [String: Any] = ["ok": true, "message": ["text": "hi"]]
        XCTAssertEqual(SlackResponder.reactions(fromPayload: json)?.count, 0)
    }

    func test_failedPayloadYieldsNilRatherThanEmpty() {
        // nil and [] must stay distinguishable: [] means "asked, nobody has
        // reacted", nil means "we never got an answer" — only the latter is
        // worth surfacing as an error.
        XCTAssertNil(SlackResponder.reactions(fromPayload: ["ok": false, "error": "missing_scope"]))
    }

    // Slack names the scope it wanted, which beats hardcoding one that could
    // drift — verified live: {"error":"missing_scope","needed":"reactions:read"}.
    func test_explain_namesTheScopeSlackAskedFor() {
        let message = SlackResponder.explain(payload: [
            "ok": false, "error": "missing_scope", "needed": "reactions:read",
        ])
        XCTAssertEqual(message?.contains("reactions:read"), true)
    }

    func test_explain_fallsBackToTheSharedTranslations() {
        XCTAssertEqual(SlackResponder.explain(payload: ["ok": false, "error": "invalid_auth"]),
                       SlackNotifier.explain("invalid_auth"))
    }

    func test_explain_silentOnSuccess() {
        XCTAssertNil(SlackResponder.explain(payload: ["ok": true]))
    }

    // MARK: - Expiry notice

    // A reaction that arrives after the hook gave up does nothing, and silence
    // there is indistinguishable from a reaction that failed — which is the
    // exact failure that made the original user-token build worthless.
    func test_expiry_announcedWhenItAgedOutUnanswered() {
        XCTAssertTrue(SlackResponder.shouldAnnounceExpiry(
            age: 550, lifetime: 550, announced: true, resolvedByUs: false))
        // The 5s ticker means a watch is noticed slightly late; the margin keeps
        // that from silently skipping the notice.
        XCTAssertTrue(SlackResponder.shouldAnnounceExpiry(
            age: 545, lifetime: 550, announced: true, resolvedByUs: false))
    }

    // Retiring early means it was answered at the machine — no DM for that.
    func test_expiry_silentWhenAnsweredElsewhere() {
        XCTAssertFalse(SlackResponder.shouldAnnounceExpiry(
            age: 30, lifetime: 550, announced: true, resolvedByUs: false))
    }

    func test_expiry_silentWhenWeResolvedIt() {
        XCTAssertFalse(SlackResponder.shouldAnnounceExpiry(
            age: 550, lifetime: 550, announced: true, resolvedByUs: true))
    }

    // No DM was sent, so there is no message anyone could have reacted to.
    func test_expiry_silentWhenNeverAnnounced() {
        XCTAssertFalse(SlackResponder.shouldAnnounceExpiry(
            age: 550, lifetime: 550, announced: false, resolvedByUs: false))
    }
}
