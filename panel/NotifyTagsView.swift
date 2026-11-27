import SwiftUI

// Settings > Notifications > "Notify me about…". One toggle per feed tag. A tag
// turned off still lists its events in the Events tab; it just stops popping a
// banner, speaking and moving the companion.
struct NotifyTagsView: View {

    @ObservedObject var nav: PanelNav
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Turn a tag off and its events still land in the list, but stop popping banners.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.bottom, 4)
                        let tags = nav.notifyTagList
                        ForEach(tags.indices, id: \.self) { index in
                            tagRow(tags[index], selected: index == nav.notifyTagSelection)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                .onChange(of: nav.notifyTagSelection) { index in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.semibold))
                    Text("Settings")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Notify me about")
                .font(.subheadline.weight(.medium))
                .padding(.leading, 6)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func tagRow(_ tag: String, selected: Bool) -> some View {
        let quiet = nav.quietTags.contains(tag)
        return HStack(spacing: 8) {
            Image(systemName: quiet ? "circle" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(quiet ? Color.secondary.opacity(0.6) : Color.accentColor.opacity(0.8))
                .frame(width: 18, alignment: .center)
            Text(tag)
                .font(.callout)
                .foregroundStyle(quiet ? .tertiary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(quiet ? 0.03 : 0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            nav.notifyTagSelection = nav.notifyTagList.firstIndex(of: tag) ?? 0
            nav.toggleQuietTag(tag)
        }
    }

    private var footer: some View {
        PageFooter {
            FooterHint(label: "Toggle", keys: ["␣"], primary: true)
            FooterHint(label: "Move", keys: ["↑↓"])
            FooterHint(label: "Back", keys: ["←"])
        }
    }
}
