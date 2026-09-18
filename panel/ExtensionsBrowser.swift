import SwiftUI

// What the browser knows: the published catalogue, what is installed, and what
// is currently happening to each of them.
//
// Owned by PanelController and handed to the view, exactly like PhrasesViewModel
// — the drill-down this copies. Every side effect is injected so the states can
// be driven in a test without a network.
final class ExtensionCatalog: ObservableObject {

    enum Load: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    // Per-extension, because one failing install must not make the others look
    // broken. Mirrors the shape of GithubSignIn, which is the precedent here.
    enum Work: Equatable {
        case installing
        case removing
        case failed(String)
    }

    @Published private(set) var load: Load = .idle
    @Published private(set) var entries: [ExtensionInstaller.IndexEntry] = []
    @Published private(set) var work: [String: Work] = [:]
    // Keyboard selection. The panel is keyboard-native and this page's own
    // footer advertises key hints, but every action on it was mouse-only.
    @Published var selectedID: String?
    // What the search field holds. Filtering happens at render time rather than
    // over `entries`, so a query never hides an *installed* extension from the
    // merge that produces the rows — it only hides it from this list.
    @Published var query = ""
    // Bumped to hand the field first-responder status, mirroring
    // PanelNav.historyFilterFocusRequests. The page deliberately opens with the
    // field *unfocused* so the key handler owns the keyboard; typing hands over.
    @Published private(set) var searchFocusRequests = 0

    func focusSearch() { searchFocusRequests += 1 }

    private let fetchCatalogue: () -> Result<[ExtensionInstaller.IndexEntry], ExtensionInstaller.Failure>
    private let performInstall: (ExtensionInstaller.IndexEntry) -> Result<String, ExtensionInstaller.Failure>
    private let performRemove: (String) -> Result<String, ExtensionInstaller.Failure>
    private let background: (@escaping () -> Void) -> Void
    private let toMain: (@escaping () -> Void) -> Void
    private let didChange: () -> Void

    init(fetchCatalogue: @escaping () -> Result<[ExtensionInstaller.IndexEntry], ExtensionInstaller.Failure>,
         performInstall: @escaping (ExtensionInstaller.IndexEntry) -> Result<String, ExtensionInstaller.Failure>
            = { ExtensionInstaller.install($0, from: .init(assets: [:], fetch: { _ in nil })) },
         performRemove: @escaping (String) -> Result<String, ExtensionInstaller.Failure>
            = { ExtensionInstaller.remove($0) },
         background: @escaping (@escaping () -> Void) -> Void
            = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         toMain: @escaping (@escaping () -> Void) -> Void
            = { DispatchQueue.main.async(execute: $0) },
         didChange: @escaping () -> Void = {}) {
        self.fetchCatalogue = fetchCatalogue
        self.performInstall = performInstall
        self.performRemove = performRemove
        self.background = background
        self.toMain = toMain
        self.didChange = didChange
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard load == .idle || load.isFailure else { return }
        reload()
    }

