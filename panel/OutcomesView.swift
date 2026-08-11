import AppKit
import Foundation
import SwiftUI

// Uncommitted working-tree size, aggregated for display. Files are summed
// across branches (each branch contributing its latest snapshot); line deltas
// likewise. `isEmpty` lets the UI omit the segment when there's nothing pending.
struct DiffStat: Equatable {
    let filesChanged: Int
    let insertions: Int
    let deletions: Int

    var isEmpty: Bool { filesChanged == 0 && insertions == 0 && deletions == 0 }
}

// A single branch's slice of a ticket — shown as an indented sub-row so a
// ticket that spans several branches reveals where its sessions/tokens went.
// `diff` is the branch's latest snapshot (pending work), not a sum across its
// sessions — uncommitted state is point-in-time, so summing would double-count.
struct BranchBreakdown: Identifiable, Equatable {
    // (repoRoot, branch) so two repos with a same-named branch stay distinct.
    var id: String { PanelNav.outcomeKey(repoRoot, branch) }
    let branch: String
    let repoRoot: String?   // for the per-branch outcome lookup (repo+branch keyed)
    let sessionCount: Int
    let totalTokens: Int
    let diff: DiffStat
}

// Where the keyboard selection should scroll to. Two anchors because the list is
// lazy: `groupAnchor` is on the LazyVStack's direct child (resolvable before that
// group has been built), `rowID` is the precise header / branch row inside it.
struct OutcomeRowTarget: Equatable {
    let groupAnchor: String
    let rowID: String
}

// How a group is keyed. Ticket groups carry a real Linear/Jira key and deep-link
// to the tracker; repo groups are the bucket for unticketed work, gathering every
// branch that ran in a repo so loose work-streams nest under the repo instead of
// scattering one anonymous row per branch.
enum GroupKind: Equatable { case ticket, repo }

// One aggregated row in the Tickets tab: every session that shares a grouping
// key. Ticket sessions key by their derived ticket; unticketed sessions key by
// the repo they ran in. Tokens are summed across the group's sessions.
struct TicketGroup: Identifiable, Equatable {
    // Stable, unique identity = the namespaced grouping key ("t:<ticket>" /
    // "r:<repoRoot>"). Used for SwiftUI identity, row ids, and selection — never
    // shown. Two groups can share a `label` (a ticket and a repo both called
    // "ENG-9", or two repos with the same basename) without colliding here.
    let id: String
    let label: String       // display text: ticket key, or repo basename
    let kind: GroupKind
    let repos: [String]     // distinct repo names the sessions ran in
    let sessionCount: Int
    let totalTokens: Int
    let agents: [String]    // distinct canonical agents, first-seen order
    let diff: DiffStat      // pending work, summed across the group's branches
    // All branch slices in the group, rendered as indented sub-rows (both kinds).
    let branches: [BranchBreakdown]

    // True when this is a real ticket key — the only kind that deep-links.
    var isTicket: Bool { kind == .ticket }
}

// Tickets tab — the first slice of the usage-to-outcome dashboard. Reads the
// handoff ledger, rolls token usage + session counts up per ticket (or per repo
// for unticketed work), shows the branches beneath each group, and deep-links
// each ticket row to its tracker when STACKNUDGE_TICKET_URL is
// set. Pure read over data the ledger already holds; no capture, no network.

// The Outcomes tab: a two-pane carousel over one dataset. Lands on the Insights
// overview (the aggregate); → carousels into the per-ticket list, ← back (key
// handling lives in PanelController.keyDown, mode == .outcomes). Resets to the
// overview each time the tab opens.
struct OutcomesTabView: View {
    @ObservedObject var nav: PanelNav

    var body: some View {
        Group {
            switch nav.outcomesPane {
            case .overview: InsightsView(nav: nav)
            case .tickets:  OutcomesView(nav: nav)
            }
        }
        .onAppear { nav.outcomesPane = .overview }
    }
}

struct OutcomesView: View {

    @ObservedObject var nav: PanelNav

