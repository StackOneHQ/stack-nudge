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
                FooterHint(label: footerStatusLabel, keys: [])
                if nav.usageDetailFocused {
                    FooterHint(label: "Scroll", keys: ["↑↓"])
                    FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"])
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
        // Always enter the tab in client-list focus, never stuck inside the pane.
        .onAppear { nav.usageDetailFocused = false }
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
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .padding(.leading, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tiers(for: selected)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ThinScrollers())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.visible)
            // Focus ring when the user has stepped into the pane (↑/↓ scroll).
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
            if let resets = tier.resetsAt {
                Text("Resets \(RelativeTime.string(resets, style: .full))")
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

    private var footerStatusLabel: String {
        if !nav.quotaTrackingEnabled { return "Tracking off" }
        if nav.quotaSyncing { return "Syncing…" }
        guard let updated = nav.quotaLastUpdated else { return "Never synced" }
        return "Updated \(RelativeTime.string(updated, style: .abbreviated))"
    }

}

