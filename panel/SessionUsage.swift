import AppKit
import Foundation
import SwiftUI

// Quota tier surfaced by the `claude` CLI's `/usage` output. Each tier
// is a percentage of a budget with a known reset time. resetsAt is optional
// because some tiers (extra_usage, future tiers) don't reset on a cycle.
struct QuotaTier: Equatable {
    let utilization: Double  // 0…100
    let resetsAt: Date?
}

// Snapshot of the user's Claude Code quota at a point in time. Built from
// the `claude --print /usage` output — the same data Claude Code's TUI shows.
//
// fiveHour       → "Current session" — the 5-hour rolling window the TUI shows.
// sevenDay       → "Current week (all models)".
// sevenDayOpus   → "Current week (Opus only)" — nil on plans without one.
// sevenDaySonnet → "Current week (Sonnet only)" — nil on plans without one.
struct QuotaSnapshot: Equatable {
    let fiveHour: QuotaTier?
    let sevenDay: QuotaTier?
    let sevenDayOpus: QuotaTier?
    let sevenDaySonnet: QuotaTier?
    // Subscription tier from the claudeAiOauth blob (e.g. "max", "pro"); nil
    // when the field is absent. Shown next to the agent name in the Usage tab.
    let planType: String?
}

// A connected client shown in the Usage tab's left-hand list. Each renders its
// own quota tiers; ↑/↓ switches between the ones that currently have data.
enum UsageClient: String, CaseIterable, Hashable {
    case claude
    case codex
    case antigravity

    var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .codex:       return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    // Where this client's replayable token history lives, or nil when it has
    // none. Claude and Codex both write per-turn token usage with a timestamp
    // into their transcripts. Antigravity's history.jsonl carries only prompt
    // text, timestamp and workspace — no token data at all — and its quota comes
    // from a live API call, so there's nothing to plot retrospectively.
    //
    // Returning the source rather than a Bool keeps the mapping exhaustive: a new
    // client can't silently inherit another agent's transcript format.
    var historySource: UsageHistoryStore.Source? {
        switch self {
        case .claude:      return .claude
        case .codex:       return .codex
        case .antigravity: return nil
        }
    }

    var hasReplayableHistory: Bool { historySource != nil }
}

// Panes of the Usage tab's inner carousel, in step order. → walks forward while
// the detail holds focus; ← walks back and then out to the client list.
enum UsagePane: CaseIterable {
    case quota
    case history

    var label: String {
        switch self {
        case .quota:   return "Quota"
        // Not "24h" — the window is user-cyclable, so naming it here would go
        // stale the moment they switch to 6h. The active window shows in the
        // chart header instead.
        case .history: return "History"
        }
    }
}

// MARK: - Usage tab UI

// Renders the current QuotaSnapshot as labelled progress bars. One bar per
// non-nil tier; an "Extra usage" row when the user's plan has top-up enabled.
// Empty state covers two cases:
//   1. Probe hasn't returned yet (loading) — show a spinner.
//   2. Probe failed (no `claude` CLI on PATH, not signed in, or unparseable
//      output) — instructional copy pointing the user at `claude /usage`.
struct UsageView: View {

    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !nav.quotaTrackingEnabled {
                trackingDisabledState
            } else if !nav.availableUsageClients.isEmpty {
                clientSplit
            } else {
                emptyState
            }