    // STACKNUDGE_TICKET_URL template, e.g. "https://linear.app/acme/issue/{key}".
    // Loaded once on appear; unset → ticket rows render without a link.
    @State private var ticketURLTemplate: String?
    // Previous selection index, to tell a ±1 step from a ⌘↑/↓ jump in the
    // scroll-follow below (a jump needs the group-anchor hop; a step doesn't).
    @State private var lastOutcomeIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = nav.visibleOutcomeGroups()
            let target = Self.selectedRow(groups, index: nav.outcomeSelectedIndex)
            if nav.githubLinkingEnabled, !nav.githubSignedIn {
                connectGithubCard
                Divider().opacity(0.4)
            }
            if groups.isEmpty {
                emptyState
            } else {
                // Count lives in the content (like the Overview pane), not the
                // footer, so the footer stays within the panel width.
                HStack {
                    Text(countSummary(groups)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                ScrollViewReader { proxy in
                    ScrollView {
                        // Lazy, like the Sessions and Events lists. A plain VStack
                        // built every group *and* every branch sub-row on every
                        // render; on a 90-day ledger that's a few hundred rows
                        // rebuilt per arrow keypress, since the selection index
                        // is published state this view reads.
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(groups) { group in
                                groupRow(group, selectedRowID: target?.rowID)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ThinScrollers())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.visible)
                    // Watch the resolved target, not the raw index, and scroll to
                    // what onChange hands us. Reading a separately-derived
                    // capture here lagged the viewport one keypress behind the
                    // selection; invisible when stepping ±1 (the row stays near
                    // the viewport) but obvious on a ⌘↑/↓ jump, where the pane
                    // didn't move until the next press. Mirrors the Sessions
                    // tab's onChange(of: selectedPID) pattern.
                    .onChange(of: target) { newTarget in
                        guard let newTarget else { return }
                        // A ±1 step lands in a group the LazyVStack has already
                        // built (it renders a buffer past the viewport), so the row
                        // anchor resolves directly — one hop, which avoids the
                        // center-group-then-center-row double move that flickers at
                        // ticket boundaries. Only a ⌘↑/↓ jump can land in an
                        // off-screen, unbuilt group; there the group anchor (a
                        // direct child of the stack, so it resolves unrealized) is
                        // hopped first to build the group, then the row anchor
                        // resolves on the next tick. Instant scroll (no animation)
                        // either way, so key-repeat doesn't pile up and bounce.
                        let index = nav.outcomeSelectedIndex
                        let isStep = abs(index - lastOutcomeIndex) <= 1
                        lastOutcomeIndex = index
                        if isStep {
                            proxy.scrollTo(newTarget.rowID, anchor: .center)
                        } else {
                            proxy.scrollTo(newTarget.groupAnchor, anchor: .center)
                            DispatchQueue.main.async {
                                proxy.scrollTo(newTarget.rowID, anchor: .center)
                            }
                        }
                    }
                }
            }

            PageFooter {
                if !groups.isEmpty {
                    FooterHint(label: "Select", keys: ["↑↓"])
                    FooterHint(label: "Open", keys: ["↵"])
                    FooterHint(label: "Remove", keys: ["⌫"])
                }
                FooterHint(label: "Overview", keys: ["←"])
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            ticketURLTemplate = ConfigFile.read()["STACKNUDGE_TICKET_URL"]
            nav.outcomeSelectedIndex = 0
            lastOutcomeIndex = 0
            nav.refreshOutcomes?()
            nav.refreshPullRequests?()
        }
    }

    // MARK: - Rows

    private func groupRow(_ group: TicketGroup, selectedRowID: String?) -> some View {
        let linkable = group.isTicket && ticketURL(for: group.label) != nil
        let selected = selectedRowID == Self.headerID(group)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if group.kind == .repo {
                    Image(systemName: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(group.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(group.isTicket ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if linkable {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 8)
                // Repo groups put the repo name in the title, so the trailing
                // slot shows the branch count instead of the (redundant) repo.
                if group.kind == .repo {
                    Text(Self.branchesLabel(group.branches.count))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                } else if !group.repos.isEmpty {
                    Text(group.repos.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.vertical, 2)
            // Selection highlight + scroll anchor live on the header ROW, not the
            // whole group container (which spans all its branches). A
            // container-wide accent lit up the entire block when a header was
            // selected — reading as an upward "jump" when crossing from a group's
            // last branch to the next group's header. A per-row highlight keeps
            // the selection a small, consistent marker that steps straight down.
            .background(RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
            .id(Self.headerID(group))
            Text(detailLine(group))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            let rollup = outcomeRollup(group)
            if !rollup.isEmpty {
                HStack(spacing: 10) {
                    ForEach(rollup, id: \.status) { statusChip($0.status, count: $0.count) }
                }
            }
            if !group.branches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.branches) { branch in
                        branchRow(branch, selectedRowID: selectedRowID)
                            .id(Self.branchID(branch))
                    }
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        // Coarse scroll anchor on the lazy stack's direct child, so it resolves
        // before this group has been built. The precise per-row anchors below it
        // only exist once it has; see the two-hop scroll in `body`.
        .id(Self.groupAnchorID(group))
        .onTapGesture { if linkable { openTicket(group) } }
        .help(linkable ? "Open \(group.label) in your tracker" : "")
    }

    private func branchRow(_ branch: BranchBreakdown, selectedRowID: String?) -> some View {
        let selected = selectedRowID == Self.branchID(branch)
        return HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(branch.branch)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(branchDetail(branch))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .fixedSize()
            if let pr = prInfo(for: branch) {
                prChip(pr)
            } else if let status = outcome(for: branch), status != .clean {
                statusChip(status)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear))
    }

    // Stable per-row ids — order must match PanelNav's selection indexing
    // (header, then a ticket group's branch sub-rows).
    private static func headerID(_ group: TicketGroup) -> String { "g:\(group.id)" }

    private static func branchID(_ branch: BranchBreakdown) -> String {
        "b:\(PanelNav.outcomeKey(branch.repoRoot, branch.branch))"
    }

    // Coarse anchor for the whole group card, distinct from headerID: that one is
    // on the header row inside the card (a card-wide selection highlight read as
    // an upward jump), which makes it invisible to a lazy scroll.
    static func groupAnchorID(_ group: TicketGroup) -> String { "ga:\(group.id)" }

    // Walks the flat row order (header, then that group's branch sub-rows) to the
    // requested index. Deliberately allocation-free: materialising the whole id
    // list meant building a string per row on every render, and the caller only
    // ever wants one of them. Out-of-range clamps to the first / last row, and an
    // empty ledger yields nil.
    static func selectedRow(_ groups: [TicketGroup], index: Int) -> OutcomeRowTarget? {
        guard let last = groups.last else { return nil }
        var remaining = max(0, index)
        for group in groups {
            if remaining == 0 { return target(group, headerID(group)) }
            remaining -= 1
            if remaining < group.branches.count {
                return target(group, branchID(group.branches[remaining]))
            }
            remaining -= group.branches.count
        }
        return target(last, last.branches.last.map(branchID) ?? headerID(last))
    }

    private static func target(_ group: TicketGroup, _ rowID: String) -> OutcomeRowTarget {
        OutcomeRowTarget(groupAnchor: groupAnchorID(group), rowID: rowID)
    }

    // "3 sessions · 218K tokens · 23 files · +1.8k/−400 · Claude, Codex" —
    // each segment is dropped when it has nothing to show.
    private func detailLine(_ group: TicketGroup) -> String {
        var parts = [Self.sessionsLabel(group.sessionCount)]
        if group.totalTokens > 0 { parts.append("\(TokenFormat.short(group.totalTokens)) tokens") }
        if !group.diff.isEmpty {
            parts.append(Self.filesLabel(group.diff.filesChanged))
            if group.diff.insertions > 0 || group.diff.deletions > 0 {
                parts.append(Self.lineDelta(group.diff))
            }
        }
        if !group.agents.isEmpty { parts.append(group.agents.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    // Compact sub-row trailing: "2 sessions · 600K · 12 files".
    private func branchDetail(_ branch: BranchBreakdown) -> String {
        var parts = [Self.sessionsLabel(branch.sessionCount)]
        if branch.totalTokens > 0 { parts.append(TokenFormat.short(branch.totalTokens)) }
        if branch.diff.filesChanged > 0 { parts.append(Self.filesLabel(branch.diff.filesChanged)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Outcome ("did it ship?")

    private func outcome(for branch: BranchBreakdown) -> OutcomeStatus? {
        nav.outcomeByBranch[PanelNav.outcomeKey(branch.repoRoot, branch.branch)]
    }

    private func prInfo(for branch: BranchBreakdown) -> PullRequestInfo? {
        nav.pullRequestByBranch[PanelNav.outcomeKey(branch.repoRoot, branch.branch)]
    }

    // A PR's state, when known, supersedes the local heuristic — a MERGED PR is
    // how a squash-merged branch finally reads as "merged". Open → at least
    // pushed; closed-not-merged falls back to the local truth.
    private func effectiveStatus(for branch: BranchBreakdown) -> OutcomeStatus? {
        OutcomeWatcher.effective(local: outcome(for: branch), pr: prInfo(for: branch))
    }

    // Counts of each non-clean status across the group's branches (PR state
    // preferred), ordered most-shipped first. Empty when nothing has resolved
    // yet or everything is clean.
    private func outcomeRollup(_ group: TicketGroup) -> [(status: OutcomeStatus, count: Int)] {
        var counts: [OutcomeStatus: Int] = [:]
        for branch in group.branches {
            guard let status = effectiveStatus(for: branch), status != .clean else { continue }
            counts[status, default: 0] += 1
        }
        return Self.outcomeOrder.compactMap { status in
            counts[status].map { (status, $0) }
        }
    }

    private func statusChip(_ status: OutcomeStatus, count: Int? = nil) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(Self.outcomeColor(status))
                .frame(width: 6, height: 6)
            Text(count.map { "\($0) \(Self.outcomeLabel(status))" } ?? Self.outcomeLabel(status))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private static let outcomeOrder: [OutcomeStatus] = [.merged, .pushed, .committed, .needsReview]

    private static func outcomeLabel(_ status: OutcomeStatus) -> String {
        switch status {
        case .merged:      return "merged"
        case .pushed:      return "pushed"
        case .committed:   return "committed"
        case .needsReview: return "needs review"
        case .clean:       return "clean"
        }
    }

    private static func outcomeColor(_ status: OutcomeStatus) -> Color {
        switch status {
        case .merged:      return .purple
        case .pushed:      return .blue
        case .committed:   return .teal
        case .needsReview: return .orange
        case .clean:       return .secondary
        }
    }

    // Clickable PR chip: state dot + label + a CI glyph. Opens the PR in the
    // browser. Used in place of the local-outcome chip when a PR is known.
    private func prChip(_ pr: PullRequestInfo) -> some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(Self.prColor(pr))
                    .frame(width: 6, height: 6)
                Text(Self.prLabel(pr))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                if let ci = pr.ci {
                    Image(systemName: Self.ciSymbol(ci))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Self.ciColor(ci))
                }
                // Link affordance so the chip reads as clickable (vs the static
                // local-outcome chip) regardless of PR state — merged included.
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.accentColor.opacity(0.7))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Open PR #\(pr.number)")
    }

    private static func prLabel(_ pr: PullRequestInfo) -> String {
        switch pr.state {
        case .merged: return "merged"
        case .closed: return "closed"
        case .open:   return pr.isDraft ? "draft #\(pr.number)" : "PR #\(pr.number)"
        }
    }

    private static func prColor(_ pr: PullRequestInfo) -> Color {
        switch pr.state {
        case .merged: return .purple
        case .closed: return .secondary
        case .open:   return pr.isDraft ? .secondary : .blue
        }
    }

    private static func ciSymbol(_ ci: CIStatus) -> String {
        switch ci {
        case .passing: return "checkmark"
        case .failing: return "xmark"
        case .pending: return "clock"
        }
    }

    private static func ciColor(_ ci: CIStatus) -> Color {
        switch ci {
        case .passing: return .green
        case .failing: return .red
        case .pending: return .yellow
        }
    }

    // MARK: - Deep link

    private func ticketURL(for key: String) -> URL? {
        guard let template = ticketURLTemplate, template.contains("{key}") else { return nil }
        return URL(string: template.replacingOccurrences(of: "{key}", with: key))
    }

    private func openTicket(_ group: TicketGroup) {
        guard let url = ticketURL(for: group.label) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Aggregation (pure, testable)

    // Roll the ledger up by `ticket ?? branch`. The ticket is re-derived from
    // the branch when the stored field is empty, so records captured before a
    // parser fix (e.g. lowercase `eng-75/…`) still roll up under `ENG-75`.
    // Tickets sort first (they're the unit the user tracks), then by most-recent
    // activity within each band.
    static func groups(from records: [HandoffRecord]) -> [TicketGroup] {
        // Ticketed sessions key by their derived ticket; everything else buckets
        // by repo. The dedupKey is namespaced (t:/r:) and, for repos, uses the
        // full repoRoot — two checkouts with the same basename (…/acme/api,
        // …/example/api) must stay separate. The label is the human text
        // (ticket key, or repo basename), which may repeat across groups.
        struct Resolved { let dedupKey: String; let label: String; let kind: GroupKind; let record: HandoffRecord }
        let resolved = records.map { record -> Resolved in
            if let ticket = record.ticket ?? TicketAttribution.ticket(branch: record.branch) {
                return Resolved(dedupKey: "t:\(ticket)", label: ticket, kind: .ticket, record: record)
            }
            let root = record.repoRoot ?? "—"
            return Resolved(dedupKey: "r:\(root)", label: repoName(record.repoRoot) ?? "—", kind: .repo, record: record)
        }

        var keyOrder: [String] = []
        var byKey: [String: [Resolved]] = [:]
        for item in resolved {
            if byKey[item.dedupKey] == nil { keyOrder.append(item.dedupKey) }
            byKey[item.dedupKey, default: []].append(item)
        }

        let groups = keyOrder.map { key -> (group: TicketGroup, last: Date) in
            let items = byKey[key] ?? []
            let rows = items.map(\.record)
            let kind = items.first?.kind ?? .repo
            let label = items.first?.label ?? "—"
            let tokens = rows.compactMap(\.contextTokens).reduce(0, +)
            let agents = orderedDistinct(rows.map { displayAgent($0.agent) })
            let repos = orderedDistinct(rows.compactMap { repoName($0.repoRoot) })
            let last = rows.map(\.updatedAt).max() ?? .distantPast
            let slices = branchBreakdown(rows)
            let diff = DiffStat(
                filesChanged: slices.reduce(0) { $0 + $1.diff.filesChanged },
                insertions: slices.reduce(0) { $0 + $1.diff.insertions },
                deletions: slices.reduce(0) { $0 + $1.diff.deletions })
            return (TicketGroup(id: key, label: label, kind: kind, repos: repos,
                                sessionCount: rows.count, totalTokens: tokens,
                                agents: agents, diff: diff, branches: slices), last)
        }
        // Tickets first, then repo buckets; most-recent within each band.
        return groups.sorted {
            if $0.group.isTicket != $1.group.isTicket { return $0.group.isTicket }
            return $0.last > $1.last
        }.map(\.group)
    }

    // Per-branch slices within a group, heaviest token use first. Keyed by
    // (repoRoot, branch) — matching the outcome/PR lookup — so a branch name
    // shared across two repos doesn't collapse into one slice or lose a repoRoot.
    static func branchBreakdown(_ rows: [HandoffRecord]) -> [BranchBreakdown] {
        var order: [String] = []
        var byKey: [String: [HandoffRecord]] = [:]
        for row in rows {
            let key = PanelNav.outcomeKey(row.repoRoot, row.branch)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(row)
        }
        return order.map { key -> BranchBreakdown in
            let group = byKey[key] ?? []
            let tokens = group.compactMap(\.contextTokens).reduce(0, +)
            let latest = group.max { $0.updatedAt < $1.updatedAt }
            let diff = DiffStat(
                filesChanged: latest?.filesChanged ?? 0,
                insertions: latest?.insertions ?? 0,
                deletions: latest?.deletions ?? 0)
            return BranchBreakdown(branch: latest?.branch ?? "—", repoRoot: latest?.repoRoot,
                                   sessionCount: group.count, totalTokens: tokens, diff: diff)
        }.sorted { $0.totalTokens > $1.totalTokens }
    }

    private static func orderedDistinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func repoName(_ repoRoot: String?) -> String? {
        guard let repoRoot, !repoRoot.isEmpty else { return nil }
        let name = (repoRoot as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private static func displayAgent(_ canonical: String) -> String {
        switch canonical {
        case "claude": return "Claude"
        case "codex":  return "Codex"
        case "agy":    return "Antigravity"
        case "gemini": return "Gemini"
        default:       return canonical.capitalized
        }
    }

    private static func sessionsLabel(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }


    private static func filesLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
    static func branchesLabel(_ count: Int) -> String {
        count == 1 ? "1 branch" : "\(count) branches"
    }

    // "+1.8k/−400" — uses the minus sign (U+2212) to match the app's typography.
    private static func lineDelta(_ diff: DiffStat) -> String {
        "+\(shortCount(diff.insertions))/−\(shortCount(diff.deletions))"
    }

    private static func shortCount(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    // MARK: - Footer + empty state

    private func countSummary(_ groups: [TicketGroup]) -> String {
        guard !groups.isEmpty else { return "No tracked sessions" }
        let sessions = groups.reduce(0) { $0 + $1.sessionCount }
        let groupWord = groups.count == 1 ? "group" : "groups"
        let sessionWord = sessions == 1 ? "session" : "sessions"
        return "\(groups.count) \(groupWord) · \(sessions) \(sessionWord)"
    }

    // MARK: - Connect GitHub (device-flow sign-in)

    @ViewBuilder private var connectGithubCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub PR links")
                .font(.callout.weight(.semibold))
            switch nav.githubSignIn {
            case .idle:
                Text("Connect GitHub to show PR + CI status on these branches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                cardButton("Connect GitHub", prominent: true) { nav.startGithubSignIn?() }
            case .requesting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Contacting GitHub…").font(.caption).foregroundStyle(.secondary)
                }
            case let .awaitingApproval(userCode, verificationURI):
                Text("Enter this code at \(displayURL(verificationURI)):")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(userCode)
                    .font(.title3.monospaced().weight(.bold))
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    cardButton("Copy & open GitHub", prominent: true) {
                        copyAndOpen(code: userCode, url: verificationURI)
                    }
                    cardButton("Cancel") { nav.cancelGithubSignIn?() }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for approval…").font(.caption2).foregroundStyle(.tertiary)
                }
            case let .failed(message):
                Text(message).font(.caption).foregroundStyle(.orange)
                cardButton("Try again", prominent: true) { nav.startGithubSignIn?() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func cardButton(_ title: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(prominent ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08)))
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func copyAndOpen(code: String, url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        if let target = URL(string: url) { NSWorkspace.shared.open(target) }
    }

    private func displayURL(_ url: String) -> String {
        url.replacingOccurrences(of: "https://", with: "")
    }

    private var emptyState: some View {
        let reason = Self.emptyReason(totalGroups: nav.totalOutcomeGroupCount(),
                                      drops: nav.handoffDrops)
        return VStack(spacing: 10) {
            Image(systemName: reason.symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(reason.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(reason.detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Empty state (pure, testable)

    // Why the list is empty. Three states that used to render one string, which
    // made a filtered-away list and a broken capture path indistinguishable from
    // a machine that simply hasn't finished a turn yet.
    enum EmptyReason: Equatable {
        case noSessions
        // Ledger has groups, but the hide-shipped filter removed all of them.
        case allShipped(hidden: Int)
        // Stops arrived and every one was dropped before it reached the ledger.
        case allDropped(count: Int, reason: HandoffDropReason)

        var symbol: String {
            switch self {
            case .noSessions:  return "tag"
            case .allShipped:  return "checkmark.seal"
            case .allDropped:  return "exclamationmark.triangle"
            }
        }

        var title: String {
            switch self {
            case .noSessions:
                return "No tracked sessions yet"
            case .allShipped(let hidden):
                return hidden == 1 ? "1 shipped ticket hidden" : "\(hidden) shipped tickets hidden"
            case .allDropped(let count, _):
                return count == 1 ? "1 turn wasn't recorded" : "\(count) turns weren't recorded"
            }
        }

        var detail: String {
            switch self {
            case .noSessions:
                return "When an agent finishes a turn inside a git repo, stack-nudge records the session here, grouped by its Linear/Jira ticket, or the branch when there's no ticket."
            case .allShipped:
                return "Everything tracked has merged. Turn off Hide shipped in Settings to see it."
            case .allDropped(_, let reason):
                let remedy = reason.remedy.map { " \($0)" } ?? ""
                return "Turns ended but \(reason.summary), so there was nothing to attribute.\(remedy)"
            }
        }
    }

    // Priority: an all-filtered list is the least alarming explanation and takes
    // precedence, then drops (the actionable fault), then a genuinely idle ledger.
    // Reports the highest-count drop reason, since a mixed bag is dominated by
    // whichever link is actually broken.
    static func emptyReason(totalGroups: Int,
                            drops: [HandoffDropReason: Int]) -> EmptyReason {
        if totalGroups > 0 { return .allShipped(hidden: totalGroups) }
        let ranked = drops.filter { $0.value > 0 }
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
        if let worst = ranked.first {
            return .allDropped(count: ranked.reduce(0) { $0 + $1.value }, reason: worst.key)
        }
        return .noSessions
    }
}
