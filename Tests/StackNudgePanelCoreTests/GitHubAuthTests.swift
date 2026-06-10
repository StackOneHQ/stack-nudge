import XCTest

@testable import StackNudgePanelCore

// GitHubAuth parses the OAuth device-flow responses. These pin the device-code
// fields (and interval/expiry defaults) and the poll error → result mapping.
final class GitHubAuthTests: XCTestCase {

    func test_parseDeviceCode_full() {
        let json = """
        {"device_code":"dc","user_code":"4F2A-9C7B",
         "verification_uri":"https://github.com/login/device","interval":5,"expires_in":900}
        """
        let actual = GitHubAuth.parseDeviceCode(Data(json.utf8))
        XCTAssertEqual(actual, DeviceCodeResponse(deviceCode: "dc", userCode: "4F2A-9C7B",
                                                  verificationURI: "https://github.com/login/device",
                                                  interval: 5, expiresIn: 900))
    }

    func test_parseDeviceCode_defaultsWhenIntervalMissing() {
        let json = #"{"device_code":"dc","user_code":"u","verification_uri":"v"}"#
        let actual = GitHubAuth.parseDeviceCode(Data(json.utf8))
        XCTAssertEqual(actual?.interval, 5)
        XCTAssertEqual(actual?.expiresIn, 900)
    }

    func test_parseDeviceCode_malformed_isNil() {
        XCTAssertNil(GitHubAuth.parseDeviceCode(Data("nope".utf8)))
        XCTAssertNil(GitHubAuth.parseDeviceCode(Data(#"{"user_code":"u"}"#.utf8)))
    }

    func test_parsePoll_token() {
        let json = #"{"access_token":"gho_abc","token_type":"bearer","scope":"repo"}"#
        XCTAssertEqual(GitHubAuth.parsePoll(Data(json.utf8)), .token("gho_abc"))
    }

    func test_parsePoll_pending() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data(#"{"error":"authorization_pending"}"#.utf8)), .pending)
    }

    func test_parsePoll_slowDown_carriesInterval() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data(#"{"error":"slow_down","interval":10}"#.utf8)), .slowDown(10))
    }

    func test_parsePoll_expired() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data(#"{"error":"expired_token"}"#.utf8)), .expired)
    }

    func test_parsePoll_denied() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data(#"{"error":"access_denied"}"#.utf8)), .denied)
    }

    func test_parsePoll_unknownError_isFailed() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data(#"{"error":"teapot"}"#.utf8)), .failed("teapot"))
    }

    func test_parsePoll_garbage_isFailed() {
        XCTAssertEqual(GitHubAuth.parsePoll(Data("???".utf8)), .failed("bad json"))
    }
}
