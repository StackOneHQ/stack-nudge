import SwiftUI

// The Insights tab: a spend-to-outcome overview over the handoff ledger. Reads
// the same per-branch outcome/PR maps the Tickets tab computes (nav.outcomeByBranch
// / nav.pullRequestByBranch), so shipped vs in-flight vs abandoned agrees with
// that tab. Step 1 is token-only (contextTokens, the effort proxy the Tickets tab
// shows); dollar cost and reclaimed-time land in later steps.
//
// The rollup is recomputed in `body`: it's a cheap in-memory pass over the
// bounded ledger, and reading nav's published maps + handoffsRevision means
// SwiftUI re-runs it exactly when the inputs change, so no separate cache is
// needed.
struct InsightsView: View {
    @ObservedObject var nav: PanelNav

    // Whether Codex hooks are wired (stack-nudge wrote ~/.codex/hooks.json). Used
    // only to hint, when Codex is present but absent from the rollup, that its
    // hooks likely need trusting. Read once on appear (a single fileExists).
    @State private var codexWired = false

    var body: some View {
        _ = nav.handoffsRevision   // re-run when a Stop adds a ledger row
        let summary = nav.insightsSummary()
        // Match the other tabs: content fills the pane with its own padding, and
        // the key hints sit in a shared PageFooter (divider + subtle bar), not a
        // bare row.
        return VStack(alignment: .leading, spacing: 0) {
            // Scroll the content so a tall window (many tickets/agents) can't push
            // the header off the top or collide with the footer; the footer stays
            // pinned outside the ScrollView. Matches the Sessions/Tickets tabs.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if summary.sessionCount == 0 {
                        emptyState
                    } else {
                        shippedHeadline(summary)
                        spendBar(summary)
                        bucketLegend(summary)
                        if !summary.topTickets.isEmpty { topTicketsSection(summary) }
                        if !summary.tokensByAgent.isEmpty { agentSection(summary) }
                        if !summary.tokensByModel.isEmpty { modelSection(summary.tokensByModel) }
                        // Codex present on the machine but nothing captured ⇒ its
                        // hooks probably aren't trusted (Codex skips untrusted
                        // hooks and we can't trust them for you).
                        if codexWired, summary.totalTokens > 0, summary.tokensByAgent["codex"] == nil {
                            codexHint
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ThinScrollers())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PageFooter {
                FooterHint(label: "Scroll", keys: ["↑↓"])
                FooterHint(label: "Window", keys: ["W"])
                FooterHint(label: "Tickets", keys: ["→"])
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            codexWired = FileManager.default.fileExists(
                atPath: "\(NSHomeDirectory())/.codex/hooks.json")
            // Populate the outcome/PR maps the same way the Tickets tab does, so
            // opening Insights first (without Tickets) still resolves shipped state.
            nav.refreshOutcomes?()
            nav.refreshPullRequests?()
        }
    }

    private var codexHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
            Text("Codex is set up but not captured. Trust its hooks with /hooks in Codex so its sessions land here.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Insights").font(.system(size: 14, weight: .semibold))
            Spacer()
            Button { nav.cycleInsightsWindow() } label: {
                Text(nav.insightsWindow.label)
                    .font(.caption).fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private func shippedHeadline(_ summary: InsightsSummary) -> some View {
        let pct = Int((summary.shippedShare * 100).rounded())
        return VStack(alignment: .leading, spacing: 2) {
            (Text("\(pct)% shipped").font(.system(size: 22, weight: .bold))
             + Text("  ·  \(TokenFormat.short(summary.totalTokens)) tokens")
                .font(.system(size: 13)).foregroundColor(.secondary))
            Text("\(summary.sessionCount) sessions · \(summary.ticketCount) tickets")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func spendBar(_ summary: InsightsSummary) -> some View {
        let segments = SpendBucket.allCases.compactMap { bucket -> (bucket: SpendBucket, tokens: Int)? in
            let tokens = summary.tokensByBucket[bucket] ?? 0
            return tokens > 0 ? (bucket, tokens) : nil
        }
        let total = max(1, segments.reduce(0) { $0 + $1.tokens })
        return GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(segments, id: \.bucket) { segment in
                    Rectangle()
                        .fill(color(for: segment.bucket))
                        .frame(width: geo.size.width * CGFloat(segment.tokens) / CGFloat(total))
                }
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func bucketLegend(_ summary: InsightsSummary) -> some View {
        let total = max(1, summary.totalTokens)
        return HStack(spacing: 14) {
            ForEach(SpendBucket.allCases, id: \.self) { bucket in
                let tokens = summary.tokensByBucket[bucket] ?? 0
                if tokens > 0 {
                    HStack(spacing: 5) {
                        Circle().fill(color(for: bucket)).frame(width: 8, height: 8)
                        Text(bucket.label).font(.caption)
                        Text("\(TokenFormat.short(tokens)) · \(Int((Double(tokens) / Double(total) * 100).rounded()))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // Model mix as wrapping pills. Names are shortened (ModelName.short drops the
    // redundant "claude-" prefix and any date stamp) and kept to one line, so a
    // long id can't wrap mid-word; FlowLayout wraps whole pills to the next row.
    private func modelSection(_ tokensByModel: [String: Int]) -> some View {
        let items = tokensByModel.sorted { $0.value > $1.value }.prefix(6)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(Array(items), id: \.key) { item in
                    HStack(spacing: 5) {
                        Text(ModelName.short(item.key)).font(.caption).fontWeight(.medium)
                        Text(TokenFormat.short(item.value)).font(.caption).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                }
            }
        }
    }

    // Heaviest-spend tickets/repos, with a bucket dot, dominant status, and token
    // total. Click a row to open its ticket/PR.
    private func topTicketsSection(_ summary: InsightsSummary) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Top tickets by spend").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(summary.topTickets) { ticket in
                    topTicketRow(ticket)
                }
            }
        }
    }

    private func topTicketRow(_ ticket: TicketSpend) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: ticket.bucket)).frame(width: 8, height: 8)
            Text(ticket.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 8)
            if let status = ticket.status {
                Text(statusLabel(status)).font(.caption2).foregroundStyle(.secondary)
            }
            Text(TokenFormat.short(ticket.tokens)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { nav.openInsightTicket(ticket) }
    }

    // Agent mix with each agent's shipped share: which agent's work actually merges.
    private func agentSection(_ summary: InsightsSummary) -> some View {
        let agents = summary.tokensByAgent.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            Text("Agents").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2) {
                ForEach(agents, id: \.key) { agent, tokens in
                    let shipped = summary.shippedTokensByAgent[agent] ?? 0
                    let share = tokens > 0 ? Int((Double(shipped) / Double(tokens) * 100).rounded()) : 0
                    HStack(spacing: 8) {
                        Text(agent).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 8)
                        Text(TokenFormat.short(tokens)).font(.caption).foregroundStyle(.secondary)
                        Text("\(share)% shipped").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No sessions in this window.").font(.system(size: 13, weight: .medium))
            Text("Finish an agent turn inside a git repo, or widen the window with W.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func statusLabel(_ status: OutcomeStatus) -> String {
        switch status {
        case .merged:      return "merged"
        case .pushed:      return "pushed"
        case .committed:   return "committed"
        case .needsReview: return "needs review"
        case .clean:       return "clean"
        }
    }

    private func color(for bucket: SpendBucket) -> Color {
        switch bucket {
        case .shipped:   return .green
        case .inFlight:  return .blue
        case .abandoned: return .orange
        }
    }
}
