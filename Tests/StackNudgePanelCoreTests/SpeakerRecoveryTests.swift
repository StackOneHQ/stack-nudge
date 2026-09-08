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

    func test_sayRecovery_givesUpOnDeterministicClientError() {
        // Exit 1 == empty text or a failed --normalize: deterministic, so a
        // retry fails identically. Recovering would also cancel any utterance
        // currently playing for nothing, so only exit 2 (daemon "busy") retries.
        let actual = Speaker.sayRecovery(exitCode: 1, terminatedBySignal: false, attempt: 1)
        XCTAssertEqual(actual, .giveUp)
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

    // MARK: - retryStillValid

    func test_retryStillValid_trueWhenGenerationUnchanged() {
        // No Mute/Quit happened during the retry delay — safe to speak.
        XCTAssertTrue(Speaker.retryStillValid(scheduled: 3, current: 3))
    }

    func test_retryStillValid_falseWhenGenerationAdvanced() {
        // stopAllAudio() bumped the generation in the gap (user muted or quit) —
        // the scheduled retry must not spawn a fresh utterance.
        XCTAssertFalse(Speaker.retryStillValid(scheduled: 3, current: 4))
    }
}
