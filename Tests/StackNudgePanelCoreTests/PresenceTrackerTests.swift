import XCTest
@testable import StackNudgePanelCore

// The rule is what decides to lock a screen, so it's pinned here against the
// numbers measured at a desk: adverts every 2–14 s around -62 to -80 dBm.
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
        XCTAssertEqual(tracker.evaluate(now: at(120), idle: 3), .present)
    }

    func test_phoneGone_andIdle_isAway() {
        var tracker = deskTracker()
        // Last advert at 20 s; 30 s of silence after it.
        XCTAssertEqual(tracker.evaluate(now: at(49), idle: 60), .present)
        XCTAssertEqual(tracker.evaluate(now: at(50), idle: 60), .away)
    }

    func test_weakAverage_andIdle_isAway() {
        var tracker = deskTracker()
        for (i, rssi) in [-90, -92, -93, -91, -94].enumerated() {
            tracker.observe(rssi: rssi, at: at(22 + Double(i)))
        }
        // The average crossed -85 partway through; 10 s on, still weak.
        XCTAssertEqual(tracker.evaluate(now: at(30), idle: 60), .present)
        tracker.observe(rssi: -92, at: at(36))
        XCTAssertEqual(tracker.evaluate(now: at(36), idle: 60), .away)
    }

    func test_oneWeakReading_doesNotSendYouAway() {
        var tracker = deskTracker()
        tracker.observe(rssi: -86, at: at(22))
        tracker.observe(rssi: -66, at: at(25))
        XCTAssertEqual(tracker.evaluate(now: at(40), idle: 600), .present)
    }

    func test_back_onInput() {
        var tracker = deskTracker()
        tracker.evaluate(now: at(60), idle: 60)
        XCTAssertEqual(tracker.state, .away)
        XCTAssertEqual(tracker.evaluate(now: at(61), idle: 0), .present)
    }

    func test_back_onStrongAdvert_butNotAFaintOne() {
        var tracker = deskTracker()
        tracker.evaluate(now: at(60), idle: 60)
        tracker.observe(rssi: -93, at: at(70))
        XCTAssertEqual(tracker.state, .away, "a faint advert from the corridor isn't you back")
        tracker.observe(rssi: -72, at: at(75))
        XCTAssertEqual(tracker.state, .present)
    }

    // The phone went quiet for good (left at home, battery dead). It locks
    // once; after you come back on input, pausing mustn't lock again until the
    // phone is heard.
    func test_phoneGoneForGood_locksOnce_notAfterEveryPause() {
        var tracker = deskTracker()
        XCTAssertEqual(tracker.evaluate(now: at(60), idle: 60), .away)
        XCTAssertEqual(tracker.evaluate(now: at(61), idle: 0), .present)
        XCTAssertEqual(tracker.evaluate(now: at(300), idle: 200), .present)
        // Heard again, then gone again: away is back on the table.
        tracker.observe(rssi: -70, at: at(310))
        XCTAssertEqual(tracker.evaluate(now: at(400), idle: 200), .away)
    }

    // Back on one strong reading while the window still holds weak ones must
    // not flip straight back to away on the next tick.
    func test_backOnStrongAdvert_doesNotFlapBackToAway() {
        var tracker = deskTracker()
        for (i, rssi) in [-90, -91, -92, -90, -93].enumerated() {
            tracker.observe(rssi: rssi, at: at(22 + Double(i)))
        }
        tracker.observe(rssi: -92, at: at(40))
        XCTAssertEqual(tracker.evaluate(now: at(40), idle: 60), .away)
        for (i, rssi) in [-90, -90, -90, -88].enumerated() {
            tracker.observe(rssi: rssi, at: at(41 + Double(i)))
        }
        tracker.observe(rssi: -78, at: at(46))
        XCTAssertEqual(tracker.state, .present)
        // Past weakFor from when the weak run started (41 s): the old code went
        // straight back to away here.
        XCTAssertEqual(tracker.evaluate(now: at(52), idle: 80), .present)
    }

    // The phone charges in the next room, advertising weakly but steadily.
    // It locks once; after you come back on input, pauses mustn't lock again
    // until the phone has been close.
    func test_phoneWeakInNextRoom_locksOnce_notAfterEveryPause() {
        var tracker = deskTracker()
        // The average is down to -88 by 34 s; 10 s of that is leaving.
        for s in stride(from: 22.0, through: 46, by: 3) { tracker.observe(rssi: -88, at: at(s)) }
        XCTAssertEqual(tracker.evaluate(now: at(46), idle: 60), .away)
        XCTAssertEqual(tracker.evaluate(now: at(47), idle: 0), .present)
        for s in stride(from: 49.0, through: 120, by: 3) { tracker.observe(rssi: -88, at: at(s)) }
        XCTAssertEqual(tracker.evaluate(now: at(120), idle: 70), .present)
        // Close again, then off to the next room: away again.
        tracker.observe(rssi: -66, at: at(125))
        for s in stride(from: 128.0, through: 160, by: 3) { tracker.observe(rssi: -90, at: at(s)) }
        XCTAssertEqual(tracker.evaluate(now: at(160), idle: 70), .away)
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
    func test_wait_setsIdleAndSilence() {
        let rule = PresenceTracker.Rule.waiting(45)
        XCTAssertEqual(rule.idleAtLeast, 45)
        XCTAssertEqual(rule.missingAfter, 45)
    }

    // A desk gap of 14 s was measured, so a short wait still won't call a phone
    // lying beside you "gone" while you read.
    func test_shortWait_keepsTheSilenceFloor() {
        let rule = PresenceTracker.Rule.waiting(10)
        XCTAssertEqual(rule.idleAtLeast, 10)
        XCTAssertEqual(rule.missingAfter, PresenceTracker.Rule.minimumSilence)
        XCTAssertEqual(rule.weakFor, 10)
    }

    func test_tenSecondWait_locksTwentySecondsAfterThePhoneGoesQuiet() {
        var tracker = PresenceTracker(rule: .waiting(10))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        tracker.observe(rssi: -70, at: t0)
        XCTAssertEqual(tracker.evaluate(now: t0.addingTimeInterval(16), idle: 16), .present,
                       "a 14 s gap between adverts at the desk isn't leaving")
        XCTAssertEqual(tracker.evaluate(now: t0.addingTimeInterval(20), idle: 20), .away)
    }

    func test_everyWaitOptionIsAValidRule() {
        for s in PanelNav.awayWaitOptions {
            XCTAssertGreaterThanOrEqual(PresenceTracker.Rule.waiting(TimeInterval(s)).missingAfter, 20)
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
