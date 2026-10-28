import Foundation

// The integrations built into the app, each with a page of its own under
// Settings → Integrations. In list order.
enum Integration: CaseIterable, Hashable {
    case slack, github

    var name: String {
        switch self {
        case .slack:  return "Slack"
        case .github: return "GitHub"
        }
    }

    // The card's second line: what turning it on gets you.
    var summary: String {
        switch self {
        case .slack:  return "A DM when a prompt waits on you and you've stepped away"
        case .github: return "PR and CI status for the branches on the Tickets tab"
        }
    }

    var symbol: String {
        switch self {
        case .slack:  return "bubble.left.and.bubble.right.fill"
        case .github: return "arrow.triangle.pull"
        }
    }
}

// What an integration's card and page say about it. `problem` colours it as
// something to fix.
struct IntegrationStatus: Equatable {
    let text: String
    var problem = false
}

extension PanelNav {

    // Delivery needs both a bot token and a member ID; either missing and
    // nothing is sent. Every Slack row past setup keys off this.
    var slackReady: Bool { slackTokenPresent && slackMemberID != nil }

    // Who Slack would DM, and where that came from, because a wrong id would
    // send your prompts to a colleague and the source is the tell.
    var slackRecipient: String? {
        guard let id = slackMemberID else { return nil }
        let who = slackMemberLabel.map { "\($0) · \(id)" } ?? id
        return slackIdentityFromEmail ? "\(who) (from git email)" : who
    }

    // The short word on the right of the card, as an extension's card has.
    func cardStatus(_ integration: Integration) -> IntegrationStatus {
        switch integration {
        case .slack:
            if slackError != nil { return IntegrationStatus(text: "Error", problem: true) }
            if !slackTokenPresent { return IntegrationStatus(text: "Not set up") }
            if slackMemberID == nil { return IntegrationStatus(text: "No user", problem: true) }
            return IntegrationStatus(text: slackEnabled ? "On" : "Off")
        case .github:
            switch githubSignIn {
            case .requesting, .awaitingApproval: return IntegrationStatus(text: "Signing in")
            case .failed:                        return IntegrationStatus(text: "Sign-in failed", problem: true)
            case .idle:                          break
            }
            // PR links on with no sign-in fetches nothing, so that's the one
            // signed-out state worth flagging.
            if !githubSignedIn {
                return IntegrationStatus(text: "Not signed in", problem: githubLinkingEnabled)
            }
            return IntegrationStatus(text: githubLinkingEnabled ? "On" : "Off")
        }
    }

    // The line beside the page's title: the card's word, said in full.
    func pageStatus(_ integration: Integration) -> IntegrationStatus {
        switch integration {
        case .slack:
            // The last paste, lookup or test answers the row just pressed, so
            // it comes first; then a delivery error, then the resting state.
            if let note = slackSetupNote { return IntegrationStatus(text: note) }
            if let error = slackError { return IntegrationStatus(text: error, problem: true) }
            guard slackTokenPresent else { return IntegrationStatus(text: "Not set up: paste your Slack setup to start") }
            guard let recipient = slackRecipient else {
                return IntegrationStatus(text: "Bot token stored, no Slack user yet", problem: true)
            }
            return IntegrationStatus(text: (slackEnabled ? "On, DMs " : "Off, would DM ") + recipient)
        case .github:
            switch githubSignIn {
            case .requesting:
                return IntegrationStatus(text: "Asking GitHub for a code…")
            case let .awaitingApproval(userCode, verificationURI):
                let site = verificationURI.replacingOccurrences(of: "https://", with: "")
                return IntegrationStatus(text: "Enter \(userCode) at \(site)")
            case .failed(let message):
                return IntegrationStatus(text: message, problem: true)
            case .idle:
                break
            }
            guard githubSignedIn else {
                return IntegrationStatus(text: githubLinkingEnabled ? "PR links are on but not signed in"
                                                                    : "Not signed in",
                                         problem: githubLinkingEnabled)
            }
            let who = githubUsesCLILogin ? "Signed in with your gh login" : "Signed in"
            return IntegrationStatus(text: who + (githubLinkingEnabled ? ", PR links on" : ", PR links off"))
        }
    }
}
