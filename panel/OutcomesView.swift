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
    var id: String { branch }
    let branch: String
    let repoRoot: String?   // for the per-branch outcome lookup (repo+branch keyed)
    let sessionCount: Int
    let totalTokens: Int
    let diff: DiffStat
}

// One aggregated row in the Tickets tab: every session that shares a grouping
// key. The key is the derived Linear/Jira ticket when one was found, else the
// git branch (so unticketed work-streams stay separate instead of collapsing
// into one anonymous bucket). Tokens are summed across the group's sessions.
struct TicketGroup: Identifiable, Equatable {
    let id: String          // grouping key = ticket ?? branch ?? placeholder
    let isTicket: Bool      // true when id is a real ticket key (gets the deep link)
    let repos: [String]     // distinct repo names the sessions ran in
    let sessionCount: Int
    let totalTokens: Int
    let agents: [String]    // distinct canonical agents, first-seen order
    let diff: DiffStat      // pending work, summed across the group's branches
    // All branch slices in the group (used for the outcome rollup); rendered as
    // sub-rows only for ticket groups — a branch-only group's slice is itself.
    let branches: [BranchBreakdown]
}

// Tickets tab — the first slice of the usage-to-outcome dashboard. Reads the
// handoff ledger, rolls token usage + session counts up per `ticket ?? branch`,
// shows the repo each group ran in and (for tickets) the branches beneath it,
// and deep-links each ticket row to its tracker when STACKNUDGE_TICKET_URL is
// set. Pure read over data the ledger already holds; no capture, no network.
struct OutcomesView: View {

    @ObservedObject var nav: PanelNav

