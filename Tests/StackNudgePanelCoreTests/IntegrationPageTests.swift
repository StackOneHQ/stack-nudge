import XCTest

@testable import StackNudgePanelCore

// Integrations was one flat list of Slack's seven rows and GitHub's three, with
// nothing marking where one ended. It is now a card per integration, each
// opening a page of its own, the way the Extensions list does.
@MainActor
final class IntegrationPageTests: XCTestCase {

    private func onIntegrations(_ nav: PanelNav = PanelNav()) -> PanelNav {
        nav.settingsCategory = .integrations
        nav.settingsDetailFocused = true
        nav.selectFirstCategoryRow()
        return nav
    }

    // MARK: - The list and its pages

    func testTheListIsACardPerIntegration() {
        XCTAssertEqual(PanelNav().rows(in: .integrations), [.integration(.slack), .integration(.github)])
    }

    func testEachPageHoldsItsOwnRows() {
        let nav = PanelNav()
        XCTAssertEqual(nav.rows(in: .integrationPage(.slack)),
                       [.slackPaste, .slackIdentity, .slackTest,
                        .slackEnabled, .slackIdle, .slackDetail, .slackStop])
        XCTAssertEqual(nav.rows(in: .integrationPage(.github)), [.githubLinks, .hideShipped, .connectGithub])
    }

    // Signed out, the page is somewhere to sign in from; signed in, to sign out.
    func testGitHubOffersConnectOrDisconnectButNeverBoth() {
        let nav = PanelNav()
        nav.githubSignedIn = true
        XCTAssertEqual(nav.rows(in: .integrationPage(.github)), [.githubLinks, .hideShipped, .disconnectGithub])
    }

    // The second card, so "opens the selected one" can't pass as "opens a
    // constant".
    func testEnterOnACardOpensThatPage() {
        let nav = onIntegrations()
        nav.selectedSettingIndex = nav.index(of: .integration(.github))
        nav.activate()
        XCTAssertEqual(nav.settingsCategory, .integrationPage(.github))
        XCTAssertTrue(nav.settingsDetailFocused)
        XCTAssertEqual(nav.selectedRow, .githubLinks)
    }

    // → is routed as ⏎ on a door; the arrows that step a value must not open
    // anything.
    func testACardOpensOnRightAndArrowsDoNothing() {
        let nav = onIntegrations()
        XCTAssertTrue(nav.selectedRowOpensOnRight)
        XCTAssertFalse(nav.selectedRowIsPicker)
        nav.cycleForward()
        nav.cycleBackward()
        XCTAssertEqual(nav.settingsCategory, .integrations)
        XCTAssertEqual(nav.selectedRow, .integration(.slack))
    }

    // ← from a page lands on the card that opened it, still in the rows, as it
    // does from an extension's page.
    func testBackFromAPageReturnsToItsCard() {
        let nav = onIntegrations()
        nav.openIntegrationPage(.github)
        XCTAssertEqual(nav.sidebarCategory, .integrations, "the sidebar keeps Integrations lit")
        XCTAssertEqual(nav.settingsBackLabel, "Integrations")

        nav.settingsBack()
        XCTAssertEqual(nav.settingsCategory, .integrations)
        XCTAssertTrue(nav.settingsDetailFocused)
        XCTAssertEqual(nav.selectedRow, .integration(.github))
        XCTAssertEqual(nav.settingsBackLabel, "Categories")
    }

    // Resuming or deep-linking to a row finds it through its category.
    func testARowIsFoundOnItsPage() {
        let nav = PanelNav()
        XCTAssertEqual(nav.category(containing: .slackIdle), .integrationPage(.slack))
        XCTAssertEqual(nav.category(containing: .hideShipped), .integrationPage(.github))
        XCTAssertEqual(nav.category(containing: .integration(.slack)), .integrations)
    }

    func testThePageIsTitledByItsIntegration() {
        XCTAssertEqual(PanelNav().label(for: .integrationPage(.github)), "GitHub")
    }

    // No ⌘⌫ here: nothing on these pages is removed by it.
    func testTheFooterGoesBackToIntegrationsAndOffersNoRemove() {
        let hints = SettingsView.detailFooterHints(picker: false, opensPage: false, removeRow: false,
                                                   removable: false, inExtensions: false,
                                                   backTo: "Integrations", editingText: false)
        XCTAssertEqual(hints.map(\.label), ["Move", "Category", "Act", "Integrations"])
    }

    // MARK: - Connect GitHub

