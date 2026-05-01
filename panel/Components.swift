import AppKit
import SwiftUI

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

// Bottom strip every panel page shares: bell icon on the left, hint pills on
// the right, hairline divider above, subtle tint behind. Pages just fill the
// hints slot.
struct PageFooter<Hints: View>: View {

    @ViewBuilder var hints: () -> Hints

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "bell.badge.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
// roughly half the default width.
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            var current: NSView? = nsView
            while let v = current {
                if let scrollView = v as? NSScrollView {
                    scrollView.verticalScroller?.controlSize = .mini
                    scrollView.horizontalScroller?.controlSize = .mini
                    return
                }
                current = v.superview
            }
        }
    }
}
