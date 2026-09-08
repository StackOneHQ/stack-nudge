import XCTest

@testable import StackNudgePanelCore

final class SpeakerRecoveryTests: XCTestCase {

    // MARK: - sayRecovery

    func test_sayRecovery_acceptsCleanExit() {
        let actual = Speaker.sayRecovery(exitCode: 0, terminatedBySignal: false, attempt: 1)
        XCTAssertEqual(actual, .accepted)
    }

    func test_sayRecovery_retriesOnBusyFirstAttempt() {
        // CLI exit 2 == daemon replied "busy" (queue full / worker wedged).
        let actual = Speaker.sayRecovery(exitCode: 2, terminatedBySignal: false, attempt: 1)
        XCTAssertEqual(actual, .retry)
    }

    func test_sayRecovery_givesUpAfterFinalAttempt() {
        let actual = Speaker.sayRecovery(
            exitCode: 2, terminatedBySignal: false, attempt: Speaker.maxSayAttempts)
        XCTAssertEqual(actual, .giveUp)
    }

    func test_sayRecovery_retriesOnAnyNonZeroExit() {
        // A non-busy failure (e.g. transient client error) is still worth one
        // cancel+retry — cancel is a harmless no-op when the daemon is down.
        let actual = Speaker.sayRecovery(exitCode: 1, terminatedBySignal: false, attempt: 1)
        XCTAssertEqual(actual, .retry)
    }

    func test_sayRecovery_givesUpWhenKilledBySignal() {
        // Quit / stopAllAudio SIGTERMs the client — do not resurrect audio the
        // user is silencing, even though the exit status is non-zero.
        let actual = Speaker.sayRecovery(exitCode: 15, terminatedBySignal: true, attempt: 1)
        XCTAssertEqual(actual, .giveUp)
    }

    func test_sayRecovery_signalKillWinsOverCleanExitCode() {
        // Defensive: a signal-terminated process should never be read as
        // accepted, whatever its reported exit code happens to be.
        let actual = Speaker.sayRecovery(exitCode: 0, terminatedBySignal: true, attempt: 1)
        XCTAssertEqual(actual, .giveUp)
    }
}
