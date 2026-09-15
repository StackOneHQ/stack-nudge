import SwiftUI

// Placeholder host for an extension's tab. The runtime that fetches and renders
// an extension's document lands separately; this exists so the tab can be
// created, ordered and navigated to before it has anything to show.
struct ExtensionTabView: View {

    @ObservedObject var nav: PanelNav
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(nav.extensionTab(id: id)?.label ?? id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            PageFooter {
                FooterHint(label: "Hide", keys: ["Esc"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