    func reload() {
        // Gated like install and remove are. This is what both "Try again" and
        // the R key call, and each ungated call blocks a pool thread inside the
        // fetch — key autorepeat alone was enough to starve the queue the
        // session poll and the quota probes share.
        guard load != .loading else { return }
        load = .loading
        background { [weak self] in
            guard let self else { return }
            let result = self.fetchCatalogue()
            self.toMain { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let entries):
                    self.entries = entries
                    self.load = .loaded
                case .failure(let failure):
                    self.load = .failed(failure.message)
                }
            }
        }
    }

    // MARK: - Installing and removing

    func install(_ entry: ExtensionInstaller.IndexEntry) {
        // A previous failure must not jam the button. The gate is on work *in
        // flight*, not on the row having ever failed — the buttons render
        // enabled in the failed state, so guarding on non-nil made the obvious
        // response to "install failed" a silent no-op.
        guard !isBusy(entry.id) else { return }
        work[entry.id] = .installing
        background { [weak self] in
            guard let self else { return }
            let result = self.performInstall(entry)
            self.toMain { [weak self] in self?.finish(entry.id, result) }
        }
    }

    func remove(_ id: String) {
        guard !isBusy(id) else { return }
        work[id] = .removing
        background { [weak self] in
            guard let self else { return }
            let result = self.performRemove(id)
            self.toMain { [weak self] in self?.finish(id, result) }
        }
    }

    // Visible for tests, which drive the states without a real install.
    func finish(_ id: String, _ result: Result<String, ExtensionInstaller.Failure>) {
        switch result {
        case .success:
            work[id] = nil
            // Re-discovery is what republishes the tab strip, so it has to
            // happen on the way out of both install and remove.
            didChange()
        case .failure(let failure):
            work[id] = .failed(failure.message)
        }
    }

    // In flight means installing or removing. A failed row is idle: it is
    // showing a reason, not doing anything.
    func isBusy(_ id: String) -> Bool {
        switch work[id] {
        case .installing, .removing: return true
        case .failed, nil:           return false
        }
    }

    func failure(for id: String) -> String? {
        if case .failed(let why) = work[id] { return why }
        return nil
    }

    // MARK: - Keyboard

    func moveSelection(among rows: [ExtensionRow], by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selectedID }
        // No selection yet: ↓ takes the first and ↑ the last, so either arrow
        // is a way in. Same rule as the extension tab's row list.
        let next = current.map { min(max($0 + delta, 0), rows.count - 1) }
            ?? (delta > 0 ? 0 : rows.count - 1)
        selectedID = rows[next].id
    }

    // What Enter does to the selected row: install it, or update it, or dismiss
    // the failure it is showing.
    //
    // Deliberately never removes. Removal is on the extension's own page now,
    // reached from Settings → Extensions — Enter on a list where most rows
    // install and one deletes is a keystroke whose meaning depends on where the
    // selection happens to be.
    func activateSelection(among rows: [ExtensionRow]) {
        guard let row = rows.first(where: { $0.id == selectedID }) else { return }
        if failure(for: row.id) != nil { return dismissFailure(for: row.id) }
        guard !isBusy(row.id), row.updateAvailable || !row.isInstalled,
              let entry = entries.first(where: { $0.id == row.id })
        else { return }
        install(entry)
    }

    // Keeps the selection on a row that still exists after a reload or a
    // removal, rather than pointing at nothing.
    func reconcileSelection(among rows: [ExtensionRow]) {
        guard let selectedID else { return }
        if !rows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
    }

    // Pure, so the matching rule is testable without a view.
    //
    // Matches the id as well as the name and description because the id is what
    // the config keys, the directory and the docs all use — somebody who knows
    // an extension as "derby" should not have to remember it is called "Token
    // Derby" to find it.
    static func matching(_ rows: [ExtensionRow], query: String) -> [ExtensionRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            [row.id, row.name, row.description].contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    func dismissFailure(for id: String) {
        if case .failed = work[id] { work[id] = nil }
    }
}

// One row per extension, however it got here. The browser used to render the
// catalogue, the refusals and the installed set as three independent lists,
// which meant a refused extension that was also published showed an orange
// "Remove" directly above a card offering "Install" — and an extension
// installed but absent from the index (a hand-placed one, or one withdrawn
// after publication) appeared in none of them while Settings still counted it.
struct ExtensionRow: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
    let installedVersion: String?
    let availableVersion: String?
    let refusedReason: String?
    let requires: [String]
    let config: [ExtensionManifest.ConfigKey]

    var isInstalled: Bool { installedVersion != nil || refusedReason != nil }

    // The environment keys, not their labels: this line is about what the
    // extension can read, and the key is the thing a reviewer recognises.
    var configKeyList: String { config.map(\.key).joined(separator: ", ") }

    // Only an installed extension has anywhere to put a value, and only one
    // that declared a key has anything to put there.
    var isConfigurable: Bool { isInstalled && !configurableKeys.isEmpty }

    // The keys a form may actually offer.
    //
    // Empty for a refused extension, whatever the index says it declares. A
    // refusal means its manifest did not parse, so the only key list available
    // is the catalogue's — and rendering fields from that writes values into
    // the user's config file for an extension that will never read them, under
    // labels its own manifest never agreed to.
    var configurableKeys: [ExtensionManifest.ConfigKey] {
        refusedReason == nil ? config : []
    }

    // Only when both are known and differ. An extension that is installed but
    // unpublished has nothing to update to, which is not the same as being
    // up to date.
    var updateAvailable: Bool {
        guard let installedVersion, let availableVersion else { return false }
        return installedVersion != availableVersion
    }
}

