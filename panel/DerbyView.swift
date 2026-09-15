import AppKit
import SwiftUI

// The Token Derby standings. One row per horse, bar drawn against the leader's
// total so the field's spread is the thing you see.
struct DerbyView: View {

    @ObservedObject var nav: PanelNav

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let race = nav.derbyRace {
                header(race)
                Divider().opacity(0.4)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(race.horses, id: \.id) { horse in
                            row(horse, leader: race.leaderTokens, race: race)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            } else {
                empty
            }

            PageFooter {
                FooterHint(label: "Sync now", keys: ["R"])
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ race: DerbyRace) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(race.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            statusPill(race)
            Spacer()
            if race.isLive, let left = race.timeLeftSeconds, left > 0 {
                Text(QuotaReset.shortLabel(until: Date().addingTimeInterval(TimeInterval(left))) ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func statusPill(_ race: DerbyRace) -> some View {
        let color: Color = race.isLive ? .green : (race.status == "pending" ? .orange : .secondary)
        return Text(race.status.uppercased())
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private func row(_ horse: DerbyHorse, leader: Double, race: DerbyRace) -> some View {
        let fraction = leader > 0 ? horse.tokens / leader : 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(horse.rank.map(String.init) ?? "–")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, alignment: .trailing)
                Text(horse.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let who = horse.userName {
                    Text(who).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(TokenFormat.short(Int(horse.tokens)))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let lane = max(geo.size.width - DerbySprite.width, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                        .frame(height: 5)
                    Capsule().fill(tint(horse))
                        .frame(width: max(fraction * lane, fraction > 0 ? 2 : 0), height: 5)
                    DerbySprite(coat: tint(horse),
                                mane: accent(horse),
                                running: race.isLive && (horse.pace15m ?? 0) > 0)
                        .offset(x: fraction * lane)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: DerbySprite.height)
            if let pace = horse.pace15m, pace > 0 {
                Text("\(TokenFormat.short(Int(pace)))/15m" + divisionSuffix(horse, race))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else if !divisionSuffix(horse, race).isEmpty {
                Text(String(divisionSuffix(horse, race).dropFirst(3)))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    private func divisionSuffix(_ horse: DerbyHorse, _ race: DerbyRace) -> String {
        // division is 1-based into league_division_names.
        guard let d = horse.division, d >= 1, race.divisionNames.indices.contains(d - 1) else { return "" }
        return " · \(race.divisionNames[d - 1])"
    }

    // The horse's own body colour, so the field reads like the race does. Most
    // of them are white, which is exactly right on this panel — only near-black
    // coats fall back, since those disappear into it. The darker mane keeps the
    // silhouette legible either way.
    private func tint(_ horse: DerbyHorse) -> Color {
        guard let hex = horse.bodyColor, let c = Color(hex: hex) else { return .accentColor }
        guard let luma = NSColor(c).usingColorSpace(.deviceRGB)?.brightnessComponent,
              luma > 0.20 else { return .accentColor }
        return c
    }

    // Mane and tail, from the horse's own colours where they read against the
    // panel; otherwise a darker shade of the coat so the silhouette still has
    // a mane rather than a hole in it.
    private func accent(_ horse: DerbyHorse) -> Color {
        let coat = tint(horse)
        guard let ns = NSColor(coat).usingColorSpace(.deviceRGB) else { return coat }
        return Color(nsColor: ns.blended(withFraction: 0.45, of: .black) ?? ns)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.equestrian.sports")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(nav.derbySyncing ? "Loading the field…" : "No race to show")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !nav.derbySyncing {
                Text("Set STACKNUDGE_DERBY_ORG to your organisation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Color {
    // "#RRGGBB" only — the derby emits nothing else.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// A horse drawn rather than fetched: the derby's own sprites are Aseprite
// sources for the crowd and track, and its runners are tinted from the same
// body/mane colours the API hands us. Two frames at 7fps — at this size the
// silhouette carries it, so the legs gather and splay rather than articulate.
struct DerbySprite: View {

    let coat: Color
    let mane: Color
    let running: Bool

    private static let px: CGFloat = 1.5
    private static let cols = 16
    private static let rows = 11
    static var width: CGFloat { CGFloat(cols) * px }
    static var height: CGFloat { CGFloat(rows) * px }

    // B body · H head · L leg · M mane · T tail · . empty
    private static let legsTogether = [
        "...........HHHH.",
        "..........MHHHHH",
        ".........MMHH...",
        "T.......MMB.....",
        "TTT...BBBBB.....",
        ".TTBBBBBBBB.....",
        "..TBBBBBBBB.....",
        "...BBBBBBB......",
        "...L.L..L.L.....",
        "...L.L..L.L.....",
        "...L.L..L.L.....",
    ]
    private static let legsSplayed = [
        "...........HHHH.",
        "..........MHHHHH",
        ".........MMHH...",
        "T.......MMB.....",
        "TTT...BBBBB.....",
        ".TTBBBBBBBB.....",
        "..TBBBBBBBB.....",
        "...BBBBBBB......",
        "..L...L.L...L...",
        "..L...L.L...L...",
        "..L...L.L...L...",
    ]

    var body: some View {
        Group {
            if running {
                // Only a live horse animates. A finished race is a standings
                // table, and 14 TimelineViews redrawing for nothing is the cost
                // the compact widget already learned to avoid.
                TimelineView(.periodic(from: .now, by: 0.14)) { context in
                    let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.14)
                    sprite(tick % 2 == 0 ? Self.legsTogether : Self.legsSplayed)
                }
            } else {
                sprite(Self.legsTogether)
            }
        }
        .frame(width: Self.width, height: Self.height)
    }

    private func sprite(_ rows: [String]) -> some View {
        Canvas { ctx, _ in
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() {
                    guard let color = paint(ch) else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(x) * Self.px, y: CGFloat(y) * Self.px,
                                         width: Self.px, height: Self.px)),
                             with: .color(color))
                }
            }
        }
    }

    private func paint(_ ch: Character) -> Color? {
        switch ch {
        case "B", "H", "L": return coat
        case "M", "T":      return mane
        default:            return nil
        }
    }
}
