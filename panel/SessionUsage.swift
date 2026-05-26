import AppKit
import Foundation
import Security
import SwiftUI

// Quota tier reported by Anthropic's /api/oauth/usage endpoint. Each tier
// is a percentage of a budget with a known reset time. resetsAt is optional
// because some tiers (extra_usage, future tiers) don't reset on a cycle.
struct QuotaTier: Equatable {
    let utilization: Double  // 0…100
    let resetsAt: Date?
}

// Snapshot of the user's Claude Code quota at a point in time. Mirrors the
// shape of the JSON returned by api.anthropic.com/api/oauth/usage.
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
}

// Reads the Claude Code OAuth token and calls the (unofficial)
// /api/oauth/usage endpoint to fetch the user's quota state. The endpoint
// is the exact data source Claude Code's TUI statusline uses, so output
// matches `/usage` 1:1.
//
// Failure paths (no token, denied keychain access, network error, 401, 429)
// return nil and log to stderr — quota tracking is informational, never a
// critical path. The caller (PanelController) will just retry on the next
// poll tick.
final class QuotaProbe {

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let keychainService = "Claude Code-credentials"

    private let session: URLSession

    // In-memory cache of the OAuth token. Touched only from the main queue
    // (fetch is invoked from PanelController's main-thread timer, and the
    // 401-retry path hops back to main before clearing).
    //
    // Why cache: Claude Code rotates this keychain item periodically and
    // each rotation wipes the trusted-app ACL we got from "Always Allow",
    // so the next SecItemCopyMatching re-fires the password prompt. Most
    // rotations happen well before the old token actually expires, so by
    // holding the token in memory and only re-reading the keychain when
    // the API rejects it (HTTP 401), we skip the prompts tied to rotations
    // that didn't invalidate the token we already have.
    private var cachedToken: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: cfg)
    }

    // One-shot probe. Calls completion on the main queue.
    func fetch(completion: @escaping (QuotaSnapshot?) -> Void) {
        fetch(retried: false, completion: completion)
    }

    private func fetch(retried: Bool, completion: @escaping (QuotaSnapshot?) -> Void) {
        let token: String
        if let cached = cachedToken {
            token = cached
        } else if let fresh = readAccessToken() {
            cachedToken = fresh
            token = fresh
        } else {
            completion(nil)
            return
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(token)",       forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20",      forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue("stack-nudge",           forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, _ in
            let http = response as? HTTPURLResponse
            let code = http?.statusCode

            // 401 = the token we used is no longer valid (Claude Code rotated
            // and the old token has actually expired, not just been replaced).
            // Drop the cache and re-read the keychain exactly once.
            if code == 401, !retried {
                DispatchQueue.main.async {
                    self?.cachedToken = nil
                    self?.fetch(retried: true, completion: completion)
                }
                return
            }

            guard let data, code == 200,
                  let snapshot = Self.parse(data) else {
                if let code, code != 200 {
                    FileHandle.standardError.write(Data(
                        "stack-nudge: /api/oauth/usage returned \(code)\n".utf8))
                }
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(snapshot) }
        }.resume()
    }

    // MARK: - Keychain

    // Read the Claude Code credentials JSON blob from the macOS Keychain and
    // extract `claudeAiOauth.accessToken`. macOS prompts the user the first
    // time stack-nudge reads this entry; subsequent reads are silent until
    // Claude Code rotates the item, which wipes the ACL and re-fires the
    // prompt. Callers cache the returned token and only re-invoke this on
    // an API 401 to keep prompt frequency to a minimum.
    private func readAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keychainService,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                FileHandle.standardError.write(Data(
                    "stack-nudge: keychain read failed (OSStatus \(status))\n".utf8))
            }
            return nil
        }
        guard let blob = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = blob["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    // MARK: - Parsing

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parse(_ data: Data) -> QuotaSnapshot? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return QuotaSnapshot(
            fiveHour:       tier(json["five_hour"]),
            sevenDay:       tier(json["seven_day"]),
            sevenDayOpus:   tier(json["seven_day_opus"]),
            sevenDaySonnet: tier(json["seven_day_sonnet"])
        )
    }

    private static func tier(_ raw: Any?) -> QuotaTier? {
        guard let dict = raw as? [String: Any],
              let utilization = dict["utilization"] as? Double else { return nil }
        let resetsAt: Date? = (dict["resets_at"] as? String).flatMap {
            iso.date(from: $0) ?? isoNoFrac.date(from: $0)
        }
        return QuotaTier(utilization: utilization, resetsAt: resetsAt)
    }
}

// MARK: - Usage tab UI

// Renders the current QuotaSnapshot as labelled progress bars. One bar per
// non-nil tier; an "Extra usage" row when the user's plan has top-up enabled.
// Empty state covers two cases:
//   1. Probe hasn't returned yet (loading) — show a spinner.
//   2. Probe failed (no token / denied keychain / 401 / 429) — instructional
//      copy pointing the user at `claude /usage` and the in-app settings.
struct UsageView: View {

    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot = nav.quota, !isAllNil(snapshot) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                // Explicit max-height claim so the ScrollView reliably
                // bounds itself to the panel's available area instead of
                // expanding to fit its content (which clipped behind the
                // PageFooter without a visible scrollbar hint). Force the
                // indicator visible so users can tell there's more to see.
                .frame(maxHeight: .infinity)
                .scrollIndicators(.visible)
            } else {
                emptyState
            }

            PageFooter {
                FooterHint(label: footerStatusLabel, keys: [])
                FooterHint(label: "Hide", keys: ["esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Spacer()
                Text("\(Int(tier.utilization.rounded()))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor(tier.utilization))
            }
            ProgressView(value: min(tier.utilization, 100), total: 100)
                .tint(barColor(tier.utilization))
            if let resets = tier.resetsAt {
                Text("Resets \(Self.relative(.full, resets))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
    }

    // Treat a snapshot with all tiers nil the same as no snapshot at all —
    // user sees the empty state rather than a blank page. Shouldn't happen
    // for a real subscription, but covers anomalous endpoint responses.
    private func isAllNil(_ s: QuotaSnapshot) -> Bool {
        s.fiveHour == nil && s.sevenDay == nil
            && s.sevenDayOpus == nil && s.sevenDaySonnet == nil
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading quota…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Requires Claude Code login. First read may prompt the system keychain.")
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
        guard let updated = nav.quotaLastUpdated else { return "Loading…" }
        return "Updated \(Self.relative(.abbreviated, updated))"
    }

    // Cached so SwiftUI re-renders don't allocate a fresh formatter on
    // every call. Two styles cover all current uses (full for "Resets in
    // 3 days", abbreviated for footer "Updated 5s ago").
    private static let fullFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
    private static let abbreviatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static func relative(_ style: RelativeDateTimeFormatter.UnitsStyle,
                                 _ date: Date) -> String {
        let formatter = (style == .abbreviated) ? abbreviatedFormatter : fullFormatter
        return formatter.localizedString(for: date, relativeTo: Date())
    }

}

