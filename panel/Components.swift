import AppKit
import SwiftUI

// Left-to-right flow that wraps to the next row when it runs out of width, so a
// row of variable-width pills stays tidy instead of overflowing or compressing
// its children (which makes their text wrap mid-word). macOS 13+ `Layout`.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + rowSpacing
                rowWidth = 0; rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + rowSpacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Footer hint pieces

// A keycap-shaped pill — used for inline shortcut hints throughout the UI.
struct KeyCapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.primary.opacity(0.85))
            .frame(minWidth: 14, minHeight: 16)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                    )
            )
    }
}

// One labelled hint: "Select [↑][↓]" — used in PageFooter.
struct FooterHint: View {
    let label: String
    let keys: [String]
    var primary: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption)
                .foregroundStyle(primary ? Color.primary : Color.secondary)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 2) {
                ForEach(keys, id: \.self) { KeyCapView(symbol: $0) }
            }
            .fixedSize()
        }
        .fixedSize()
        .padding(.leading, 10)
    }
}

// One hint as data. A page whose bar changes with state (the Events tab has
// three shapes and four label swaps) declares it as an array instead of
// branching inside a ViewBuilder, so the whole set is readable — and
// assertable — in one place. Mirrors the data-driven `settingsRows`.
struct FooterHintSpec: Equatable {
    let label: String
    let keys: [String]
    var primary = false
    // Rendered dimmed: the shortcut is real but doesn't apply to the current
    // row. Still occupies the bar so it doesn't reflow as selection moves.
    var dimmed = false
    // nil never sheds; lower sheds first. See ShedToFitLayout.
    var shedOrder: Int?
}

// Renders a FooterHintSpec, applying the dim and shed annotations it carries.
struct FooterHintRow: View {
    let spec: FooterHintSpec

    var body: some View {
        FooterHint(label: spec.label, keys: spec.keys, primary: spec.primary)
            .opacity(spec.dimmed ? 0.35 : 1.0)
            .footerShedOrder(spec.shedOrder ?? .max)
    }
}

// Vertical pipe between primary action and secondary hints in a footer.
struct FooterDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.15))
            .frame(width: 1, height: 14)
            .padding(.leading, 14)
            .padding(.trailing, 4)
    }
}

// MARK: - Footer overflow

// Order in which a hint is given up when the bar is narrower than its hints.
// Lower goes first. Un-annotated hints carry `.max`, so a page that doesn't opt
// in keeps every hint until there is genuinely nothing sheddable left.
// Internal rather than private so a test can read the annotation back off a real
// layout pass — that hop (spec → FooterHintRow's modifier → this key) is the one
// part of the shed mechanism that rests on SwiftUI's semantics rather than
// arithmetic, and a silent break there degrades shedding to trailing-most-first.
struct FooterShedOrderKey: LayoutValueKey {
    static let defaultValue: Int = .max
}

extension View {
    // Marks a footer hint as the first thing to give up when the panel is too
    // narrow for the whole bar. Annotate the refinements (a jump shortcut, a
    // hint that's dimmed most of the time), not the primary action.
    func footerShedOrder(_ order: Int) -> some View {
        layoutValue(key: FooterShedOrderKey.self, value: order)
    }
}

// Trailing-aligned row that drops whole hints rather than letting them run off
// the panel. FooterHint is .fixedSize() by design (so labels never wrap
// mid-word), which left `HStack { Spacer(); hints }` with no shrink path: once
// the hints' ideal widths exceeded the panel the row simply ran out past the
// leading edge, taking the primary action with it. Measuring up front and
// shedding by `footerShedOrder` means a narrow panel loses the least useful
// hint instead of clipping the most useful one. macOS 13+ `Layout`.
struct ShedToFitLayout: Layout {

    struct Cache {
        // Ideal size per subview, in declaration order.
        var sizes: [CGSize]
        // Subview indices in the order they should be given up.
        var shedOrder: [Int]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) },
              shedOrder: Self.shedSequence(of: subviews.map { $0[FooterShedOrderKey.self] }))
    }

    // The order annotations are given up in: lowest first, ties trailing-most
    // first so an un-annotated bar gives up its rightmost hint before the
    // leading primary action. Pure, and shared with makeCache so a test asserts
    // this rule rather than a copy of it.
    static func shedSequence(of orders: [Int]) -> [Int] {
        orders.indices.sorted {
            orders[$0] == orders[$1] ? $0 > $1 : orders[$0] < orders[$1]
        }
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        // Height covers every hint, shed or not, so the bar keeps a constant
        // height as the panel is resized and hints come and go.
        let height = cache.sizes.map(\.height).max() ?? 0
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: Self.idealWidth(cache), height: height)
        }
        return CGSize(width: max(width, 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let keep = Self.keptIndices(width: bounds.width, cache: cache)
        let used = keep.reduce(0) { $0 + cache.sizes[$1].width }
        var x = bounds.maxX - used
        for index in cache.sizes.indices {
            let size = cache.sizes[index]
            guard keep.contains(index) else {
                // Shed. A Layout can't remove a subview, and proposing zero is
                // ignored by .fixedSize(), so park it clear of the bar — the
                // footer clips, so it can't show or take a click.
                subviews[index].place(at: CGPoint(x: bounds.minX - size.width - 1_000,
                                                  y: bounds.midY),
                                      anchor: .leading,
                                      proposal: ProposedViewSize(size))
                continue
            }
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY),
                                  anchor: .leading,
                                  proposal: ProposedViewSize(size))
            x += size.width
        }
    }

    // Which hints survive at `width`, in declaration order. Pure and static so
    // the shed sequence can be asserted in tests against the same widths the
    // panel actually allows.
    static func keptIndices(width: CGFloat, cache: Cache) -> Set<Int> {
        var total = idealWidth(cache)
        var shed = Set<Int>()
        // Always keep one hint — an empty bar tells the user less than a
        // truncated one would.
        let mostSheddable = max(cache.sizes.count - 1, 0)
        for index in cache.shedOrder {
            if total <= width || shed.count == mostSheddable { break }
            shed.insert(index)
            total -= cache.sizes[index].width
        }
        return Set(cache.sizes.indices).subtracting(shed)
    }

    static func idealWidth(_ cache: Cache) -> CGFloat {
        cache.sizes.reduce(0) { $0 + $1.width }
    }
}

// MARK: - Page-level layout

// Bottom strip every panel page shares: hint pills on the right, hairline
// divider above, subtle tint behind. Pages just fill the hints slot. (The
// brand mark lives once in the top tab strip; the footer stays icon-free.)
struct PageFooter<Hints: View>: View {

    @ViewBuilder var hints: () -> Hints

    var body: some View {
        ShedToFitLayout {
            hints()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            ZStack {
                Color.primary.opacity(0.05)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        )
        // Backstop for the parked hints above, and for any bar that still
        // overflows because every hint is unsheddable.
        .clipped()
    }
}

// MARK: - NSScrollView introspection

// SwiftUI doesn't expose scroller width directly. Drop a zero-sized helper
// into the ScrollView's content via .background, walk up the view hierarchy
// to the underlying NSScrollView, and shrink its scroller to `.mini` —
// roughly half the default width. Also force `.overlay` style so the
// scrollbar floats over the content instead of claiming layout width and
// shifting rows left when overflow first appears (which is what users with
// "Show scroll bars: Always" in System Settings would otherwise see).
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var current: NSView? = nsView
            while let v = current {
                if let scrollView = v as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.verticalScroller?.controlSize = .mini
                    scrollView.horizontalScroller?.controlSize = .mini
                    return
                }
                current = v.superview
            }
        }
    }
}
