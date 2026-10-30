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

    func test_saveFailure_nilOnlyWhenSavedAndReadBack() {
        XCTAssertNil(GitHubAuth.saveFailure(status: errSecSuccess, expected: "t", readBack: "t"))
    }

    func test_saveFailure_refusedWriteIsReportedWithItsStatus() {
        let message = GitHubAuth.saveFailure(status: errSecAuthFailed, expected: "t", readBack: nil)
        XCTAssertEqual(message?.contains("OSStatus \(errSecAuthFailed)"), true)
    }

    // A success status with nothing (or something else) behind it is not a sign-in.
    func test_saveFailure_missingOrDifferentReadBackFails() {
        XCTAssertNotNil(GitHubAuth.saveFailure(status: errSecSuccess, expected: "t", readBack: nil))
        XCTAssertNotNil(GitHubAuth.saveFailure(status: errSecSuccess, expected: "t", readBack: "old"))
    }

    func test_saveFailure_refusedWriteNamesTheKeychainItem() {
        let message = GitHubAuth.saveFailure(status: errSecDuplicateItem, expected: "t", readBack: nil)
        XCTAssertEqual(message?.contains(GitHubAuth.keychainService), true)
    }

    // MARK: - store

    // Records which Keychain calls store made, in order, and what each returns.
    private final class KeychainCalls {
        var log: [String] = []
        var updateStatus: OSStatus = errSecSuccess
        var addStatus: OSStatus = errSecSuccess

        func store(_ token: String) -> OSStatus {
            GitHubAuth.store(
                token: token,
                update: { _ in self.log.append("update"); return self.updateStatus },
                add: { _ in self.log.append("add"); return self.addStatus })
        }
    }

    func test_store_updateSucceeds_neverAdds() {
        let keychain = KeychainCalls()
        XCTAssertEqual(keychain.store("t"), errSecSuccess)
        XCTAssertEqual(keychain.log, ["update"])
    }

    func test_store_noItemYet_addsAndReturnsTheAddStatus() {
        let keychain = KeychainCalls()
        keychain.updateStatus = errSecItemNotFound
        keychain.addStatus = errSecAuthFailed
        XCTAssertEqual(keychain.store("t"), errSecAuthFailed)
        XCTAssertEqual(keychain.log, ["update", "add"])
    }

    // Any other update failure is the answer: adding would only hit errSecDuplicateItem.
    func test_store_refusedUpdate_returnedWithoutAnAdd() {
        let keychain = KeychainCalls()
        keychain.updateStatus = errSecAuthFailed
        XCTAssertEqual(keychain.store("t"), errSecAuthFailed)
        XCTAssertEqual(keychain.log, ["update"])
    }

    // MARK: - completeSignIn

    // Stands in for the Keychain item: what store writes is what read returns,
    // unless a test makes the save refuse.
    private final class FakeKeychain {
        var saved: String?
        var storeStatus: OSStatus = errSecSuccess

        func store(_ token: String) -> OSStatus {
            if storeStatus == errSecSuccess { saved = token }
            return storeStatus
        }
        func read() -> String? { saved }

        func completeSignIn(_ token: String) -> GitHubAuth.SignInSave {
            GitHubAuth.completeSignIn(token: token, store: store, read: read)
        }
    }

    func test_completeSignIn_savedAndReadBack_isSaved() {
        let keychain = FakeKeychain()
        XCTAssertEqual(keychain.completeSignIn("new"), .saved)
        XCTAssertEqual(keychain.saved, "new")
    }

    func test_completeSignIn_refusedSave_failsWithItsStatus() {
        let keychain = FakeKeychain()
        keychain.storeStatus = errSecAuthFailed
        guard case .failed(let message) = keychain.completeSignIn("new") else {
            return XCTFail("a refused save with no token behind it must not sign in")
        }
        XCTAssertTrue(message.contains("OSStatus \(errSecAuthFailed)"))
    }

    // A failed save must not delete a working token; the panel stays signed in on it.
    func test_completeSignIn_refusedSave_keepsOlderToken() {
        let keychain = FakeKeychain()
        keychain.saved = "old"
        keychain.storeStatus = errSecAuthFailed
        XCTAssertEqual(keychain.completeSignIn("new"), .keptOlderToken)
        XCTAssertEqual(keychain.saved, "old")
    }

    // The store reports success but nothing reads back.
    func test_completeSignIn_nothingReadsBack_fails() {
        let result = GitHubAuth.completeSignIn(token: "new", store: { _ in errSecSuccess }, read: { nil })
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
    }

    // The store reports success but the older token is what reads back.
    func test_completeSignIn_staleReadBack_keepsOlderToken() {
        let result = GitHubAuth.completeSignIn(token: "new", store: { _ in errSecSuccess }, read: { "old" })
        XCTAssertEqual(result, .keptOlderToken)
    }
}
