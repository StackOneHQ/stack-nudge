import SwiftUI

// Settings → Extensions → Other catalogues: the repositories
// STACKNUDGE_EXTENSIONS_SOURCES names, added and removed without opening the
// config file, each with when it was last read and what it may grant.
//
// The setting stays the record. This page reads it on arrival and writes it on
// every change, so an edit made by hand shows up here and one made here is in
// the file, and the catalogue is fetched again straight after so the browser
// agrees with the list.
final class ExtensionSources: ObservableObject {

    struct Row: Equatable, Identifiable {
        // As written in the setting; the app's own repository for the first row.
        let entry: String
        let source: ExtensionSource?
        let isBuiltIn: Bool
        // An entry naming a repository an earlier one already does, which the
        // fetch skips. Shown, so a repeat added by hand can be taken out.
        let repeatsEarlier: Bool
        let index: Int

        var id: String { isBuiltIn ? "builtin" : "entry-\(index)" }
        var isRemovable: Bool { !isBuiltIn }
    }

    @Published private(set) var value: String?
    @Published var draft = "" {
        didSet { if draft != oldValue { problem = nil } }
    }
    // Why the last ⏎ didn't add, until the field changes.
    @Published private(set) var problem: String?
    @Published var selection: Int?
    @Published private(set) var fieldFocusRequests = 0

    private let readValue: () -> String?
    private let writeValue: (String?) -> Void
    private let didChange: () -> Void

    init(readValue: @escaping () -> String? = { ConfigFile.read()[ExtensionSource.configKey] },
         writeValue: @escaping (String?) -> Void = ExtensionSources.persist,
         didChange: @escaping () -> Void = {}) {
        self.readValue = readValue
        self.writeValue = writeValue
        self.didChange = didChange
    }

    static func persist(_ value: String?) {
        if let value {
            ConfigFile.write(key: ExtensionSource.configKey, value: value)
        } else {
            ConfigFile.remove(key: ExtensionSource.configKey)
        }
    }

    var rows: [Row] { Self.rows(value: value) }

    static func rows(value: String?) -> [Row] {
        var seen: [ExtensionSource] = [.builtIn]
        let builtIn = Row(entry: ExtensionSource.builtIn.slug, source: .builtIn, isBuiltIn: true,
                          repeatsEarlier: false, index: 0)
        return [builtIn] + ExtensionSource.entries(value).enumerated().map { offset, entry in
            let source = ExtensionSource(slug: entry)
            let repeats = source.map { source in seen.contains { $0.sameRepository(as: source) } } ?? false
            if let source, !repeats { seen.append(source) }
            return Row(entry: entry, source: source, isBuiltIn: false, repeatsEarlier: repeats, index: offset + 1)
        }
    }

    var selectedRow: Row? {
        guard let selection, rows.indices.contains(selection) else { return nil }
        return rows[selection]
    }

    // On arrival, and after anything else may have written the file.
    func load() {
        value = readValue()
        clampSelection()
    }

    // Returns whether it was added, so the field can hand the keyboard back.
    @discardableResult
    func add() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        switch ExtensionSource.adding(text, to: readValue()) {
        case .success(let updated):
            writeValue(updated)
            value = updated
            draft = ""
            problem = nil
            selection = rows.count - 1
            didChange()
            return true
        case .failure(let failure):
            problem = failure.message
            return false
        }
    }

    func removeSelected() {
        guard let row = selectedRow, row.isRemovable else { return }
        let updated = ExtensionSource.removing(row.entry, from: readValue())
        writeValue(updated)
        value = updated
        clampSelection()
        didChange()
    }

    func move(by delta: Int) {
        let count = rows.count
        guard count > 0 else { return }
        guard let current = selection else {
            selection = delta > 0 ? 0 : count - 1
            return
        }
        selection = min(max(current + delta, 0), count - 1)
    }

    func jump(toLast: Bool) {
        selection = toLast ? rows.count - 1 : 0
    }

    func focusField() { fieldFocusRequests += 1 }

    private func clampSelection() {
        guard let current = selection else { return }
        selection = min(current, rows.count - 1)
    }

    // MARK: - What each row says

    enum Tone: Equatable { case normal, warning }

    // A row's status line. The time is the reason the page exists: a
    // repository that stopped answering looks the same as one that never
    // listed anything until you can see when it last did.
    static func status(of row: Row, sync: ExtensionCatalog.SourceSync?, loading: Bool,
                       now: Date) -> (text: String, tone: Tone) {
        guard let source = row.source else {
            return ("Not owner/repo, so it's skipped", .warning)
        }
        if !row.isBuiltIn, source.isBuiltIn {
            return ("Always read, so this entry does nothing", .normal)
        }
        if row.repeatsEarlier {
            return ("Already listed above, so this entry does nothing", .normal)
        }
        guard let sync else {
            return (loading ? "Syncing…" : "Not synced yet", .normal)
        }
        if let failure = sync.failure {
            var text = "Couldn't read it \(ago(sync.attempted, now: now)): \(failure)"
            if let synced = sync.synced { text += " Last synced \(ago(synced, now: now))." }
            return (text, .warning)
        }
        let synced = sync.synced ?? sync.attempted
        let count = sync.extensions ?? 0
        let listed = count == 1 ? "1 extension" : "\(count) extensions"
        return ("Synced \(ago(synced, now: now)) · \(listed)", .normal)
    }

    static func ago(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : RelativeTime.string(date, style: .full, relativeTo: now)
    }

    // What the repository's index may grant, from the list compiled into the
    // app (ExtensionSource.ceiling), never from anything on this page.
    static func ceilingText(of row: Row) -> String? {
        guard let source = row.source, !row.repeatsEarlier, row.isBuiltIn || !source.isBuiltIn else { return nil }
        return source.ceiling == .trusted ? "Can grant up to trusted" : "View only"
    }

    // The Settings row's trailing text.
    static func settingsValue(_ value: String?) -> String {
        let count = rows(value: value).filter { !$0.isBuiltIn }.count
        switch count {
        case 0:  return "None"
        case 1:  return "1 repo"
        default: return "\(count) repos"
        }
    }
}

