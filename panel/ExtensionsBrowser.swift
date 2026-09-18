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
    // Everything on the page the keyboard can land on, in the order it is drawn.
    // Not just the rows: the page has a back chevron above them and, when the
    // catalogue fetch failed, a Try again beside the reason. Both had a key
    // already (Esc and ⌘R) and neither had a ring, so the page looked half
    // wired next to an extension's own, which walks its buttons.
    //
    // The search field is deliberately not a target. Every other control here
    // needs ⏎ to reach it; the field is reached by typing, which is what the
    // page does with any printable key, and a ring you step onto to start
    // typing would be a second way to do the thing that already needs none.
    enum Target: Equatable {
        case back
        case retry
        case row(String)
    }

    // Keyboard selection. The panel is keyboard-native and this page's own
    // footer advertises key hints, but every action on it was mouse-only.
    @Published var selection: Target?

    // The row the selection is on, if it is on one. Most of the page cares only
    // about this, and a card highlighting itself should not have to know the
    // chevron exists.
    var selectedID: String? {
        if case .row(let id) = selection { return id }
        return nil
    }
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

    // Drawing order, which is also the order ↑↓ walk. Try again exists only
    // while the fetch has failed, because that is the only time the button is
    // drawn; back is always there, so the list is never empty even on a
    // catalogue with nothing in it.
    func targets(among rows: [ExtensionRow]) -> [Target] {
        [.back] + (load.isFailure ? [.retry] : []) + rows.map { Target.row($0.id) }
    }

    func moveSelection(among rows: [ExtensionRow], by delta: Int) {
        let all = targets(among: rows)
        let current = all.firstIndex { $0 == selection }
        // No selection yet: ↓ takes the first and ↑ the last, so either arrow
        // is a way in. Same rule as the extension tab's row list.
        let next = current.map { min(max($0 + delta, 0), all.count - 1) }
            ?? (delta > 0 ? 0 : all.count - 1)
        selection = all[next]
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

    // ⌘↑↓, which every other list page in the panel answers.
    func selectEdge(among rows: [ExtensionRow], top: Bool) {
        let all = targets(among: rows)
        selection = top ? all.first : all.last
    }

    // Keeps the selection on a row that still exists after a reload, a removal
    // or a query, and puts it on the first row when there is nothing valid to
    // keep. Dropping to nil was half the job: it left the page with a footer
    // advertising ⏎ against no selection, which is also how it opened: the
    // catalogue arrives after the view does, so there was nothing to select at
    // onAppear and nothing selected it afterwards either.
    //
    // Row order is what makes seeding safe to do unprompted: refusals sort
    // first, then what is installed, and only then what is merely published. On
    // any machine with an extension on it ⏎ lands on a page, not an install.
    func reconcileSelection(among rows: [ExtensionRow]) {
        let all = targets(among: rows)
        if let selection, all.contains(selection) { return }
        // A row first where there is one, so ⏎ on arrival acts on the list
        // rather than walking straight back out of the page. Then Try again,
        // which is what somebody reading "couldn't download" wants ⏎ to do.
        // The chevron last, for an empty catalogue that loaded fine: there is
        // genuinely nothing else on the page.
        selection = all.first(where: { if case .row = $0 { return true } else { return false } })
            ?? all.first(where: { $0 == .retry })
            ?? all.first
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
            ScrollViewReader { proxy in
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
                // Nearest-edge, matching the Settings detail pane. Cards here
                // carry a description, a "Reads …" line and a "Needs …" line,
                // so about two of them fit at the panel's 260pt minimum, and
                // without this ↑↓ moved a highlight straight off the bottom of
                // a catalogue of any size, which is the whole page.
                .onChange(of: catalog.selection) { target in
                    guard let anchor = Self.anchor(for: target) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(anchor, anchor: nil)
                    }
                }
            }

            PageFooter {
                let hints = Self.footerHints(
                    selection: catalog.selection,
                    activation: activationLabel(in: rows),
                    updateSelected: selectedRow(in: rows)?.updateAvailable == true,
                    queryIsEmpty: catalog.query.isEmpty,
                    hasRows: !rows.isEmpty)
                ForEach(hints.indices, id: \.self) { FooterHintRow(spec: hints[$0]) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            catalog.loadIfNeeded()
            // Whatever is already on disk. The catalogue lands later and the
            // onChange below seeds again from it, but an installed or refused
            // extension is selectable from the first frame.
            catalog.reconcileSelection(among: rows)
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

    // The bar as data, so it can be asserted rather than read.
    //
    // One hint per action, with ⏎ added to whichever the ring is on. A
    // separate hint naming the selected target prints the bar's own labels
    // twice the moment the selection reaches the chevron, which is what the
    // extension config page ran into.
    static func footerHints(selection: ExtensionCatalog.Target?,
                            activation: String,
                            updateSelected: Bool,
                            queryIsEmpty: Bool,
                            hasRows: Bool) -> [FooterHintSpec] {
        var hints: [FooterHintSpec] = []
        // Named for what Esc does from here, which depends on whether there is a
        // query to clear first. ⏎ joins it only when the chevron is selected
        // *and* Esc would leave rather than clear, or the one key would be
        // advertised for two different things.
        let backSelected = selection == .back
        let escapeLeaves = queryIsEmpty
        hints.append(FooterHintSpec(
            label: escapeLeaves ? "Back" : "Clear",
            keys: backSelected && escapeLeaves ? ["⏎", "Esc"] : ["Esc"],
            primary: backSelected && escapeLeaves))
        hints.append(FooterHintSpec(label: "Search", keys: ["/"]))
        // Dimmed rather than dropped when a query, or an empty catalogue, leaves
        // nothing to walk: the bar must not reflow as the list filters, and an
        // advertised key that does nothing is the thing this page kept doing.
        // Same treatment the Settings footer gives its Cycle hint.
        hints.append(FooterHintSpec(label: "Select", keys: ["↑↓", "⌘↑↓"],
                                    dimmed: !hasRows))
        // Only while the ring is on a row. On the chevron or Try again, ⏎
        // belongs to those, and the row verb would name something it will not do.
        if case .row = selection {
            hints.append(FooterHintSpec(label: activation, keys: ["⏎"], primary: true))
            // Only where Enter is busy doing something else. An installed row
            // with an update pending takes Enter for the update, so without this
            // there would be no keyboard route to its page.
            if updateSelected {
                hints.append(FooterHintSpec(label: "Settings", keys: ["⌘⏎"]))
            }
        }
        // ⌘R rather than R: a plain letter seeds the search field, the same
        // trade the history pane makes. Try again and Reload are one action, so
        // selecting the button adds ⏎ here rather than printing a second hint.
        let retrySelected = selection == .retry
        hints.append(FooterHintSpec(label: "Reload",
                                    keys: retrySelected ? ["⏎", "⌘R"] : ["⌘R"],
                                    primary: retrySelected))
        return hints
    }

    // The back chevron sits above the scroller and needs no anchor; scrolling to
    // the top of the list is what brings it into view.
    static let retryAnchor = "extensions-retry"

    static func anchor(for target: ExtensionCatalog.Target?) -> String? {
        switch target {
        case .row(let id):   return id
        case .retry:         return retryAnchor
        case .back, nil:     return nil
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
        let selected = catalog.selection == .back
        return HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text("Settings").font(.caption)
                }
                .foregroundStyle(selected ? Color.primary : .secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(selected ? 0.18 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
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
                    cardButton("Try again", prominent: true,
                               selected: catalog.selection == .retry) { catalog.reload() }
                        .id(Self.retryAnchor)
                }
                ForEach(rows) { row in extensionRow(row) }
            }
        // A where clause binds to the pattern it follows, not to the list, so
        // this read as ".idle, or .loading with nothing to show"; and .idle is
        // the state the first frame renders in, before onAppear has started the
        // fetch. An extension already on disk was hidden behind "Looking for
        // extensions…" for that frame.
        case .idle where rows.isEmpty, .loading where rows.isEmpty:
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
        .onTapGesture { catalog.selection = .row(row.id) }
        // The scroll anchor, keyed by what the selection is keyed by.
        .id(row.id)
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
                            selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        CardButton(title: title, prominent: prominent, selected: selected, action: action)
    }
}

// The button on an extension card. Its own type rather than a method, because
// the per-extension config page needs the same one and two copies of a button
// style is how two pages in one panel start looking like two apps.
struct CardButton: View {

    let title: String
    var prominent = false
    var enabled = true
    // Where the keyboard is, on a page whose ↑↓ walk the buttons as well as the
    // fields. A ring rather than a deeper fill: the prominent variant is already
    // accent-filled and cannot deepen its own fill legibly, which is the same
    // reason the Settings "Set up" banner button rings instead.
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(prominent ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(selected ? 0.7 : 0), lineWidth: 2))
                .foregroundStyle(prominent ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}
