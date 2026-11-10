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
    // already (← and ⌘R) and neither had a ring, so the page looked half
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
    @Published var selection: Target? {
        // Moving off a row withdraws a confirmation it was waiting for.
        didSet { if selection != oldValue { confirming = nil } }
    }

    // An install waiting to be confirmed: one above the `view` tier asks
    // first, saying what that tier lets it do, and the same ⏎ (or the
    // button, now reading Confirm) again installs it.
    @Published private(set) var confirming: String?

    // Requirements the catalogue's entries need that this Mac lacks, by
    // extension. Probed once per name in the background when the catalogue
    // lands, since a probe runs the interpreter; a row only says "Needs X"
    // when X is in here.
    @Published private(set) var missingRequirements: [String: [String]] = [:]

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
    private let didLoadCatalogue: () -> Void
    private let probeRequirement: (String) -> Bool
    private let recordedTiers: () -> [String: ExtensionTier]

    init(fetchCatalogue: @escaping () -> Result<[ExtensionInstaller.IndexEntry], ExtensionInstaller.Failure>,
         performInstall: @escaping (ExtensionInstaller.IndexEntry) -> Result<String, ExtensionInstaller.Failure>
            = { ExtensionInstaller.install($0, from: .init(assets: [:], fetch: { _ in nil })) },
         performRemove: @escaping (String) -> Result<String, ExtensionInstaller.Failure>
            = { ExtensionInstaller.remove($0) },
         background: @escaping (@escaping () -> Void) -> Void
            = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         toMain: @escaping (@escaping () -> Void) -> Void
            = { DispatchQueue.main.async(execute: $0) },
         didChange: @escaping () -> Void = {},
         didLoadCatalogue: @escaping () -> Void = {},
         probeRequirement: @escaping (String) -> Bool = ExtensionInstaller.interpreterWorks,
         recordedTiers: @escaping () -> [String: ExtensionTier] = { ExtensionTiers.read() }) {
        self.probeRequirement = probeRequirement
        self.recordedTiers = recordedTiers
        self.fetchCatalogue = fetchCatalogue
        self.performInstall = performInstall
        self.performRemove = performRemove
        self.background = background
        self.toMain = toMain
        self.didChange = didChange
        self.didLoadCatalogue = didLoadCatalogue
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
        cancelConfirmation()
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
                    self.probeRequirements(of: entries)
                    // An installed row has nothing to compare its version
                    // against until this lands, so whoever merged the two
                    // lists needs telling to do it again.
                    self.didLoadCatalogue()
                case .failure(let failure):
                    self.load = .failed(failure.message)
                }
            }
        }
    }

    private func probeRequirements(of entries: [ExtensionInstaller.IndexEntry]) {
        let names = Set(entries.flatMap(\.requires))
        guard !names.isEmpty else { missingRequirements = [:]; return }
        let probe = probeRequirement
        background { [weak self] in
            let missing = Set(names.filter { !probe($0) })
            self?.toMain { [weak self] in
                self?.missingRequirements = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                    let lacking = entry.requires.filter(missing.contains)
                    return lacking.isEmpty ? nil : (entry.id, lacking)
                })
            }
        }
    }

    // MARK: - Installing and removing

    // Whether installing or updating this entry asks first: when the index
    // gives it a tier above `view` and above what this Mac has recorded for
    // it. A fresh install has nothing recorded, so anything above `view`
    // asks; an update that keeps or lowers the tier doesn't, and one that
    // raises it does, since it's being given more than was agreed to.
    static func needsConfirmation(_ entry: ExtensionInstaller.IndexEntry,
                                  recorded: ExtensionTier?) -> Bool {
        entry.reviewedTier > .view && entry.reviewedTier > (recorded ?? .view)
    }

    // What the confirmation says: what this extension asks for that its tier
    // would grant, in plain words, and never anything it didn't ask for. An
    // index from before entries carried capabilities can't say, so it says
    // only that the extension gets more than a tab would.
    static func confirmationText(for entry: ExtensionInstaller.IndexEntry, updating: Bool = false) -> String {
        let tier = entry.reviewedTier
        guard tier > .view else { return "" }
        let again = updating ? " \u{23CE} again to update." : " \u{23CE} again to install."
        guard let asked = entry.requestedCapabilities else {
            return "Runs in the background with more access than a tab." + again
        }
        let granted = asked.filter(tier.allows)
        guard !granted.isEmpty else { return "Runs in the background." + again }
        return "Runs in the background. Asks for: "
            + granted.map(\.askingWords).joined(separator: ", ") + "." + again
    }

    // Every install and update goes through here: the browser's ⏎ and its
    // buttons, and the Update row on an extension's page. Straight away when
    // no confirmation is needed, otherwise on the second request for the
    // same extension.
    func requestInstall(_ entry: ExtensionInstaller.IndexEntry) {
        if Self.needsConfirmation(entry, recorded: recordedTiers()[entry.id]), confirming != entry.id {
            confirming = entry.id
            return
        }
        confirming = nil
        install(entry)
    }

    // Leaving the page, hiding the panel, reloading, or the list changing
    // under the selection all drop a pending confirmation.
    func cancelConfirmation() {
        if confirming != nil { confirming = nil }
    }

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
        requestInstall(entry)
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
        cancelConfirmation()
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

    // The rows Settings lists, merged against the catalogue this object holds.
    //
    // Here rather than at the call site because *which catalogue* is the thing
    // that went wrong: the controller passed an empty one, so every installed
    // row came back with no availableVersion, nothing was ever an update, and
    // the count on the Settings row was permanently zero. PanelController is
    // not reachable from a test, so that decision could not be asserted while
    // it lived there — it can here.
    //
    // Installed and refused only. The merge also yields every published
    // extension, which is the browser's list, not this one: Settings showed
    // Token Derby, Pylon and System on a Mac that had only Away.
    func settingsRows(installed: [ExtensionManifest],
                      refused: [ExtensionRuntime.Refusal]) -> [ExtensionRow] {
        Self.rows(catalogue: entries, installed: installed, refused: refused).filter(\.isInstalled)
    }

    // The Browse row's trailing text: how many published extensions aren't
    // installed, and how many installed ones have an update. Nothing until
    // the catalogue has loaded, since a count of what hasn't been fetched
    // would be a guess.
    static func browseRowValue(load: Load, catalogue: [ExtensionInstaller.IndexEntry],
                               installed: [ExtensionRow]) -> String {
        switch load {
        case .idle, .loading: return ""
        case .failed:         return "Couldn't load"
        case .loaded:         break
        }
        let installedIDs = Set(installed.map(\.id))
        let available = catalogue.filter { !installedIDs.contains($0.id) }.count
        let updates = installed.filter(\.updateAvailable).count
        var parts = [available == 0 ? "None available" : "\(available) available"]
        if updates > 0 { parts.append("\(updates) update\(updates == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // The browser's list: everything published plus anything installed,
    // ranked so what's worth acting on comes first. With no query it stops at
    // `browseLimit` and says how many more a search would find; a query shows
    // every match.
    static let browseLimit = 10

    static func browseRows(_ rows: [ExtensionRow], query: String) -> (shown: [ExtensionRow], more: Int) {
        func rank(_ row: ExtensionRow) -> Int {
            if row.updateAvailable { return 0 }
            return row.isInstalled ? 2 : 1
        }
        let ranked = matching(rows, query: query).sorted { a, b in
            rank(a) == rank(b)
                ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                : rank(a) < rank(b)
        }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ranked.count > browseLimit else { return (ranked, 0) }
        return (Array(ranked.prefix(browseLimit)), ranked.count - browseLimit)
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
            // The installed manifest's description when there is one: it is
            // what's on disk, and an extension the index describes differently
            // (or not at all) is still the one installed.
            let installedDescription = installedByID[entry.id]?.description ?? ""
            rows.append(ExtensionRow(
                id: entry.id,
                name: entry.name,
                description: installedDescription.isEmpty ? entry.description : installedDescription,
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
                id: manifest.id, name: manifest.name, description: manifest.description,
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

    // Typing focuses it, so the page is type-to-find rather than
    // click-then-type. It is why R lost its bare binding — see the key routing
    // in Panel. Not focused on arrival: see onAppear.
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
                    VStack(alignment: .leading, spacing: 2) {
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
                    // The last row brings the "N more" line with it, so the
                    // end of the list says where the rest are.
                    let last = rows.last.map { ExtensionCatalog.Target.row($0.id) } == target && browse.more > 0
                    withAnimation(.easeOut(duration: 0.15)) {
                        if last { proxy.scrollTo(Self.moreAnchor, anchor: .bottom) }
                        else { proxy.scrollTo(anchor, anchor: nil) }
                    }
                }
            }

            PageFooter {
                let hints = Self.footerHints(
                    selection: catalog.selection,
                    activation: activationLabel(in: rows),
                    updateSelected: selectedRow(in: rows)?.updateAvailable == true,
                    hasRows: !rows.isEmpty,
                    searching: searchFocused)
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
            // declines — so focusing on arrival handed the field ←, ↑↓ and ⏎
            // and left every hint in the footer describing a key that no longer
            // did anything. Same contract the history pane states in
            // panelHandlesKey, reached the same way: typing hands over.
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
        // And on the query itself, which is what filters the list as you type.
        .onChange(of: catalog.query) { _ in
            catalog.reconcileSelection(among: visibleRows)
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
                            hasRows: Bool,
                            searching: Bool = false) -> [FooterHintSpec] {
        var hints: [FooterHintSpec] = []
        // ⏎ joins ← when the chevron is selected, since both then leave.
        // Dimmed while the search field has focus, where ← moves the caret.
        let backSelected = selection == .back
        hints.append(FooterHintSpec(
            label: "Back",
            keys: backSelected ? ["⏎", "←"] : ["←"],
            primary: backSelected,
            dimmed: searching))
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
    static let moreAnchor = "extensions-more"

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
        if catalog.confirming == row.id { return "Confirm" }
        return row.isInstalled ? "Open" : "Install"
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
                // NSWindow.keyDown, so Enter has to be handled here or not at
                // all. It releases focus so ↑↓ and ⏎ go back to acting on the
                // list.
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

    var visibleRows: [ExtensionRow] { browse.shown }

    private var browse: (shown: [ExtensionRow], more: Int) {
        ExtensionCatalog.browseRows(
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

            Text("Browse extensions").font(.subheadline.weight(.medium)).padding(.leading, 6)
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
        let more = browse.more
        switch catalog.load {
        // A failed *catalogue* fetch does not hide what is installed — those
        // rows are read from disk and are still true.
        case .failed(let why):
            HStack(spacing: 6) {
                Text(why).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                cardButton("Try again", prominent: true,
                           selected: catalog.selection == .retry) { catalog.reload() }
                    .id(Self.retryAnchor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            ForEach(rows) { row in extensionRow(row) }
        // Only when there is nothing to show; a reload of a populated list
        // keeps it, and the header spinner says it's working.
        case .idle where rows.isEmpty, .loading where rows.isEmpty:
            note("Looking for extensions…")
        default:
            if rows.isEmpty {
                // Distinguished, because "nothing is published" and "nothing
                // matches what you typed" want very different next actions.
                note(catalog.query.isEmpty
                     ? "No extensions are published yet."
                     : "No extensions match \u{201C}\(catalog.query)\u{201D}.")
            } else {
                ForEach(rows) { row in extensionRow(row) }
                if more > 0 {
                    // Not a row: nothing to select, just where the rest are.
                    note("\(more) more \u{2014} type to search")
                        .padding(.top, 4)
                        .id(Self.moreAnchor)
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
    }

    // MARK: - Rows

    // One line per extension, the same shape as the installed list in
    // Settings: icon, name, a one-line description (the whole of it in the
    // tooltip), and on the right what ⏎ does or why it can't. A pill only
    // where there is something to press; "Installed" is a state, and ⏎ on it
    // opens the extension's page, as the chevron says.
    private func extensionRow(_ row: ExtensionRow) -> some View {
        let failure = catalog.failure(for: row.id)
        let selected = catalog.selectedID == row.id
        let confirming = catalog.confirming == row.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: glyph(for: row))
                    .font(.system(size: 13))
                    .foregroundStyle(tint(for: row))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.subheadline).lineLimit(1)
                    let line = row.refusedReason ?? row.description
                    if !line.isEmpty {
                        Text(line).font(.caption)
                            .foregroundStyle(row.refusedReason == nil ? Color.secondary : Color.orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(line)
                    }
                }
                Spacer(minLength: 8)
                status(row)
            }
            if confirming, let entry = entry(for: row.id) {
                Text(ExtensionCatalog.confirmationText(for: entry, updating: row.isInstalled))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            if let failure {
                HStack(spacing: 6) {
                    Text(failure).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    cardButton("Dismiss") { catalog.dismissFailure(for: row.id) }
                }
                .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The Settings selection, exactly: an accent fill, no ring.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 0.22 : 0)))
        .contentShape(Rectangle())
        .onTapGesture {
            catalog.selection = .row(row.id)
            if row.isInstalled, !row.updateAvailable { onConfigure(row) }
        }
        .id(row.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func glyph(for row: ExtensionRow) -> String {
        if row.refusedReason != nil { return "exclamationmark.triangle.fill" }
        return row.isInstalled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension"
    }

    private func tint(for row: ExtensionRow) -> Color {
        if row.refusedReason != nil { return .orange }
        return row.isInstalled ? .green : .secondary
    }

    // The right-hand column. Fixed width, so the column lines up row to row.
    //
    // The pill is the accent one only on the selected row, the one ⏎ acts
    // on; elsewhere it's the quiet one, the same size, so a list of ten isn't
    // ten blue buttons and nothing moves as the selection does.
    @ViewBuilder
    private func status(_ row: ExtensionRow) -> some View {
        let prominent = catalog.selectedID == row.id
        Group {
            if catalog.isBusy(row.id) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text(catalog.work[row.id] == .removing ? "Removing…" : "Installing…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if row.updateAvailable, let entry = entry(for: row.id) {
                cardButton(catalog.confirming == row.id ? "Confirm" : "Update \(row.availableVersion ?? "")",
                           prominent: prominent) {
                    catalog.selection = .row(row.id)
                    catalog.requestInstall(entry)
                }
            } else if row.isInstalled {
                HStack(spacing: 6) {
                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
            } else if let missing = catalog.missingRequirements[row.id], !missing.isEmpty {
                Text("Needs \(missing.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            } else if let entry = entry(for: row.id) {
                cardButton(catalog.confirming == row.id ? "Confirm" : "Install", prominent: prominent) {
                    catalog.selection = .row(row.id)
                    catalog.requestInstall(entry)
                }
            }
        }
        .frame(minWidth: 96, alignment: .trailing)
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
