import SwiftUI

// The PRs tab: your open pull requests and the ones waiting on your review,
// from the same poll that feeds GitHub activity events (GitHubFeedPoller), so
// the tab costs no requests of its own.

struct PRRow: Identifiable, Equatable {
    enum Section: String { case mine = "Mine", review = "To review" }
    struct Chip: Equatable {
        enum Tone { case neutral, good, attention, bad }
        let text: String
        let tone: Tone
    }

    let id: String          // the PR's URL: unique, and what ⏎ opens
    let section: Section
    let title: String
    let label: String       // "app#12"
    let url: URL?
    let chips: [Chip]
}

enum PRRows {

    // Mine first, then To review, each in GitHub's search order (most
    // recently updated first).
    static func rows(_ snapshot: GitHubFeed.Snapshot, login: String?, now: Date = Date()) -> [PRRow] {
        let mine = snapshot.mine.map { pr -> PRRow in
            var chips: [PRRow.Chip] = []
            if pr.isDraft { chips.append(.init(text: "Draft", tone: .neutral)) }
            switch pr.reviewDecision {
            case "APPROVED":          chips.append(.init(text: "Approved", tone: .good))
            case "CHANGES_REQUESTED": chips.append(.init(text: "Changes requested", tone: .attention))
            default: break
            }
            switch pr.commits.nodes.first?.commit.statusCheckRollup?.state {
            case "SUCCESS":               chips.append(.init(text: "CI passing", tone: .good))
            case "FAILURE", "ERROR":      chips.append(.init(text: "CI failing", tone: .bad))
            case "PENDING", "EXPECTED":   chips.append(.init(text: "CI running", tone: .neutral))
            default: break
            }
            if pr.mergeable == "CONFLICTING" { chips.append(.init(text: "Conflict", tone: .bad)) }
            return PRRow(id: pr.url, section: .mine, title: pr.title,
                         label: label(pr.repository.nameWithOwner, pr.number),
                         url: URL(string: pr.url), chips: chips)
        }
        // Asked of you by name first, then through a team.
        let direct = snapshot.requested.filter { pr in login.map { pr.isDirect(login: $0) } ?? false }
        let viaTeam = snapshot.requested.filter { pr in !(login.map { pr.isDirect(login: $0) } ?? false) }
        let review = (direct + viaTeam).map { pr -> PRRow in
            var chips: [PRRow.Chip] = []
            if let login, pr.isDirect(login: login) {
                let request = GitHubFeed.latestRequest(pr, login: login, now: now)
                if let who = request?.requester ?? pr.author?.login {
                    chips.append(.init(text: request?.again == true ? "asked again by \(who)" : "from \(who)",
                                       tone: request?.again == true ? .attention : .neutral))
                }
            } else {
                chips += pr.teams.map { .init(text: "team: \($0)", tone: .neutral) }
                if let author = pr.author?.login { chips.append(.init(text: "by \(author)", tone: .neutral)) }
            }
            return PRRow(id: pr.url, section: .review, title: pr.title,
                         label: label(pr.repository.nameWithOwner, pr.number),
                         url: URL(string: pr.url), chips: chips)
        }
        return mine + review
    }

    static func label(_ repo: String, _ number: Int) -> String {
        "\(GitHubFeed.shortRepo(repo))#\(number)"
    }
}

struct PullRequestsView: View {
    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(spacing: 0) {
            content
            PageFooter {
                FooterHint(label: "Select", keys: ["↑↓"])
                FooterDivider()
                FooterHint(label: "Open", keys: ["⏎"], primary: true)
                FooterDivider()
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = nav.pullRequestRows
        if !nav.githubSignedIn {
            signIn
        } else if nav.pullRequestSnapshot == nil {
            message("Loading your pull requests…", "The first check runs a few seconds after GitHub activity is turned on.")
        } else if rows.isEmpty {
            message("Nothing open", "No open pull requests of yours, and no reviews waiting on you.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            if index == 0 || rows[index - 1].section != row.section {
                                sectionHeader(row.section, count: rows.filter { $0.section == row.section }.count)
                            }
                            rowView(row, selected: index == nav.prSelectedIndex)
                                .id(index)
                                .onTapGesture {
                                    nav.prSelectedIndex = index
                                    nav.openSelectedPullRequest()
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: nav.prSelectedIndex) { proxy.scrollTo($0) }
            }
        }
    }

    private func sectionHeader(_ section: PRRow.Section, count: Int) -> some View {
        Text("\(section.rawValue) · \(count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func rowView(_ row: PRRow, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(row.label).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if !row.chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(row.chips, id: \.text) { chip in
                        Text(chip.text)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(color(chip.tone))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(color(chip.tone).opacity(0.14)))
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(selected ? nav.theme.color.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }

    // Semantic, like the Events tab's severity colours: red reads as broken
    // whatever the accent.
    private func color(_ tone: PRRow.Chip.Tone) -> Color {
        switch tone {
        case .neutral:   return .secondary
        case .good:      return .green
        case .attention: return .orange
        case .bad:       return .red
        }
    }

    // Signing in from here: one click copies the code and opens GitHub.
    private var signIn: some View {
        VStack(spacing: 8) {
            Text("Sign in to GitHub to see your pull requests").font(.subheadline.weight(.medium))
            if case let .awaitingApproval(code, _) = nav.githubSignIn {
                Text(code).font(.title3.monospaced().weight(.semibold))
                Text("Copied. Paste it on the GitHub page that opened, then approve.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy and open GitHub again") { nav.connectGithub() }
            } else {
                Button("Sign in to GitHub") { nav.connectGithub() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nav.githubSignIn == .requesting)
                if case let .failed(message) = nav.githubSignIn {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