extension ExtensionCatalog {
    // Pure, so the merge is testable without a view.
    static func rows(catalogue: [ExtensionInstaller.IndexEntry],
                     installed: [ExtensionManifest],
                     refused: [ExtensionRuntime.Refusal]) -> [ExtensionRow] {
        let installedByID = Dictionary(installed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let refusedByID = Dictionary(refused.map { ($0.id, $0.reason) }, uniquingKeysWith: { a, _ in a })

        var rows: [ExtensionRow] = []
        var seen = Set<String>()

        for entry in catalogue where seen.insert(entry.id).inserted {
            rows.append(ExtensionRow(
                id: entry.id,
                name: entry.name,
                description: entry.description,
                installedVersion: installedByID[entry.id]?.version,
                availableVersion: entry.version,
                refusedReason: refusedByID[entry.id],
                requires: entry.requires,
                // The installed manifest wins when there is one: it is the
                // version that actually runs, and the form is for configuring
                // *it*. Taking the index's list instead would offer a field for
                // a key a newer release added and this install ignores.
                //
                // With nothing installed there is only the index, which carries
                // key names and no metadata — enough for the "Reads …" line,
                // which is all an uninstalled row shows. isConfigurable already
                // requires an install, so a label-less key never reaches a form.
                config: installedByID[entry.id]?.config
                    ?? entry.config.map { .init(key: $0, label: nil, help: nil, placeholder: nil) }))
        }
        // Installed but unpublished — still listed, so it can be seen and
        // removed rather than being invisible and permanent. In the browser
        // that is a hand-placed extension; in the Settings list (which passes
        // no catalogue) it is every installed extension.
        for manifest in installed where seen.insert(manifest.id).inserted {
            rows.append(ExtensionRow(
                id: manifest.id, name: manifest.name, description: "",
                installedVersion: manifest.version, availableVersion: nil,
                refusedReason: nil,
                requires: manifest.requires, config: manifest.config))
        }
        // A refusal has no manifest to read a name from, so the id is the name.
        for refusal in refused where seen.insert(refusal.id).inserted {
            rows.append(ExtensionRow(
                id: refusal.id, name: refusal.id, description: "",
                installedVersion: nil, availableVersion: nil,
                refusedReason: refusal.reason, requires: [], config: []))
        }
        // Refusals first — a refusal is what somebody opened this page to
        // understand — then installed, then the rest, each alphabetically.
        return rows.sorted { a, b in
            func rank(_ r: ExtensionRow) -> Int {
                if r.refusedReason != nil { return 0 }
                return r.isInstalled ? 1 : 2
            }
            return rank(a) == rank(b) ? a.id < b.id : rank(a) < rank(b)
        }
    }
}

extension ExtensionCatalog.Load {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - The view

struct ExtensionsView: View {

    @ObservedObject var catalog: ExtensionCatalog
    @ObservedObject var host: ExtensionHost
    let onConfigure: (ExtensionRow) -> Void
    let onBack: () -> Void

    // Focused on arrival, so the page is type-to-find rather than
    // click-then-type. It is why R lost its bare binding — see the key routing
    // in Panel.
    @FocusState private var searchFocused: Bool

    var body: some View {
        // Once per body pass. visibleRows is a merge of three lists plus a sort
        // and a filter, and it was read from the ScrollView, from .onChange's
        // value expression, from its closure and twice from the footer.
        let rows = visibleRows
        return VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    catalogueBody(rows)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // On the content, not on the ScrollView: ThinScrollers walks
                // superviews for the NSScrollView, and every other call site in
                // the tree attaches it this way.
                .background(ThinScrollers())
            }