    // Turning PR links on in Settings used to start a sign-in whose code was
    // only shown on the Tickets tab. The page now starts one itself and shows
    // the code in its status line.
    func testConnectStartsASignInUnlessOneIsUnderWay() {
        let nav = PanelNav()
        var started = 0
        nav.startGithubSignIn = { started += 1 }
        nav.connectGithub()
        XCTAssertEqual(started, 1)

        nav.githubSignIn = .failed("Code expired — try again")
        nav.connectGithub()
        XCTAssertEqual(started, 2, "a failed sign-in can be tried again")

        nav.githubSignIn = .requesting
        nav.connectGithub()
        XCTAssertEqual(started, 2, "not while GitHub is being asked for a code")
    }

    func testEnterOnConnectReachesTheSignIn() {
        let nav = PanelNav()
        var started = 0
        nav.startGithubSignIn = { started += 1 }
        nav.openIntegrationPage(.github)
        nav.selectedSettingIndex = nav.index(of: .connectGithub)
        nav.activate()
        XCTAssertEqual(started, 1)
    }

    // Connect becomes Disconnect in the same place when the sign-in lands. A
    // selection left there would make the next ⏎ sign straight back out.
    func testASignInFinishingMovesTheSelectionOffDisconnect() {
        let nav = PanelNav()
        nav.openIntegrationPage(.github)
        nav.selectedSettingIndex = nav.index(of: .connectGithub)
        nav.githubSignedIn = true
        XCTAssertEqual(nav.selectedRow, .githubLinks)
    }

    // MARK: - Status

    func testSlackStatusSaysWhatsMissingBeforeWhetherItsOn() {
        let nav = PanelNav()
        XCTAssertEqual(nav.cardStatus(.slack), IntegrationStatus(text: "Not set up"))
        XCTAssertEqual(nav.pageStatus(.slack).text, "Not set up: paste your Slack setup to start")

        nav.slackTokenPresent = true
        XCTAssertEqual(nav.cardStatus(.slack), IntegrationStatus(text: "No user", problem: true))
        XCTAssertTrue(nav.pageStatus(.slack).problem)

        nav.slackMemberID = "U012AB3CD"
        nav.slackMemberLabel = "Alex"
        XCTAssertEqual(nav.cardStatus(.slack).text, "Off")
        XCTAssertEqual(nav.pageStatus(.slack).text, "Off, would DM Alex · U012AB3CD")

        nav.slackEnabled = true
        XCTAssertEqual(nav.cardStatus(.slack).text, "On")
        XCTAssertEqual(nav.pageStatus(.slack).text, "On, DMs Alex · U012AB3CD")
    }

    // The last paste or test answers the row just pressed, so it leads; a
    // delivery error leads the resting state.
    func testSlackPageStatusLeadsWithTheLatestOutcome() {
        let nav = PanelNav()
        nav.slackTokenPresent = true
        nav.slackMemberID = "U012AB3CD"
        nav.slackError = "channel_not_found"
        XCTAssertEqual(nav.pageStatus(.slack), IntegrationStatus(text: "channel_not_found", problem: true))
        XCTAssertEqual(nav.cardStatus(.slack), IntegrationStatus(text: "Error", problem: true))

        nav.slackSetupNote = "Test message sent"
        XCTAssertEqual(nav.pageStatus(.slack), IntegrationStatus(text: "Test message sent"))
    }

    func testGitHubStatusFollowsTheSignIn() {
        let nav = PanelNav()
        XCTAssertEqual(nav.cardStatus(.github), IntegrationStatus(text: "Not signed in"))

        // PR links on with nothing to fetch them with is the state to flag.
        nav.githubLinkingEnabled = true
        XCTAssertEqual(nav.cardStatus(.github), IntegrationStatus(text: "Not signed in", problem: true))

        nav.githubSignIn = .awaitingApproval(userCode: "ABCD-1234", verificationURI: "https://github.com/login/device")
        XCTAssertEqual(nav.cardStatus(.github).text, "Signing in")
        XCTAssertEqual(nav.pageStatus(.github).text, "Enter ABCD-1234 at github.com/login/device")

        nav.githubSignIn = .failed("Access denied")
        XCTAssertEqual(nav.pageStatus(.github), IntegrationStatus(text: "Access denied", problem: true))

        nav.githubSignIn = .idle
        nav.githubSignedIn = true
        XCTAssertEqual(nav.cardStatus(.github).text, "On")
        XCTAssertEqual(nav.pageStatus(.github).text, "Signed in, PR links on")
    }
}
