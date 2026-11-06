import XCTest
@testable import StackNudgePanelCore

// The rule is what decides to lock a screen, so it's pinned here against the
// numbers measured: an idle phone on the desk went up to 75 s between adverts,
// at anything from -41 to -99 dBm.
final class PresenceTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    private func deskTracker() -> PresenceTracker {
        var tracker = PresenceTracker()
        for (s, rssi) in [(0.0, -66), (4, -72), (10, -68), (14, -79), (20, -70)] {
            tracker.observe(rssi: rssi, at: at(s))
        }
        return tracker
    }

    func test_phoneAtDesk_staysPresentEvenWhenIdle() {
        var tracker = deskTracker()
        XCTAssertEqual(tracker.evaluate(now: at(25), idle: 600), .present)
    }

    func test_phoneGone_butTyping_staysPresent() {
        var tracker = deskTracker()
        XCTAssertEqual(tracker.evaluate(now: at(600), idle: 3), .present)
    }

    func test_phoneGone_andIdle_isAway() {
        var tracker = deskTracker()
        // Last advert at 20 s; two minutes of silence after it.
        XCTAssertEqual(tracker.evaluate(now: at(139), idle: 600), .present)
        XCTAssertEqual(tracker.evaluate(now: at(140), idle: 600), .away)
    }

    // Recorded with the phone lying idle beside the Mac: a 66 s and a 75 s
    // gap, and a minute of readings in the -90s. The old rule locked on both.
    func test_idlePhoneOnTheDesk_isNeverAway() {
        var tracker = PresenceTracker(rule: .waiting(10))
        let adverts: [(TimeInterval, Int)] = [
            (0, -79), (6, -70), (12, -88), (15, -84),
            (81, -75), (82, -93), (86, -98), (92, -92), (100, -95), (110, -96),
            (122, -98), (126, -93), (136, -94), (146, -89),
            (221, -99), (225, -85),
        ]
        var next = 0
        for s in stride(from: 0.0, through: 240, by: 2) {
            while next < adverts.count && adverts[next].0 <= s {
                tracker.observe(rssi: adverts[next].1, at: at(adverts[next].0))
                next += 1
            }
            XCTAssertEqual(tracker.evaluate(now: at(s), idle: s + 60), .present, "at \(s) s")
        }
    }

    func test_back_onInput() {
        var tracker = deskTracker()
        tracker.evaluate(now: at(200), idle: 200)
        XCTAssertEqual(tracker.state, .away)
        XCTAssertEqual(tracker.evaluate(now: at(201), idle: 0), .present)
    }

    func test_back_onStrongAdvert_butNotAFaintOne() {
        var tracker = deskTracker()
        tracker.evaluate(now: at(200), idle: 200)
        tracker.observe(rssi: -93, at: at(210))
        XCTAssertEqual(tracker.state, .away, "a faint advert from the corridor isn't you back")
        tracker.observe(rssi: -72, at: at(215))
        XCTAssertEqual(tracker.state, .present)
    }

    // The phone went quiet for good (left at home, battery dead). It locks
    // once; after you come back on input, pausing mustn't lock again until the
    // phone is heard.
    func test_phoneGoneForGood_locksOnce_notAfterEveryPause() {
        var tracker = deskTracker()
        XCTAssertEqual(tracker.evaluate(now: at(200), idle: 200), .away)
        XCTAssertEqual(tracker.evaluate(now: at(201), idle: 0), .present)
        XCTAssertEqual(tracker.evaluate(now: at(600), idle: 300), .present)
        // Heard again, then gone again: away is back on the table.
        tracker.observe(rssi: -70, at: at(610))
        XCTAssertEqual(tracker.evaluate(now: at(730), idle: 300), .away)
    }

    func test_neverSeen_isNeverAway() {
        var tracker = PresenceTracker()
        XCTAssertEqual(tracker.evaluate(now: at(600), idle: 600), .present)
    }

    func test_noReadingValue_isIgnored() {
        var tracker = PresenceTracker()
        tracker.observe(rssi: 127, at: at(0))
        XCTAssertNil(tracker.lastSeen)
    }
}

final class PresenceRuleWaitTests: XCTestCase {
    func test_shortWait_setsIdle_andKeepsTheSilenceFloor() {
        let rule = PresenceTracker.Rule.waiting(10)
        XCTAssertEqual(rule.idleAtLeast, 10)
        XCTAssertEqual(rule.missingAfter, PresenceTracker.Rule.minimumSilence)
    }

    func test_tenSecondWait_locksTwoMinutesAfterThePhoneGoesQuiet() {
        var tracker = PresenceTracker(rule: .waiting(10))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        tracker.observe(rssi: -70, at: t0)
        XCTAssertEqual(tracker.evaluate(now: t0.addingTimeInterval(80), idle: 80), .present,
                       "a 75 s gap between adverts at the desk isn't leaving")
        XCTAssertEqual(tracker.evaluate(now: t0.addingTimeInterval(120), idle: 120), .away)
    }

    func test_everyWaitOptionKeepsTheSilenceFloor() {
        for s in PanelNav.awayWaitOptions {
            XCTAssertGreaterThanOrEqual(PresenceTracker.Rule.waiting(TimeInterval(s)).missingAfter, 120)
        }
    }
}

final class NearbyDevicePairedTests: XCTestCase {
    func test_onlyPairedDevicesAreOffered() {
        let now = Date()
        let devices = [
            NearbyDevice(id: UUID(), name: "Hiskias Melke's S25+", rssi: -70, lastSeen: now),
            NearbyDevice(id: UUID(), name: "50\" Crystal UHD", rssi: -45, lastSeen: now),
        ]
        let offered = NearbyDevice.pairedOnly(devices, pairedNames: ["Hiskias Melke's S25+", "ULT WEAR"])
        XCTAssertEqual(offered.map(\.name), ["Hiskias Melke's S25+"])
    }

    func test_nothingPaired_offersNothing() {
        let d = NearbyDevice(id: UUID(), name: "Someone's Pixel", rssi: -60, lastSeen: Date())
        XCTAssertTrue(NearbyDevice.pairedOnly([d], pairedNames: []).isEmpty)
    }
}
