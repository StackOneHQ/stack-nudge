import UserNotifications
import XCTest

@testable import StackNudgePanelCore

final class PromptReplyTests: XCTestCase {

    func test_bannerButtonsAnswerFromTheBanner() {
        XCTAssertEqual(PanelController.bannerReply(to: "ALLOW"), .allow)
        XCTAssertEqual(PanelController.bannerReply(to: "DENY"), .deny)
    }

    func test_swipeAwayDenies() {
        XCTAssertEqual(PanelController.bannerReply(to: UNNotificationDismissActionIdentifier), .deny)
    }

    // Holding on here left Codex with no prompt on screen: it waits for the hook
    // before drawing its own.
    func test_bodyTapReleasesTheHook() {
        XCTAssertEqual(PanelController.bannerReply(to: UNNotificationDefaultActionIdentifier), .release)
    }

    // notify.sh matches these words literally.
    func test_repliesAreTheWordsNotifyShReads() {
        XCTAssertEqual(PromptReply.allow.rawValue, "allow")
        XCTAssertEqual(PromptReply.deny.rawValue, "deny")
        XCTAssertEqual(PromptReply.release.rawValue, "release")
    }
}
