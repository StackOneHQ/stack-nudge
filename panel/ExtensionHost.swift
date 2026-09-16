import Foundation

// Per-extension pane state, and the one place that decides when to spawn.
// Separate from PanelNav because nav is already large and this is genuinely its
// own concern: nav owns which tab you're looking at, this owns what's in it.
//
// Main-thread only, like the rest of the view models here — the spawn is the
// one thing that isn't, and it hops back before touching any of this.
final class ExtensionHost: ObservableObject {

    // Why a pane looks the way it does. `stale` and `broken` differ in whether
    // there is anything left to show: a transient failure with a document in
    // hand keeps the document and marks it old, while the same failure on a
    // cold pane has nothing to fall back to and has to say so plainly.
    enum Status: Equatable {
        case idle
        case loading
        case stale(String)
        case broken(String)

        var message: String? {
            switch self {
            case .idle, .loading:                    return nil
            case .stale(let why), .broken(let why):  return why
            }
        }
    }

    struct Pane: Equatable {
        var document: ExtensionDocument?
        var status: Status = .idle
        // When the last fetch *succeeded*, and when one was last *tried*. They
        // have to be separate: scheduling off updatedAt alone meant a failing
        // extension was permanently overdue, so a 30s interval collapsed to the
        // 5s ticker cadence and stayed there — 18 spawns in 120s, forever.
        var updatedAt: Date?
        var attemptedAt: Date?
        // Survives a refresh by id rather than index, so a row that moves up
        // the list stays selected and a row that disappears deselects instead
        // of silently pointing at whatever took its place.
        var selectedRow: String?
        // One invocation in flight per extension. Two concurrent spawns of the
        // same script would race to publish, and the loser's document would
        // overwrite the winner's for no reason anyone could see.
        var busy = false
    }

    @Published private(set) var panes: [String: Pane] = [:]
    @Published private(set) var manifests: [ExtensionManifest] = []
    // Directories that looked like extensions and weren't loadable. Surfaced
    // rather than dropped — see ExtensionRuntime.Discovery.
    @Published private(set) var refused: [ExtensionRuntime.Refusal] = []

    private let runner: (ExtensionManifest, String?, String?) -> ExtensionRuntime.Fetch
    private let onTabsChanged: ([ExtensionTab]) -> Void
    private let background: (@escaping () -> Void) -> Void
    private let toMain: (@escaping () -> Void) -> Void

    // `runner` is injected so the store can be driven with canned outcomes in
    // tests; the default spawns for real. It is called on a background queue,
    // so it takes and returns values rather than touching this object.
    //
    // The two hops are injected for the same reason RefreshGate injects its
    // timer: run them inline and the whole invocation becomes synchronous, so a
    // test can assert on the in-flight gate rather than on a race with it.
    init(onTabsChanged: @escaping ([ExtensionTab]) -> Void = { _ in },
         background: @escaping (@escaping () -> Void) -> Void
             = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         toMain: @escaping (@escaping () -> Void) -> Void
             = { DispatchQueue.main.async(execute: $0) },
         runner: @escaping (ExtensionManifest, String?, String?) -> ExtensionRuntime.Fetch
             = { ExtensionRuntime.fetch($0, action: $1, row: $2) }) {
        self.onTabsChanged = onTabsChanged
        self.background = background
        self.toMain = toMain
        self.runner = runner
    }

    func pane(_ id: String) -> Pane { panes[id] ?? Pane() }

    func manifest(_ id: String) -> ExtensionManifest? { manifests.first { $0.id == id } }

    // MARK: - Discovery

    func load(_ discovery: ExtensionRuntime.Discovery? = nil) {
        let found = discovery ?? ExtensionRuntime.discover()
        manifests = found.installed
        refused = found.refused
        // Reported to stderr as well as published. The Settings browser that
        // will render these properly arrives with distribution; until then a
        // refusal that only lives in a @Published nobody reads is the same
        // silence this was meant to end.
        for refusal in found.refused {
            FileHandle.standardError.write(Data(
                "stack-nudge: extension \"\(refusal.id)\" not loaded — \(refusal.reason)\n".utf8))
        }
        // Drop state for anything no longer installed, so reinstalling an
        // extension doesn't resurrect the document from its previous life.
        let live = Set(manifests.map(\.id))
        panes = panes.filter { live.contains($0.key) }
        onTabsChanged(manifests.map(\.tabEntry))
    }

    // MARK: - Invocation

    // Opening a tab refreshes it unless the manifest opted out, and unless
    // something is already in flight.
    func tabAppeared(_ id: String) {
        guard let manifest = manifest(id), manifest.refresh.onOpen else { return }
        refresh(id)
    }

