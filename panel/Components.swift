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

// MARK: - Page-level layout

// Bottom strip every panel page shares: hint pills on the right, hairline
// divider above, subtle tint behind. Pages just fill the hints slot. (The
// brand mark lives once in the top tab strip; the footer stays icon-free.)
struct PageFooter<Hints: View>: View {

    @ViewBuilder var hints: () -> Hints

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
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
