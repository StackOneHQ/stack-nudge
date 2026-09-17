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
            // A marker for anything that isn't a clean, current document. It sits
            // above the header rather than inside it because `header` is
            // optional: a headerless document used to go stale, or spin, with
            // nothing on screen to say so.
            if let note = statusNote { statusStrip(note) }
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

    // MARK: - Status

    // Any status worth showing over a live document. `.broken` belongs here too:
    // it used to be rendered only by `cold`, which is the no-document branch, so
    // a script that started erroring left last hour's numbers on screen with no
    // marker at all — the exact failure the stale/broken split exists to prevent.
    private var statusNote: (text: String, spinning: Bool)? {
        guard pane.document != nil else { return nil }
        switch pane.status {
        case .idle:            return pane.busy ? ("Refreshing…", true) : nil
        case .loading:         return ("Refreshing…", true)
        case .stale(let why):  return ("Showing older data · \(why)", false)
        case .broken(let why): return (why, false)
        }
    }

    private func statusStrip(_ note: (text: String, spinning: Bool)) -> some View {
        HStack(spacing: 5) {
            if note.spinning {
                ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
            }
            Text(note.text).font(.system(size: 10)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(document.rows, id: \.id) { row in
                                rowView(row).id(row.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .background(ThinScrollers())
                    // Keyboard selection has to bring its row with it; ↑/↓ past
                    // the fold otherwise move an invisible highlight, and ⏎ acts
                    // on a row the user can't see. Every other list pane here
                    // does this (see OutcomesView, Sessions, Phrases).
                    .onChange(of: pane.selectedRow) { selected in
                        guard let selected else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selected, anchor: .center)
                        }
                    }
                }
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
                // Bounded: `message` comes from the extension, and an unbounded
                // one would push the pane apart with no scroller to catch it.
                .lineLimit(6)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Rows are line-limited; the header used to not be, so a long title wrapped
    // and pushed the list down inside a fixed-height panel, and a long badge
    // wrapped inside its own capsule.
    private func headerView(_ header: ExtensionDocument.Header) -> some View {
        HStack(spacing: 6) {
            Text(header.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if let badge = header.badge {
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Self.color(badge.tone).opacity(0.18)))
                    .foregroundStyle(Self.color(badge.tone))
            }
            Spacer(minLength: 8)
            if let trailing = header.trailing {
                Text(trailing).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
                        .lineLimit(1)
                }
                Text(row.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let subtitle = row.subtitle {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(value).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                }
            }
            // The ornament no longer rides on the track's existence — it used to
            // be passed only into trackView, so a row without a bar silently
            // dropped a sprite that had parsed perfectly well.
            if row.track != nil || row.ornament != nil {
                trackView(row.track, ornament: row.ornament, label: row.title, value: row.value)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // The bar, and the paler bar behind it. Same shape as the Usage tab's pace
    // marker — including the second frame, which centres the capsules in their
    // slot; without it the bar hugs the top of a 12pt band and sits visibly
    // closer to the title than to the footnote.
    private func trackView(_ track: ExtensionDocument.Track?,
                           ornament: ExtensionDocument.Ornament?,
                           label: String,
                           value: String?) -> some View {
        let tint = Self.readable(Self.hexColor(track?.tint)) ?? .accentColor
        let fill = track?.fill ?? 0
        let band = Self.bandHeight(for: ornament)
        return GeometryReader { geo in
            // Bottom-aligned so the bar sits at the foot of the band and a
            // sprite stands *on* it. Centring both put the track line through
            // the sprite's legs, which reads as a horse wading rather than
            // running.
            ZStack(alignment: .bottomLeading) {
                if track != nil {
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: Self.barHeight)
                    if let ghost = track?.ghost, ghost > 0 {
                        Capsule().fill(tint.opacity(0.2))
                            .frame(width: max(ghost * geo.size.width, 2), height: Self.barHeight)
                    }
                    Capsule().fill(tint)
                        .frame(width: max(fill * geo.size.width, fill > 0 ? 2 : 0), height: 3)
                }
                if let ornament {
                    SpriteView(ornament: ornament)
                        .offset(x: Self.spriteOffset(ornament, fill: fill, width: geo.size.width),
                                // Hooves land on the bar's centre line rather
                                // than below it, so the sprite rides the track.
                                y: -Self.barHeight / 2)
                        // Decoration only, and it is taller than its band: an
                        // uncapped sprite used to spill into the title above and
                        // the row below.
                        .accessibilityHidden(true)
                }
            }
            .frame(height: band)
            .clipped()
        }
        .frame(height: band)
        // The bar *is* the information when a row has no `value` — the Usage tab
        // annotates exactly this widget the same way (see SessionUsage.paceBar).
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value ?? Self.percentLabel(fill)))
        .accessibilityHidden(track == nil)
    }

    // The row's bar band. Tall enough for whatever sprite rides on it, because
    // clipping a sprite to the bar's own 6pt is how an 11-row horse ends up as a
    // 4-row smudge — the overflow fix has to make room, not just cut. The bar
    // stays 6pt and centres itself inside the band.
    static let barHeight: CGFloat = 6

    static func bandHeight(for ornament: ExtensionDocument.Ornament?) -> CGFloat {
        guard let ornament else { return 12 }
        // Room for the whole sprite standing on the bar's centre line, plus a
        // point of headroom so a tall one doesn't touch the title above.
        let sprite = CGFloat(SpriteView.rows(ornament)) * SpriteView.cell
        return max(12, sprite + barHeight / 2 + 1)
    }

    static func percentLabel(_ fill: Double) -> String {
        "\(Int((min(max(fill, 0), 1) * 100).rounded()))%"
    }

    // "fill-edge" parks the sprite at the head of the bar, which is what makes a
    // progress bar read as a race. Clamped so a sprite at 100% still draws
    // inside the track rather than half off the pane.
    static func spriteOffset(_ ornament: ExtensionDocument.Ornament,
                             fill: Double, width: CGFloat) -> CGFloat {
        let sprite = CGFloat(SpriteView.columns(ornament)) * SpriteView.cell
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
            // Only bound actions get a hint. An action whose key request was
            // refused has no shortcut and no button, so advertising it would be
            // a lie — see the note on ExtensionKey.
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

    // Keep an extension's colour distinguishable from the surface behind it.
    // A well-formed #FFFFFF is an invisible bar in light mode and #111111 is
    // invisible in dark, so rejecting only *malformed* hex left the interesting
    // half of the problem open. Resolved per-appearance rather than clamped to a
    // fixed palette, so a colour that reads well in one theme isn't dulled in
    // the other.
    static func readable(_ color: Color?) -> Color? {
        // NSApp is nil outside a running application — under the test runner,
        // and briefly at launch — and it is an implicitly unwrapped optional, so
        // reading it unguarded is a crash rather than a wrong colour.
        readable(color, dark: NSApp?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    // How dark a colour may be on a dark background, and how light on a light
    // one, before it is pulled back toward legibility.
    static let luminanceFloor = 0.35
    static let luminanceCeiling = 0.75

    static func luminance(_ color: Color) -> Double {
        let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    static func readable(_ color: Color?, dark: Bool) -> Color? {
        guard let color else { return nil }
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return color }
        let light = luminance(color)

        // Solved in luminance terms rather than handed to NSColor.blended,
        // which mixes through its own colour space and overshot the target by
        // enough to matter. Both branches move every channel the same way, so
        // hue survives: a pale yellow stops being white and stays yellow.
        let adjusted: NSColor
        if dark, light < luminanceFloor {
            // Toward white: c' = c + f(1 - c) lifts luminance to L + f(1 - L),
            // so the fraction follows directly. Guard the degenerate L == 1.
            guard light < 1 else { return color }
            let fraction = (luminanceFloor - light) / (1 - light)
            adjusted = NSColor(srgbRed: rgb.redComponent + fraction * (1 - rgb.redComponent),
                               green: rgb.greenComponent + fraction * (1 - rgb.greenComponent),
                               blue: rgb.blueComponent + fraction * (1 - rgb.blueComponent),
                               alpha: rgb.alphaComponent)
        } else if !dark, light > luminanceCeiling {
            // Toward black is a plain scale, and luminance scales with it.
            guard light > 0 else { return color }
            let scale = luminanceCeiling / light
            adjusted = NSColor(srgbRed: rgb.redComponent * scale,
                               green: rgb.greenComponent * scale,
                               blue: rgb.blueComponent * scale,
                               alpha: rgb.alphaComponent)
        } else {
            return color
        }
        return Color(nsColor: adjusted)
    }
}

// An animated pixel grid. Generic on purpose: "a grid of coloured cells" is a
// primitive the host can render without knowing anything, whereas "a horse" is
// a thing only one extension would ever ask for.
struct SpriteView: View {

    static let cell: CGFloat = 1.5

    let ornament: ExtensionDocument.Ornament

    // One width for the whole sprite, taken across every frame. Sizing the
    // canvas from the *current* frame while anchoring from the global maximum
    // made a ragged sprite resize and jump on every tick, and park left of the
    // fill edge.
    static func columns(_ ornament: ExtensionDocument.Ornament) -> Int {
        ornament.frames.flatMap { $0 }.map(\.count).max() ?? 0
    }

    static func rows(_ ornament: ExtensionDocument.Ornament) -> Int {
        ornament.frames.map(\.count).max() ?? 0
    }

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
        Canvas { context, _ in
            for (y, row) in rows.enumerated() {
                for (x, key) in row.enumerated() where key != "." {
                    // A palette entry that doesn't parse falls back rather than
                    // skipping the cell: a whole sprite silently failing to draw
                    // reads as a rendering bug, not as a bad colour string.
                    let color = ExtensionTabView.readable(
                        ExtensionTabView.hexColor(ornament.palette[String(key)])) ?? .accentColor
                    context.fill(Path(CGRect(x: CGFloat(x) * Self.cell,
                                             y: CGFloat(y) * Self.cell,
                                             width: Self.cell, height: Self.cell)),
                                 with: .color(color))
                }
            }
        }
        // Sized from the sprite as a whole, so the frame doesn't change size
        // under a ragged animation.
        .frame(width: CGFloat(Self.columns(ornament)) * Self.cell,
               height: CGFloat(Self.rows(ornament)) * Self.cell)
    }
}