struct ExtensionSourcesView: View {

    @ObservedObject var model: ExtensionSources
    @ObservedObject var catalog: ExtensionCatalog
    let onBack: () -> Void
    @Environment(\.editingText) private var editingText
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Repositories whose latest release has an extensions index. Their extensions show in the browser labelled with the repository. A private one is read with your GitHub sign-in, or the gh CLI's.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        field
                        // One clock for every row, so two rows synced together
                        // can't read a minute apart.
                        let now = Date()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { offset, row in
                                rowView(row, selected: model.selection == offset, now: now)
                                    .id(row.id)
                                    .onTapGesture { model.selection = offset }
                            }
                        }
                        Text("Removing a repository keeps what you installed from it, but each of those drops to view on the next full sync.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                .onChange(of: model.selection) { newValue in
                    guard let index = newValue, model.rows.indices.contains(index) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(model.rows[index].id, anchor: .center)
                    }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            model.load()
            catalog.loadIfNeeded()
        }
        .onChange(of: model.fieldFocusRequests) { _ in fieldFocused = true }
        // AppKit selects the field's contents when it takes focus, which would
        // replace the character that asked for it. See FieldEditor.
        .onChange(of: fieldFocused) { focused in
            if focused { FieldEditor.collapseSelectionToEnd() }
        }
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

            Text("Other catalogues")
                .font(.subheadline.weight(.medium))
                .padding(.leading, 6)

            Spacer()

            if catalog.load == .loading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add a repository, owner/repo", text: $model.draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($fieldFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
                .onSubmit {
                    if model.add() { fieldFocused = false }
                }
            if let problem = model.problem {
                Text(problem).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rowView(_ row: ExtensionSources.Row, selected: Bool, now: Date) -> some View {
        let sync = row.source.flatMap { catalog.sourceSyncs[ExtensionCatalog.syncKey($0.slug)] }
        let status = ExtensionSources.status(of: row, sync: sync, loading: catalog.load == .loading, now: now)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(row.entry)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.isBuiltIn {
                    Text("built in").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if let ceiling = ExtensionSources.ceilingText(of: row) {
                    Text(ceiling).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(status.text)
                .font(.caption2)
                .foregroundStyle(status.tone == .warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(selected ? 0.1 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(selected && !editingText ? 0.6 : 0), lineWidth: 1))
    }

    private var footer: some View {
        let removable = model.selectedRow?.isRemovable ?? false
        return PageFooter {
            FooterHint(label: "Add", keys: ["⏎"], primary: true)
            // While the field has focus these keys type or move its caret.
            FooterHint(label: "Remove", keys: ["⌘⌫"]).opacity(editingText || !removable ? 0.35 : 1)
            FooterHint(label: "Sync", keys: ["⌘R"])
            FooterHint(label: "Top/Bottom", keys: ["⌘↑↓"]).opacity(editingText ? 0.35 : 1)
            FooterHint(label: "Settings", keys: ["←"]).opacity(editingText ? 0.35 : 1)
        }
    }
}
