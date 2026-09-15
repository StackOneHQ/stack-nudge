import SwiftUI

// Renders one extension's view document. Everything here is driven by the JSON
// an extension printed — the host has no idea what any of it means, which is
// the point: the primitives are a list, a bar and an animated pixel grid, and
// an extension expresses itself by combining them.
struct ExtensionTabView: View {

    @ObservedObject var host: ExtensionHost
    let id: String

    private var pane: ExtensionHost.Pane { host.pane(id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document = pane.document {
                content(document)
            } else {
                cold
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { host.tabAppeared(id) }
    }

    // MARK: - Body

    @ViewBuilder
    private func content(_ document: ExtensionDocument) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let header = document.header { headerView(header) }
            if let placeholder = document.placeholder {
                message(placeholder, icon: document.state == .error
                        ? "exclamationmark.triangle" : "tray")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(document.rows, id: \.id) { row in
                            rowView(row)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(ThinScrollers())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // No document yet: either the first fetch is in flight, or it failed before
    // there was anything to keep.
    @ViewBuilder
    private var cold: some View {
        switch pane.status {
        case .loading:
            message("Loading…", icon: "puzzlepiece.extension")
        case .broken(let why), .stale(let why):
            message(why, icon: "exclamationmark.triangle")
        case .idle:
            message(host.manifest(id)?.name ?? id, icon: "puzzlepiece.extension")
        }
    }

    private func message(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headerView(_ header: ExtensionDocument.Header) -> some View {
        HStack(spacing: 6) {
            Text(header.title).font(.system(size: 12, weight: .semibold))
            if let badge = header.badge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Self.color(badge.tone).opacity(0.18)))
                    .foregroundStyle(Self.color(badge.tone))
            }
            Spacer(minLength: 8)
            // The stale marker sits with the header's own trailing text rather
            // than in a banner of its own: it's a qualifier on what's shown,
            // and a banner would reflow the list every time a refresh blipped.
            if let why = staleNote {
                Text(why).font(.system(size: 10)).foregroundStyle(.tertiary)
            } else if let trailing = header.trailing {
                Text(trailing).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if pane.busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var staleNote: String? {
        if case .stale(let why) = pane.status { return why }
        return nil
    }

    // MARK: - Rows

    private func rowView(_ row: ExtensionDocument.Row) -> some View {
        let selected = pane.selectedRow == row.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let lead = row.lead {
                    Text(lead)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 14, alignment: .trailing)
                }
                Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(value).font(.system(size: 11, design: .monospaced))
                }
            }
            if let track = row.track {
                trackView(track, ornament: row.ornament)
            }
            if let footnote = row.footnote {
                Text(footnote).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selected ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { host.selectRow(row.id, on: id) }
    }

    // The bar, and the paler bar behind it. Same shape as the Usage tab's pace
    // marker, which is where the ghost came from.
    private func trackView(_ track: ExtensionDocument.Track,
                           ornament: ExtensionDocument.Ornament?) -> some View {
        let tint = Self.hexColor(track.tint) ?? .accentColor
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                if let ghost = track.ghost, ghost > 0 {
                    Capsule().fill(tint.opacity(0.2))
                        .frame(width: max(ghost * geo.size.width, 2), height: 6)
                }
                Capsule().fill(tint)
                    .frame(width: max(track.fill * geo.size.width, track.fill > 0 ? 2 : 0),
                           height: 3)
                if let ornament {
                    SpriteView(ornament: ornament)
                        .offset(x: Self.spriteOffset(ornament, fill: track.fill,
                                                     width: geo.size.width))
                }
            }
            .frame(height: 6)
        }
        .frame(height: 12)
    }

    // "fill-edge" parks the sprite at the head of the bar, which is what makes a
    // progress bar read as a race. Clamped so a sprite at 100% still draws
    // inside the track rather than half off the pane.
    static func spriteOffset(_ ornament: ExtensionDocument.Ornament,
                             fill: Double, width: CGFloat) -> CGFloat {
        let columns = ornament.frames.flatMap { $0 }.map(\.count).max() ?? 0
        let sprite = CGFloat(columns) * SpriteView.cell
        switch ornament.anchor {
        case .leading:  return 0
        case .trailing: return max(width - sprite, 0)
        case .fillEdge: return min(max(CGFloat(fill) * width - sprite / 2, 0),
                                   max(width - sprite, 0))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        PageFooter {
            FooterHint(label: "Hide", keys: ["Esc"])
            if let document = pane.document, !document.rows.isEmpty {
                FooterHint(label: "Select", keys: ["↑", "↓"])
            }
            // Only bound actions get a hint; an action with no key is reachable
            // by click and would be a lie in the footer.
            ForEach(hintedActions, id: \.id) { action in
                FooterHint(label: action.label, keys: [Self.keyCap(action.key ?? "")])
            }
        }
    }

    private var hintedActions: [ExtensionDocument.Action] {
        guard let document = pane.document else { return [] }
        let rowActions = document.rows.first { $0.id == pane.selectedRow }?.actions ?? []
        return (rowActions + document.actions).filter { $0.key != nil }
    }

    static func keyCap(_ key: String) -> String {
        key == "return" ? "⏎" : key.uppercased()
    }

    // MARK: - Colours

    static func color(_ tone: ExtensionDocument.Tone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .danger:  return .red
        }
    }

    // #RGB and #RRGGBB only. Anything else returns nil and the caller falls
    // back to the accent colour — an extension shouldn't be able to make a row
    // invisible by getting its palette wrong.
    static func hexColor(_ raw: String?) -> Color? {
        guard var hex = raw?.trimmingCharacters(in: .whitespaces).lowercased(),
              hex.hasPrefix("#") else { return nil }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

// An animated pixel grid. Generic on purpose: "a grid of coloured cells" is a
// primitive the host can render without knowing anything, whereas "a horse" is
// a thing only one extension would ever ask for.
struct SpriteView: View {

    static let cell: CGFloat = 1.5

    let ornament: ExtensionDocument.Ornament

    var body: some View {
        // A still sprite doesn't get a timeline at all — a TimelineView that
        // never changes anything still wakes the view up on every tick.
        if ornament.fps > 0 && ornament.frames.count > 1 {
            TimelineView(.periodic(from: .now, by: 1 / ornament.fps)) { context in
                grid(frame(at: context.date))
            }
        } else {
            grid(ornament.frames.first ?? [])
        }
    }

    private func frame(at date: Date) -> [String] {
        let step = Int(date.timeIntervalSinceReferenceDate * ornament.fps)
        // Negative dates are not reachable through TimelineView, but the modulo
        // would be negative if they were, and an index crash in a decorative
        // sprite is not a trade worth making.
        return ornament.frames[abs(step) % ornament.frames.count]
    }

    private func grid(_ rows: [String]) -> some View {
        let width = rows.map(\.count).max() ?? 0
        return Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, key) in row.enumerated() where key != "." {
                    guard let color = ExtensionTabView.hexColor(ornament.palette[String(key)])
                    else { continue }
                    context.fill(Path(CGRect(x: CGFloat(x) * Self.cell,
                                             y: CGFloat(y) * Self.cell,
                                             width: Self.cell, height: Self.cell)),
                                 with: .color(color))
                }
            }
        }
        .frame(width: CGFloat(width) * Self.cell,
               height: CGFloat(rows.count) * Self.cell)
    }
}