    // STACKNUDGE_TICKET_URL template, e.g. "https://linear.app/acme/issue/{key}".
    // Loaded once on appear; unset → ticket rows render without a link.
    @State private var ticketURLTemplate: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let groups = Self.groups(from: HandoffLedger.shared.all())
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(groups) { groupRow($0) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ThinScrollers())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollIndicators(.visible)
            }

            PageFooter {
                FooterHint(label: footerStatus(groups), keys: [])
                if nav.compactMode { FooterHint(label: "Compact", keys: ["M"]) }
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            ticketURLTemplate = ConfigFile.read()["STACKNUDGE_TICKET_URL"]
            nav.refreshOutcomes?()
        }
    }

    // MARK: - Rows

    private func groupRow(_ group: TicketGroup) -> some View {
        let linkable = group.isTicket && ticketURL(for: group.id) != nil
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(group.id)
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
                if !group.repos.isEmpty {
                    Text(group.repos.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Text(detailLine(group))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            let rollup = outcomeRollup(group)
            if !rollup.isEmpty {
                HStack(spacing: 10) {
                    ForEach(rollup, id: \.status) { statusChip($0.status, count: $0.count) }
                }
            }
            if group.isTicket, !group.branches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.branches) { branchRow($0) }
                }
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { if linkable { openTicket(group) } }
        .help(linkable ? "Open \(group.id) in your tracker" : "")
    }

    private func branchRow(_ branch: BranchBreakdown) -> some View {
        HStack(spacing: 6) {
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
            if let status = outcome(for: branch), status != .clean {
                statusChip(status)
            }
        }
        .padding(.leading, 12)
    }

    // "3 sessions · 218K tokens · 23 files · +1.8k/−400 · Claude, Codex" —
    // each segment is dropped when it has nothing to show.
    private func detailLine(_ group: TicketGroup) -> String {
        var parts = [Self.sessionsLabel(group.sessionCount)]
        if group.totalTokens > 0 { parts.append("\(Self.shortTokens(group.totalTokens)) tokens") }
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
        if branch.totalTokens > 0 { parts.append(Self.shortTokens(branch.totalTokens)) }
        if branch.diff.filesChanged > 0 { parts.append(Self.filesLabel(branch.diff.filesChanged)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Outcome ("did it ship?")

    private func outcome(for branch: BranchBreakdown) -> OutcomeStatus? {
        nav.outcomeByBranch[PanelNav.outcomeKey(branch.repoRoot, branch.branch)]
    }

    // Counts of each non-clean outcome across the group's branches, ordered
    // most-shipped first. Empty when nothing has a status yet (e.g. still
    // computing) or everything is clean.
    private func outcomeRollup(_ group: TicketGroup) -> [(status: OutcomeStatus, count: Int)] {
        var counts: [OutcomeStatus: Int] = [:]
        for branch in group.branches {
            guard let status = outcome(for: branch), status != .clean else { continue }
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

    // MARK: - Deep link

    private func ticketURL(for key: String) -> URL? {
        guard let template = ticketURLTemplate, template.contains("{key}") else { return nil }
        return URL(string: template.replacingOccurrences(of: "{key}", with: key))
    }

    private func openTicket(_ group: TicketGroup) {
        guard let url = ticketURL(for: group.id) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Aggregation (pure, testable)

    // Roll the ledger up by `ticket ?? branch`. The ticket is re-derived from
    // the branch when the stored field is empty, so records captured before a
    // parser fix (e.g. lowercase `eng-75/…`) still roll up under `ENG-75`.
    // Tickets sort first (they're the unit the user tracks), then by most-recent
    // activity within each band.
    static func groups(from records: [HandoffRecord]) -> [TicketGroup] {
        struct Resolved { let key: String; let isTicket: Bool; let record: HandoffRecord }
        let resolved = records.map { record -> Resolved in
            if let ticket = record.ticket ?? TicketAttribution.ticket(branch: record.branch) {
                return Resolved(key: ticket, isTicket: true, record: record)
            }
            return Resolved(key: record.branch ?? "—", isTicket: false, record: record)
        }

        var keyOrder: [String] = []
        var byKey: [String: [Resolved]] = [:]
        for item in resolved {
            if byKey[item.key] == nil { keyOrder.append(item.key) }
            byKey[item.key, default: []].append(item)
        }

        let groups = keyOrder.map { key -> (group: TicketGroup, last: Date) in
            let items = byKey[key] ?? []
            let rows = items.map(\.record)
            let isTicket = items.first?.isTicket ?? false
            let tokens = rows.compactMap(\.contextTokens).reduce(0, +)
            let agents = orderedDistinct(rows.map { displayAgent($0.agent) })
            let repos = orderedDistinct(rows.compactMap { repoName($0.repoRoot) })
            let last = rows.map(\.updatedAt).max() ?? .distantPast
            let slices = branchBreakdown(rows)
            let diff = DiffStat(
                filesChanged: slices.reduce(0) { $0 + $1.diff.filesChanged },
                insertions: slices.reduce(0) { $0 + $1.diff.insertions },
                deletions: slices.reduce(0) { $0 + $1.diff.deletions })
            return (TicketGroup(id: key, isTicket: isTicket, repos: repos,
                                sessionCount: rows.count, totalTokens: tokens,
                                agents: agents, diff: diff, branches: slices), last)
        }
        return groups.sorted {
            if $0.group.isTicket != $1.group.isTicket { return $0.group.isTicket }
            return $0.last > $1.last
        }.map(\.group)
    }

    // Per-branch slices within a ticket, heaviest token use first.
    static func branchBreakdown(_ rows: [HandoffRecord]) -> [BranchBreakdown] {
        var order: [String] = []
        var byBranch: [String: [HandoffRecord]] = [:]
        for row in rows {
            let branch = row.branch ?? "—"
            if byBranch[branch] == nil { order.append(branch) }
            byBranch[branch, default: []].append(row)
        }
        return order.map { branch -> BranchBreakdown in
            let group = byBranch[branch] ?? []
            let tokens = group.compactMap(\.contextTokens).reduce(0, +)
            let latest = group.max { $0.updatedAt < $1.updatedAt }
            let diff = DiffStat(
                filesChanged: latest?.filesChanged ?? 0,
                insertions: latest?.insertions ?? 0,
                deletions: latest?.deletions ?? 0)
            return BranchBreakdown(branch: branch, repoRoot: latest?.repoRoot,
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

    private static func shortTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return "\(Int((Double(count) / 1_000).rounded()))K" }
        return "\(count)"
    }

    private static func filesLabel(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }

    // "+1.8k/−400" — uses the minus sign (U+2212) to match the app's typography.
    private static func lineDelta(_ diff: DiffStat) -> String {
        "+\(shortCount(diff.insertions))/−\(shortCount(diff.deletions))"
    }

    private static func shortCount(_ count: Int) -> String {
        count >= 1_000 ? String(format: "%.1fk", Double(count) / 1_000) : "\(count)"
    }

    // MARK: - Footer + empty state

    private func footerStatus(_ groups: [TicketGroup]) -> String {
        guard !groups.isEmpty else { return "No tracked sessions" }
        let sessions = groups.reduce(0) { $0 + $1.sessionCount }
        let groupWord = groups.count == 1 ? "group" : "groups"
        let sessionWord = sessions == 1 ? "session" : "sessions"
        return "\(groups.count) \(groupWord) · \(sessions) \(sessionWord)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tag")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No tracked sessions yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("When an agent finishes a turn inside a git repo, stack-nudge records the session here — grouped by its Linear/Jira ticket, or the branch when there's no ticket.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}