            PageFooter {
                // Named for what Esc does from here, which depends on whether
                // there is a query to clear first.
                FooterHint(label: catalog.query.isEmpty ? "Back" : "Clear", keys: ["Esc"])
                FooterHint(label: "Search", keys: ["/"])
                FooterHint(label: "Select", keys: ["↑", "↓"])
                FooterHint(label: activationLabel(in: rows), keys: ["⏎"])
                // Only where Enter is busy doing something else. An installed
                // row with an update pending takes Enter for the update, so
                // without this there would be no keyboard route to its page.
                if selectedRow(in: rows)?.updateAvailable == true {
                    FooterHint(label: "Settings", keys: ["⌘⏎"])
                }
                // ⌘R rather than R: a plain letter seeds the search field, the
                // same trade the history pane makes.
                FooterHint(label: "Reload", keys: ["⌘R"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            catalog.loadIfNeeded()
            // Deliberately NOT focused. A focused field is first responder, and
            // FloatingPanel.keyDown only fires for what the first responder
            // declines — so focusing on arrival handed the field Esc, ↑↓ and ⏎
            // and left every hint in the footer describing a key that no longer
            // did anything. Same contract the history pane states at
            // Panel.swift:4042, reached the same way: typing hands over.
            searchFocused = false
        }
        .onChange(of: catalog.searchFocusRequests) { _ in searchFocused = true }
        // AppKit selects the field's whole contents when it becomes first
        // responder, which throws away the character that asked for focus:
        // type "de" and get "e". The history filter hands focus over the same
        // way and needs the same collapse — see FieldEditor for why this keys
        // off focus actually becoming true rather than a scheduled hop.
        .onChange(of: searchFocused) { focused in
            if focused { FieldEditor.collapseSelectionToEnd() }
        }
        // The selection has to survive the list changing under it, and it was
        // never reconciled from anywhere — the method existed and only the
        // tests called it. Searching made that visible: a query that filters
        // out the selected row leaves selectedID pointing at something not on
        // screen, and Enter then does nothing at all rather than acting on
        // whatever is in front of you.
        .onChange(of: rows.map(\.id)) { _ in
            catalog.reconcileSelection(among: rows)
        }
    }

    private func selectedRow(in rows: [ExtensionRow]) -> ExtensionRow? {
        guard let id = catalog.selectedID else { return nil }
        return rows.first { $0.id == id }
    }

    // Named for what Enter will actually do to the selected row, rather than a
    // generic verb that is wrong two thirds of the time.
    private func activationLabel(in rows: [ExtensionRow]) -> String {
        guard let row = selectedRow(in: rows) else { return "Select" }
        if catalog.failure(for: row.id) != nil { return "Dismiss" }
        if row.updateAvailable { return "Update" }
        // Named for what Enter does, which on an installed row is open its
        // page — the same thing the card's button does. It used to say
        // "Installed", which is a state rather than an action, on a row where
        // Enter did nothing at all.
        return row.isInstalled ? "Settings" : "Install"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption2).foregroundStyle(.tertiary)
            TextField("Search extensions", text: $catalog.query)
                .textFieldStyle(.plain)
                .font(.caption)
                .focused($searchFocused)
                // Once the field *is* first responder it consumes keys before
                // NSWindow.keyDown, so Esc and Enter have to be handled here or
                // not at all. Esc clears the query, then steps out of the field
                // — the same two-step the history filter uses; Enter releases
                // focus so ↑↓ and ⏎ go back to acting on the list.
                .onExitCommand {
                    if catalog.query.isEmpty { searchFocused = false } else { catalog.query = "" }
                }
                .onSubmit { searchFocused = false }
            if !catalog.query.isEmpty {
                Button { catalog.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    var visibleRows: [ExtensionRow] {
        ExtensionCatalog.matching(
            ExtensionCatalog.rows(catalogue: catalog.entries,
                                  installed: host.manifests,
                                  refused: host.refused),
            query: catalog.query)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text("Settings").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text("Extensions").font(.subheadline.weight(.medium)).padding(.leading, 6)
            Spacer()
            if catalog.load == .loading {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func catalogueBody(_ rows: [ExtensionRow]) -> some View {
        switch catalog.load {
        // A failed *catalogue* fetch does not hide what is installed — those
        // rows are read from disk and are still true, and one of them may be
        // the refusal somebody came here to remove.
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(why).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    cardButton("Try again", prominent: true) { catalog.reload() }
                }
                ForEach(rows) { row in extensionRow(row) }
            }
        case .idle, .loading where rows.isEmpty:
            // Only when there is nothing to show. Reloading a populated
            // catalogue used to replace the whole list with this, while the
            // header spinner — which is the actual reload indicator — was
            // already saying the same thing.
            note("Looking for extensions…")
        default:
            if rows.isEmpty {
                // Distinguished, because "nothing is published" and "nothing
                // matches what you typed" want very different next actions.
                note(catalog.query.isEmpty
                     ? "No extensions are published yet."
                     : "Nothing matches \"\(catalog.query)\".")
            } else {
                ForEach(rows) { row in extensionRow(row) }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Rows

    private func extensionRow(_ row: ExtensionRow) -> some View {
        let failure = catalog.failure(for: row.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: glyph(for: row))
                    .font(.system(size: 14))
                    .foregroundStyle(tint(for: row))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                        if let version = row.installedVersion ?? row.availableVersion {
                            Text(version).font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    if let reason = row.refusedReason {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !row.description.isEmpty {
                        Text(row.description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if row.isInstalled && row.availableVersion == nil && row.refusedReason == nil {
                        Text("Installed directly — not in the catalogue")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    // What it will be able to read, before it is installed
                    // rather than after. The namespace is narrow by design, but
                    // narrow is not the same as nothing.
                    if !row.config.isEmpty {
                        Text("Reads \(row.configKeyList)")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    if !row.requires.isEmpty {
                        Text("Needs \(row.requires.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                actionArea(row)
            }
            if let failure {
                HStack(spacing: 6) {
                    Text(failure).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    cardButton("Dismiss") { catalog.dismissFailure(for: row.id) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(row.refusedReason == nil
                  ? Color.primary.opacity(catalog.selectedID == row.id ? 0.12 : 0.05)
                  : Color.orange.opacity(catalog.selectedID == row.id ? 0.16 : 0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(catalog.selectedID == row.id ? 0.6 : 0),
                          lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { catalog.selectedID = row.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(catalog.selectedID == row.id ? [.isSelected] : [])
    }

    private func glyph(for row: ExtensionRow) -> String {
        if row.refusedReason != nil { return "exclamationmark.triangle.fill" }
        return row.isInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension"
    }

    private func tint(for row: ExtensionRow) -> Color {
        if row.refusedReason != nil { return .orange }
        return row.isInstalled ? .green : .secondary
    }

    // Every state routes through here, including a refused row — which
    // previously rendered a bare Remove with no spinner and no way to see that
    // the removal had failed.
    @ViewBuilder
    private func actionArea(_ row: ExtensionRow) -> some View {
        if catalog.isBusy(row.id) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                if row.updateAvailable, let entry = entry(for: row.id) {
                    cardButton("Update", prominent: true) { catalog.install(entry) }
                }
                // Settings is where an installed extension is configured and
                // removed; this page is for finding ones you don't have. An
                // installed row says so and offers the way there rather than
                // duplicating the controls.
                if row.isInstalled {
                    cardButton("Settings") { onConfigure(row) }
                } else if let entry = entry(for: row.id) {
                    cardButton("Install", prominent: true) { catalog.install(entry) }
                }
            }
        }
    }

    private func entry(for id: String) -> ExtensionInstaller.IndexEntry? {
        catalog.entries.first { $0.id == id }
    }

    private func cardButton(_ title: String, prominent: Bool = false,
                            action: @escaping () -> Void) -> some View {
        CardButton(title: title, prominent: prominent, action: action)
    }
}

// The button on an extension card. Its own type rather than a method, because
// the per-extension config page needs the same one and two copies of a button
// style is how two pages in one panel start looking like two apps.
struct CardButton: View {

    let title: String
    var prominent = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08)))
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