    func refresh(_ id: String) { invoke(id, action: nil, row: nil) }

    // A press while busy is ignored rather than queued: the user pressed it
    // because nothing visible happened yet, and queueing would run it twice.
    func perform(action: String, row: String?, on id: String) {
        invoke(id, action: action, row: row)
    }

    // MARK: - Scheduled refresh

    // Whether a scheduled refresh is owed. `whileFocusedOnly` exists because
    // the only thing these panes are useful for is being looked at: an
    // extension that polls a remote service every 30s while the panel is hidden
    // is spending someone's battery and someone's rate limit to update a view
    // nobody can see.
    static func isDue(_ manifest: ExtensionManifest,
                      pane: Pane,
                      visible: Bool,
                      now: Date) -> Bool {
        guard let interval = manifest.refresh.intervalSeconds, interval > 0 else { return false }
        guard !pane.busy else { return false }
        if manifest.refresh.whileFocusedOnly && !visible { return false }
        // No fetch yet at all: onOpen (or the user) owns the first one, so the
        // interval doesn't start until something has been tried.
        guard let attemptedAt = pane.attemptedAt else { return false }
        // Measured from the last *attempt*, not the last success — otherwise a
        // broken extension is overdue on every tick and polls at the ticker's
        // cadence instead of its own.
        return now.timeIntervalSince(attemptedAt) >= TimeInterval(interval)
    }

    func tick(visibleTab: String?, now: Date = Date()) {
        for manifest in manifests
        where Self.isDue(manifest, pane: pane(manifest.id),
                         visible: visibleTab == manifest.id, now: now) {
            refresh(manifest.id)
        }
    }

    // MARK: - Selection and keys

    func selectRow(_ row: String?, on id: String) {
        var pane = self.pane(id)
        pane.selectedRow = row
        panes[id] = pane
    }

    func moveSelection(on id: String, by delta: Int) {
        let rows = pane(id).document?.rows ?? []
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == pane(id).selectedRow }
        // No selection yet: ↓ takes the first row and ↑ the last, so either
        // arrow is a way in rather than one of them doing nothing.
        let next = current.map { min(max($0 + delta, 0), rows.count - 1) }
            ?? (delta > 0 ? 0 : rows.count - 1)
        selectRow(rows[next].id, on: id)
    }

    // The selected row's binding wins over the document's, so a row-level "o"
    // can mean "open this one" while the same letter at document level means
    // something global. Nothing is resolved while an invocation is in flight.
    static func resolve(key: String,
                        in document: ExtensionDocument,
                        selectedRow: String?) -> (action: String, row: String?)? {
        if let selectedRow, let row = document.rows.first(where: { $0.id == selectedRow }),
           let action = row.actions.first(where: { $0.key == key }) {
            return (action.id, row.id)
        }
        if let action = document.actions.first(where: { $0.key == key }) {
            return (action.id, nil)
        }
        return nil
    }

    // True when the key belonged to this extension. The caller swallows it
    // either way — an unbound letter must not fall through to another tab's
    // handler — but the return says whether anything was spawned.
    @discardableResult
    func handle(key: String, on id: String) -> Bool {
        let pane = self.pane(id)
        guard !pane.busy, let document = pane.document,
              let hit = Self.resolve(key: key, in: document, selectedRow: pane.selectedRow)
        else { return false }
        perform(action: hit.action, row: hit.row, on: id)
        return true
    }

    private func invoke(_ id: String, action: String?, row: String?) {
        guard let manifest = manifest(id) else { return }
        var pane = self.pane(id)
        guard !pane.busy else { return }
        pane.busy = true
        pane.status = .loading
        panes[id] = pane

        let runner = self.runner
        background { [weak self] in
            let result = runner(manifest, action, row)
            self?.toMain { self?.finish(id, result) }
        }
    }

    // Visible for tests, which drive the store without a real spawn.
    func finish(_ id: String, _ result: ExtensionRuntime.Fetch) {
        var pane = self.pane(id)
        pane.busy = false
        pane.attemptedAt = Date()
        switch result {
        case .ok(let document):
            pane.document = document
            pane.updatedAt = Date()
            pane.status = .idle
            // A selection pointing at a row the new document doesn't have would
            // make ⏎ a no-op with a highlight still drawn somewhere.
            if let selected = pane.selectedRow,
               !document.rows.contains(where: { $0.id == selected }) {
                pane.selectedRow = nil
            }
        case .transient(let why):
            // Only a pane that has something to show can go stale; otherwise
            // "showing old data" would be a claim about an empty pane.
            pane.status = pane.document == nil ? .broken(why) : .stale(why)
        case .missing(let why), .malformed(let why):
            pane.status = .broken(why)
        }
        panes[id] = pane
    }
}