            PageFooter {
                if nav.usageDetailFocused {
                    // The history pane has nothing to scroll, so ↑/↓ cycle the
                    // plotted metric there instead — and ⌘↑↓ has no meaning.
                    if nav.usagePane == .history {
                        FooterHint(label: "Metric", keys: ["↑↓"])
                        FooterHint(label: "Window", keys: ["W"])
                    } else {
                        FooterHint(label: "Scroll", keys: ["↑↓"])
                        FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
                    }
                    if nav.usagePane != UsagePane.allCases.last {
                        FooterHint(label: UsagePane.allCases.last?.label ?? "Next", keys: ["→"])
                    }
                    FooterHint(label: "Back", keys: ["←"])
                } else {
                    if nav.availableUsageClients.count > 1 {
                        FooterHint(label: "Switch", keys: ["↑↓"])
                        FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
                    }
                    if !nav.availableUsageClients.isEmpty {
                        FooterHint(label: "Enter", keys: ["→"])
                    }
                }
                if nav.quotaTrackingEnabled {
                    FooterHint(label: "Sync now", keys: ["R"])
                }
                FooterHint(label: nav.quotaTrackingEnabled ? "Pause" : "Resume", keys: ["P"])
                FooterHint(label: "Hide",    keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Always enter the tab in client-list focus on the first carousel pane,
        // never stuck inside the pane or on a pane the user last left behind.
        .onAppear {
            nav.usageDetailFocused = false
            nav.usagePane = .quota
        }
    }

    // Left: one row per connected client (↑/↓ or click to select). Right: the
    // selected client's quota tiers, scrollable in case a client has several.
    private var clientSplit: some View {
        let clients = nav.availableUsageClients
        let selected = clients[min(nav.clampedUsageClientIndex, max(0, clients.count - 1))]
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(clients, id: \.self) { client in
                    clientRow(client, isSelected: client == selected)
                }
                Spacer(minLength: 0)
                // Sync freshness lives here rather than in the footer: it
                // describes the whole tab (not one carousel pane), and the
                // footer had run out of room once the carousel added its own
                // hints. The column already ended in slack space.
                syncStatus
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .padding(.leading, 6)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                paneIndicator
                switch nav.usagePane {
                case .quota:   quotaPane(for: selected)
                case .history: historyPane(for: selected)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Focus ring when the user has stepped into the carousel.
            .overlay(alignment: .top) {
                if nav.usageDetailFocused {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // Carousel position. Always rendered so the second pane is discoverable
    // without pressing → to find out it exists; dimmed until the carousel
    // actually holds focus, matching how the client rows de-emphasise once
    // focus moves on.
    private var paneIndicator: some View {
        HStack(spacing: 6) {
            ForEach(UsagePane.allCases, id: \.self) { pane in
                let active = pane == nav.usagePane
                Text(pane.label)
                    .font(.caption2.weight(active ? .semibold : .regular))
                    .foregroundStyle(active
                                     ? (nav.usageDetailFocused ? Color.accentColor : Color.primary)
                                     : Color.primary.opacity(0.35))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(active ? Color.accentColor.opacity(nav.usageDetailFocused ? 0.14 : 0.06)
                                         : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        nav.usagePane = pane
                        nav.usageDetailFocused = true
                        if pane == .history { nav.refreshUsageSeries() }
                    }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func quotaPane(for client: UsageClient) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                tiers(for: client)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThinScrollers())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.visible)
    }

    private func clientRow(_ client: UsageClient, isSelected: Bool) -> some View {
        // Selection is shown brightly only while the client list holds focus;
        // once focus steps into the detail pane it's de-emphasised so it's clear
        // ↑/↓ now scroll rather than switch.
        let activeSelection = isSelected && !nav.usageDetailFocused
        return VStack(alignment: .leading, spacing: 1) {
            Text(client.displayName)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(activeSelection ? Color.accentColor
                                 : (isSelected ? .primary : .secondary))
            if let plan = planLabel(for: client) {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected
                      ? Color.accentColor.opacity(activeSelection ? 0.12 : 0.05)
                      : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let idx = nav.availableUsageClients.firstIndex(of: client) {
                nav.usageClientIndex = idx
                nav.usageDetailFocused = false
            }
        }
    }

    @ViewBuilder private func tiers(for client: UsageClient) -> some View {
        switch client {
        case .claude:
            if let snapshot = nav.quota {
                if let tier = snapshot.fiveHour {
                    section("Current session") { tierRow(tier) }
                }
                if let tier = snapshot.sevenDay {
                    section("Current week (all models)") { tierRow(tier) }
                }
                if let tier = snapshot.sevenDayOpus {
                    section("Current week (Opus only)") { tierRow(tier) }
                }
                if let tier = snapshot.sevenDaySonnet {
                    section("Current week (Sonnet only)") { tierRow(tier) }
                }
            }
        case .codex:
            if let codex = nav.codexQuota {
                if let tier = codex.primary {
                    section("Current session (5h)") { tierRow(tier) }
                }
                if let tier = codex.secondary {
                    section("Current week") { tierRow(tier) }
                }
            }
        case .antigravity:
            if let agy = nav.antigravityQuota {
                // One bar per model — agy reports a separate quota window per
                // model, each with its own reset time.
                ForEach(agy.models, id: \.label) { model in
                    section(model.label) { tierRow(model.tier) }
                }
                if agy.promptCredits != nil || agy.flowCredits != nil {
                    section("Credits") { creditsRow(agy) }
                }
            }
        }
    }

    // MARK: - History pane

    // Replayed transcript history for the selected client. Deliberately labelled
    // as token throughput rather than quota: the bars on the previous pane come
    // from the provider's own quota accounting, which is weighted per model and
    // plan and counts usage from other machines, so the two will not agree.
    @ViewBuilder
    private func historyPane(for client: UsageClient) -> some View {
        if !client.hasReplayableHistory {
            historyMessage(
                icon: "clock.badge.questionmark",
                title: "No history for \(client.displayName)",
                detail: "\(client.displayName) doesn't record token usage to disk, so there's nothing to replay. Its quota above is read live."
            )
        } else if let series = nav.usageSeries(for: client), series.hasActivity {
            let metric = nav.usageMetric
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metric.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    // The window lives here rather than in the pane label, since
                    // W cycles it.
                    Text(nav.usageWindow.label)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.green.opacity(0.14))
                        )
                    Spacer()
                    Text(metricValue(series.total(for: metric), metric))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
                UsageSparkline(series: series, metric: metric)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                axisLabels(series)
                if let peak = series.peakBucket(for: metric), peak.value(for: metric) > 0 {
                    Text("Peak \(metricValue(peak.value(for: metric), metric)) at \(Self.clockLabel(peak.start))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        } else if nav.usageSeriesLoading {
            historyLoading
        } else {
            historyMessage(
                icon: "chart.line.flattrend.xyaxis",
                title: "No activity in the last 24 hours",
                detail: "This replays \(client.displayName)'s transcripts, so it fills in as soon as there are turns to plot."
            )
        }
    }

    private var historyLoading: some View {
        historyPlaceholder {
            ProgressView().controlSize(.small)
            Text("Reading transcripts…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func historyMessage(icon: String, title: String, detail: String) -> some View {
        historyPlaceholder {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func historyPlaceholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 20)
    }

    // Four evenly spaced clock labels across the window — as many as fit legibly
    // in the ~465pt the pane gets at the panel's default width.
    private func axisLabels(_ series: UsageSeries) -> some View {
        let span = series.windowEnd.timeIntervalSince(series.windowStart)
        let stops = (0...3).map { series.windowStart.addingTimeInterval(span * Double($0) / 3.0) }
        return HStack(spacing: 0) {
            ForEach(stops.indices, id: \.self) { index in
                Text(Self.clockLabel(stops[index]))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                if index < stops.count - 1 { Spacer(minLength: 0) }
            }
        }
    }

    private func metricValue(_ value: Int, _ metric: UsageMetric) -> String {
        metric == .turns ? "\(value)" : TokenFormat.short(value)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func clockLabel(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private func creditsRow(_ agy: AntigravityQuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let prompt = agy.promptCredits {
                Text("Prompt: \(prompt.available) / \(prompt.monthly)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let flow = agy.flowCredits {
                Text("Flow: \(flow.available) / \(flow.monthly)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
    }

    // Subscription tier shown under the client name (e.g. "Max", "Plus").
    private func planLabel(for client: UsageClient) -> String? {
        switch client {
        case .claude:      return nav.quota?.planType?.capitalized
        case .codex:       return nav.codexQuota?.planType?.capitalized
        case .antigravity: return nav.antigravityQuota?.planType?.capitalized
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 6)
            content()
        }
    }

    private func tierRow(_ tier: QuotaTier) -> some View {
        // Show "30% used" or "70% remaining" depending on the toggle. Bar
        // still represents utilization so the color ramp keeps its meaning.
        let display = nav.quotaShowRemaining
            ? max(0, 100 - tier.utilization)
            : tier.utilization
        let suffix  = nav.quotaShowRemaining ? "% left" : "%"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer()
                Text("\(Int(display.rounded()))\(suffix)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor(tier.utilization))
            }
            ProgressView(value: min(tier.utilization, 100), total: 100)
                .tint(barColor(tier.utilization))
            // Hidden rather than rendered as "Resets 11 months ago" when the
            // deadline has passed — that only happens on a stale snapshot, and a
            // silent row beats a confidently wrong one.
            if let resets = tier.resetsAt, let label = QuotaReset.relativeLabel(until: resets) {
                Text("Resets \(label)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
    }


    private var emptyState: some View {
        VStack(spacing: 10) {
            if let error = nav.quotaError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("StackNudge reads your usage by running `claude /usage`. This clears on its own once the CLI is on PATH, signed in, and its output is parseable again.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Loading usage…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Requires the `claude` CLI signed in (Claude reads usage via `claude /usage`), or a Codex session on a ChatGPT plan.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    private var trackingDisabledState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Quota tracking is off")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Enable in Settings → Usage → Quota tracking to see your Claude usage here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    // Green < 50 < yellow < 80 < red. Matches ClaudeBar's color thresholds
    // so users coming from there see familiar colors.
    private func barColor(_ utilization: Double) -> Color {
        if utilization >= 80 { return .red }
        if utilization >= 50 { return .yellow }
        return .green
    }

    // Foot of the client column. Wraps rather than truncating — the column is
    // 104pt wide and "Updated 15m ago" doesn't fit on one line there.
    private var syncStatus: some View {
        Text(syncStatusLabel)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    // No "tracking off" case: the column only renders inside clientSplit, which
    // is gated on quotaTrackingEnabled — trackingDisabledState owns that message.
    private var syncStatusLabel: String {
        if nav.quotaSyncing { return "Syncing…" }
        guard let updated = nav.quotaLastUpdated else { return "Never synced" }
        return "Updated \(RelativeTime.string(updated, style: .abbreviated))"
    }

}


// Hand-drawn area chart. Swift Charts is available (deployment target is macOS
// 13) but its axis and legend chrome costs more room than the plot itself at
// this size — the pane gets ~465x140pt — and the rest of the panel is drawn by
// hand, so this keeps the look consistent and the swiftc build dependency-free.
//
// Every bucket is plotted, empty ones included: over a real 24h only ~22% of
// five-minute buckets have activity, so filling to a baseline reads as bursts of
// work, where a line that skips the gaps reads as broken data.
private struct UsageSparkline: View {

    let series: UsageSeries
    let metric: UsageMetric

    // The same green the quota bars use at low utilization, and the one the
    // mascots and Settings toggles use — this plots token counts, which have no
    // threshold semantics, so it stays green throughout rather than ramping to
    // yellow/red the way a utilization bar does.
    private static let plotColor = Color.green

    var body: some View {
        GeometryReader { geometry in
            let width  = geometry.size.width
            let height = geometry.size.height
            let peak   = max(1, series.peakValue(for: metric))
            let values = series.buckets.map { $0.value(for: metric) }
            // Guard the single-bucket case so the divisor can't be zero.
            let step   = values.count > 1 ? width / CGFloat(values.count - 1) : width
            let lastX  = CGFloat(max(0, values.count - 1)) * step

            let pointY: (Int) -> CGFloat = { value in
                height - (CGFloat(value) / CGFloat(peak)) * height
            }

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in values.enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(index) * step, y: pointY(value)))
                    }
                    path.addLine(to: CGPoint(x: lastX, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [Self.plotColor.opacity(0.45), Self.plotColor.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(x: CGFloat(index) * step, y: pointY(value))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(Self.plotColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                // Baseline, so an all-quiet stretch still reads as an axis
                // rather than as empty space.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height - 0.5))
                    path.addLine(to: CGPoint(x: width, y: height - 0.5))
                }
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            }
            // The peak value is printed rather than drawing a y-axis: one number
            // is enough to scale the shape mentally, and ticks would eat most of
            // the pane's height.
            .overlay(alignment: .topTrailing) {
                Text(metric == .turns ? "\(peak)" : TokenFormat.short(peak))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
