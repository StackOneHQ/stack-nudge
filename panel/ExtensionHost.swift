import Foundation

// What the widget shows for an extension that opted in: its header badge while
// the tone is worth interrupting for, the trailing text beside it, and the tab
// label so the chip says whose it is. Derived from the document the tab already
// renders, so an extension has nothing new to produce.
struct ExtensionGlance: Equatable, Identifiable {
    let id: String
    let label: String
    let text: String
    let tone: ExtensionDocument.Tone
    let trailing: String?
    // The extension has stopped refreshing: see ExtensionHost.glance. Drawn
    // dimmed, and `trailing` has already gone.
    var stale = false
}

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
        // Whether the last attempt failed in a way that is worth trying again.
        // A timeout or a non-zero exit is; a missing script or a document that
        // doesn't parse is not — those need the extension fixed, and retrying
        // one on every panel appearance is churn nobody asked for. `.broken`
        // alone cannot answer this: it covers both a transient failure with
        // nothing yet to show and a permanently broken extension.
        var lastFailureWasTransient = false
        // A fetch is in flight that is meant to *replace* what is on screen
        // rather than top it up, so the pane shows its loading state instead of
        // the previous document.
        //
        // Only opening the tab and asking for a refresh set this, never the
        // scheduled poll: blanking the pane every interval while somebody is
        // watching it is the periodic flicker this pane already had once. The
        // difference that matters is that a document from before you opened the
        // tab may not be about the same thing at all — the Derby's was a race
        // that had since finished, so the pane showed one race and then
        // silently became another.
        var supersedingFetch = false
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
    // Each running service extension's supervisor state, as last reported.
    // Nothing renders it yet; Settings will.
    @Published private(set) var services: [String: ServiceSupervisor.State] = [:]

    // Signals the service extensions hold. Nothing in the app reacts to one yet.
    let signals: SignalRegistry

    private let runner: (ExtensionManifest, String?, String?) -> ExtensionRuntime.Fetch
    private let onTabsChanged: ([ExtensionTab]) -> Void
    private let onRefusalsChanged: (Int) -> Void
    private let onGlancesChanged: ([ExtensionGlance]) -> Void
    // What was last published, so an unchanged glance doesn't redraw the widget
    // on every scheduled refresh.
    private var publishedGlances: [ExtensionGlance] = []
    private let background: (@escaping () -> Void) -> Void
    private let toMain: (@escaping () -> Void) -> Void

    // MARK: Service extensions

    typealias SupervisorFactory = (ExtensionManifest, [ExtensionCapability],
                                   @escaping (ServiceSupervisor.Event) -> Void) -> ServiceSupervisor

    private struct Service {
        let manifest: ExtensionManifest
        // What the tier allows, before signals are handed out. Compared on
        // every load, so a change of tier restarts the process with the new
        // grant rather than leaving it running on the old one.
        let allowed: [ExtensionCapability]
        // What it was actually given: `allowed` less any signal another
        // extension holds.
        let granted: [ExtensionCapability]
        let supervisor: ServiceSupervisor
        // Which supervisor an event came from. An old one still winding down
        // after an update shares the id with its replacement.
        let token: UUID
    }

    private let tiers: () -> [String: ExtensionTier]
    private let makeSupervisor: SupervisorFactory
    private var running: [String: Service] = [:]
    // Supervisors told to stop that haven't finished. A replacement waits for
    // its predecessor, so there is never more than one process per extension.
    private var stopping: [String: ServiceSupervisor] = [:]
    private var wanted: [String: (manifest: ExtensionManifest, allowed: [ExtensionCapability])] = [:]
    private var shuttingDown = false
    private var reportedFeed: Set<String> = []

    // `runner` is injected so the store can be driven with canned outcomes in
    // tests; the default spawns for real. It is called on a background queue,
    // so it takes and returns values rather than touching this object.
    //
    // The two hops are injected for the same reason RefreshGate injects its
    // timer: run them inline and the whole invocation becomes synchronous, so a
    // test can assert on the in-flight gate rather than on a race with it.
    init(onTabsChanged: @escaping ([ExtensionTab]) -> Void = { _ in },
         onRefusalsChanged: @escaping (Int) -> Void = { _ in },
         onGlancesChanged: @escaping ([ExtensionGlance]) -> Void = { _ in },
         background: @escaping (@escaping () -> Void) -> Void
             = { DispatchQueue.global(qos: .utility).async(execute: $0) },
         toMain: @escaping (@escaping () -> Void) -> Void
             = { DispatchQueue.main.async(execute: $0) },
         runner: @escaping (ExtensionManifest, String?, String?) -> ExtensionRuntime.Fetch
             = { ExtensionRuntime.fetch($0, action: $1, row: $2) },
         tiers: @escaping () -> [String: ExtensionTier] = { ExtensionTiers.read() },
         // In memory unless given a path. The app passes the real record; a
         // test that builds a host never writes to the user's.
         signals: SignalRegistry = SignalRegistry(),
         makeSupervisor: @escaping SupervisorFactory = { manifest, granted, onEvent in
             ServiceSupervisor.live(manifest: manifest,
                                    directory: ExtensionRuntime.directory(for: manifest.id) ?? "",
                                    granted: granted, onEvent: onEvent)
         }) {
        self.onTabsChanged = onTabsChanged
        self.onRefusalsChanged = onRefusalsChanged
        self.onGlancesChanged = onGlancesChanged
        self.background = background
        self.toMain = toMain
        self.runner = runner
        self.tiers = tiers
        self.makeSupervisor = makeSupervisor
        self.signals = signals
    }

    func pane(_ id: String) -> Pane { panes[id] ?? Pane() }

    // Plants pane state so a test can exercise a gate that only opens mid-flight
    // — the busy guard in particular, which is otherwise only reachable through
    // a race. Production state always goes through invoke/finish.
    func replacePaneForTesting(_ pane: Pane, on id: String) { panes[id] = pane }

    func manifest(_ id: String) -> ExtensionManifest? { manifests.first { $0.id == id } }

    // MARK: - Discovery

    func load(_ discovery: ExtensionRuntime.Discovery? = nil) {
        let found = discovery ?? ExtensionRuntime.discover()
        let tiers = self.tiers()
        var installed: [ExtensionManifest] = []
        var refusals = found.refused
        for manifest in found.installed {
            let tier = tiers[manifest.id] ?? .view
            // Refused rather than shown as a tab that never fills: its `run`
            // was written to stay up, so it can't be run as a view instead.
            if manifest.mode == .service, !tier.allowsServiceMode {
                refusals.append(.init(id: manifest.id,
                                      reason: "service mode needs the service tier; it has \(tier.rawValue)"))
                continue
            }
            installed.append(manifest)
        }
        manifests = installed
        refused = refusals
        // Still reported to stderr, but no longer only there: the Settings
        // browser renders these now, which is what the published property was
        // added for. The log line stays because a refusal at launch happens
        // before anybody opens Settings.
        for refusal in refusals {
            FileHandle.standardError.write(Data(
                "stack-nudge: extension \"\(refusal.id)\" not loaded — \(refusal.reason)\n".utf8))
        }
        // Drop state for anything no longer installed, so reinstalling an
        // extension doesn't resurrect the document from its previous life.
        let live = Set(manifests.map(\.id))
        panes = panes.filter { live.contains($0.key) }
        onTabsChanged(manifests.map(\.tabEntry))
        onRefusalsChanged(refused.count)
        publishGlances()

        wanted = [:]
        for manifest in manifests where manifest.mode == .service {
            wanted[manifest.id] = (manifest, ExtensionTier.grants(for: manifest,
                                                                  tier: tiers[manifest.id] ?? .view))
        }
        // A recorded holder that is gone, refused, or no longer granted the
        // signal gives it up, so the next one in line can have it.
        let wanted = self.wanted
        signals.forgetHolders { signal, id in
            wanted[id]?.allowed.contains(signal.capability) == true
        }
        reconcileServices()
    }

    // MARK: - Invocation

    // The pane came on screen: a tab switch, the panel returning, or the pill
    // expanding onto the tab someone left it on.
    //
    // One floor for all of them, because the view cannot tell them apart. In
    // compact mode — the default, and effectively the only mode — collapsing to
    // the pill removes this pane from the view tree entirely, so expanding it
    // again fires `onAppear` exactly as switching tabs does. An earlier version
    // of this tried to treat a switch as explicit and exempt it from the floor;
    // that put the exemption on the path everyone actually uses and the floor
    // on one almost nobody does, so every press of the hotkey spawned a script.
    //
    // ⌘R is the deliberate override. See `forceRefresh`.
    func tabAppeared(_ id: String, now: Date = Date()) {
        guard let manifest = manifest(id), manifest.refresh.onOpen else { return }
        let pane = self.pane(id)
        // A pane whose last attempt failed *transiently* and has nothing to
        // show is not protected by the floor. The floor exists so that showing
        // a window cannot spawn a script redundantly, and retrying a timeout is
        // not redundant — it is the whole reason somebody is looking at the tab
        // again. Without it a transient failure stuck for a full interval, and
        // switching away and back did nothing, which is what a person tries
        // first and what worked before the floor existed.
        //
        // Deliberately not every documentless pane. A missing script or a
        // document that doesn't parse is not going to come good by being run
        // again on every panel appearance; those want the extension fixed.
        let worthRetrying = pane.document == nil && pane.lastFailureWasTransient
        if !worthRetrying, let attemptedAt = pane.attemptedAt,
           now.timeIntervalSince(attemptedAt) < TimeInterval(Self.reopenFloor(manifest)) {
            return
        }
        refresh(id, superseding: true)
    }

    // What ⌘R does: refetch now, whatever the floor says.
    //
    // The floor exists so that showing a window cannot spawn a script, which is
    // a thing that happens to a user rather than something they ask for. This
    // is the opposite, and without it an extension declaring no actions of its
    // own has no way to refresh at all — the floor would otherwise have taken
    // away the switch-away-and-back that used to serve as one.
    func forceRefresh(_ id: String) {
        // On a service, ⌘R is offered only once it has given up, and means
        // try again. See `tabKeys`.
        if manifest(id)?.mode == .service { return retryService(id) }
        refresh(id, superseding: true)
    }

    // How stale a pane must be before coming on screen refetches it.
    //
    // The manifest's own interval, not the schema's minimum. Those are
    // different numbers and using the minimum was wrong: it is the fastest any
    // extension is *permitted* to poll (ExtensionManifest clamps declared
    // intervals up to it), not the cadence this one chose. An extension asking
    // for 600s against a rate-limited API would have been spawned every 5
    // seconds by someone toggling the panel — 120x what it declared.
    //
    // Reopening sooner than the interval leaves the pane showing data younger
    // than the extension itself called acceptable, which is what it asked for.
    // An onOpen-only extension has no interval to read, so it keeps the
    // minimum.
    static func reopenFloor(_ manifest: ExtensionManifest) -> Int {
        max(ExtensionManifest.minimumIntervalSeconds,
            manifest.refresh.intervalSeconds ?? ExtensionManifest.minimumIntervalSeconds)
    }

    // The extension's settings were saved. A view runs again with the new
    // environment; a running service is sent the new values without a restart,
    // and keeps them for its next one.
    func configChanged(_ id: String, configValues: [String: String] = ConfigFile.read()) {
        guard let manifest = manifest(id) else { return }
        guard manifest.mode == .service else { return refresh(id) }
        guard let service = running[id] else { return }
        let (environment, config) = ServiceSupervisor.configuration(for: service.manifest,
                                                                     configValues: configValues)
        service.supervisor.reconfigure(environment: environment, config: config)
    }

    func refresh(_ id: String, superseding: Bool = false) {
        invoke(id, action: nil, row: nil, superseding: superseding)
    }

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
        // No fetch yet at all. A focused-only pane leaves the first one to
        // onOpen (or the user), so its interval doesn't start until something
        // has been tried. A background one is due straight away: it polls so
        // that it can act while nobody is looking, and waiting for its tab to
        // be opened meant it did nothing after every launch, login or update
        // until somebody happened to open it.
        guard let attemptedAt = pane.attemptedAt else { return !manifest.refresh.whileFocusedOnly }
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
        // A glance goes stale with time as well as with failures, and an
        // extension that isn't being polled sends nothing that would notice.
        // Publishing only on change keeps this from redrawing the widget.
        publishGlances(now: now)
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
        guard manifest(id)?.mode == .view, !pane.busy, let document = pane.document,
              let hit = Self.resolve(key: key, in: document, selectedRow: pane.selectedRow)
        else { return false }
        perform(action: hit.action, row: hit.row, on: id)
        return true
    }

    private func invoke(_ id: String, action: String?, row: String?,
                        superseding: Bool = false) {
        // A service's documents come from its own process. Running `run` as a
        // one-shot fetch would start a second copy beside it.
        guard let manifest = manifest(id), manifest.mode == .view else { return }
        var pane = self.pane(id)
        guard !pane.busy else { return }
        pane.busy = true
        pane.status = .loading
        // Nothing on screen yet means nothing to supersede; the cold state is
        // already what gets drawn.
        pane.supersedingFetch = superseding && pane.document != nil
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
        // Cleared whatever the outcome: a fetch that failed has not superseded
        // anything, so the previous document comes back with its stale marker
        // rather than the pane sitting on "Loading…" forever.
        pane.supersedingFetch = false
        switch result {
        case .ok(let document):
            pane.lastFailureWasTransient = false
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
            pane.lastFailureWasTransient = true
            pane.status = pane.document == nil ? .broken(why) : .stale(why)
        case .missing(let why), .malformed(let why):
            pane.lastFailureWasTransient = false
            pane.status = .broken(why)
        }
        panes[id] = pane
        publishGlances()
    }

    // MARK: - Glances

    // How many of its own intervals a glance's document may go without a
    // successful refresh before the chip says so.
    static let glanceStaleAfterIntervals = 2

    // Only warning and danger. A glance is a request to be looked at, and
    // "CLEAR" or a neutral count on the widget all day is how a chip turns
    // into wallpaper.
    //
    // Kept through a failed refresh, like the document it comes from: the tab
    // marks that document stale rather than dropping it. But once a couple of
    // intervals have passed without a good one, whether the extension is failing
    // or nothing is polling it, the glance is marked stale and loses `trailing`:
    // a countdown frozen on the widget for hours is wrong. Dimmed rather than
    // dropped, because a chip that vanishes reads as "all clear".
    static func glance(for manifest: ExtensionManifest, pane: Pane,
                       now: Date = Date()) -> ExtensionGlance? {
        guard manifest.glance, let header = pane.document?.header, let badge = header.badge,
              badge.tone == .warning || badge.tone == .danger else { return nil }
        let stale: Bool
        if manifest.mode == .service {
            // A service sends a document when something changes, not on a
            // clock, so its age says nothing. What does is whether the process
            // behind it is still up, which the pane's status already tracks.
            stale = pane.status != .idle
        } else {
            let limit = TimeInterval(glanceStaleAfterIntervals * reopenFloor(manifest))
            stale = pane.updatedAt.map { now.timeIntervalSince($0) > limit } ?? false
        }
        return ExtensionGlance(id: manifest.id, label: manifest.tab.label, text: badge.text,
                               tone: badge.tone, trailing: stale ? nil : header.trailing,
                               stale: stale)
    }

    var glances: [ExtensionGlance] { glances(now: Date()) }

    func glances(now: Date) -> [ExtensionGlance] {
        manifests.compactMap { Self.glance(for: $0, pane: pane($0.id), now: now) }
    }

    private func publishGlances(now: Date = Date()) {
        let current = glances(now: now)
        guard current != publishedGlances else { return }
        publishedGlances = current
        onGlancesChanged(current)
    }

    // MARK: - Services

    // Which keys an extension's tab answers, for the router and the footer to
    // agree on. A view's ⌘R refetches and its document's actions run it. A
    // service has neither: its documents arrive by themselves, and its actions
    // would need a message the protocol doesn't have yet. Its ⌘R comes back
    // only once it is broken, as the way to try again.
    struct TabKeys: Equatable {
        // The ⌘R hint's label, or nil when ⌘R does nothing here.
        var refresh: String?
        var actions: Bool

        static let view = TabKeys(refresh: "Refresh", actions: true)
    }

    static func tabKeys(mode: ExtensionManifest.Mode, state: ServiceSupervisor.State?) -> TabKeys {
        guard mode == .service else { return .view }
        if case .broken? = state { return TabKeys(refresh: "Retry", actions: false) }
        return TabKeys(refresh: nil, actions: false)
    }

    func tabKeys(_ id: String) -> TabKeys {
        Self.tabKeys(mode: manifest(id)?.mode ?? .view, state: services[id])
    }

    // A fresh supervisor, so a fresh crash window: the user has asked, and
    // presumably fixed whatever it was.
    private func retryService(_ id: String) {
        guard case .broken? = services[id] else { return }
        stopService(id)
    }

    // Brings the running supervisors in line with what is installed: stops
    // what was removed or changed (an update, a new tier, a signal it was
    // refused that has since come free), and starts what is missing once any
    // predecessor has gone.
    //
    // Started in id order, so that when nobody has a signal on record, which
    // extension gets it is the same every launch rather than whatever order a
    // dictionary happened to iterate in. Once given, the record decides.
    private func reconcileServices() {
        guard !shuttingDown else { return }
        for (id, service) in running {
            let signalCameFree = AppSignal.allCases.contains {
                service.allowed.contains($0.capability) && !service.granted.contains($0.capability)
                    && signals.holders[$0] == nil
            }
            guard let want = wanted[id], want.manifest == service.manifest,
                  want.allowed == service.allowed, !signalCameFree else {
                stopService(id)
                continue
            }
        }
        for id in wanted.keys.sorted() where running[id] == nil && stopping[id] == nil {
            guard let want = wanted[id] else { continue }
            startService(want.manifest, allowed: want.allowed)
        }
    }

    private func startService(_ manifest: ExtensionManifest, allowed: [ExtensionCapability]) {
        let id = manifest.id
        // Signals are handed out here, first come first kept. One already held
        // by another extension is left out of the grant, so `hello` tells this
        // one the truth about what it can set.
        var granted = allowed
        for signal in AppSignal.allCases where granted.contains(signal.capability) {
            if !signals.claim(signal, by: id) {
                granted.removeAll { $0 == signal.capability }
                log(id, "not given \(signal.rawValue) \u{2014} \(signals.refusals[id]?.message ?? "it is held")")
            }
        }
        let token = UUID()
        let supervisor = makeSupervisor(manifest, granted) { [weak self] event in
            self?.toMain { self?.serviceEvent(event, from: id, token: token) }
        }
        running[id] = Service(manifest: manifest, allowed: allowed, granted: granted,
                              supervisor: supervisor, token: token)
        services[id] = .stopped
        supervisor.start()
    }

    private func stopService(_ id: String) {
        guard let service = running.removeValue(forKey: id) else { return }
        // Released now rather than when the process is finally gone: the
        // extension is no longer one the app listens to, so whatever it last
        // said must not keep acting.
        signals.release(id)
        services[id] = nil
        // Held here until the stop completes. This is the supervisor's only
        // strong reference, and letting go of it early would skip the polite
        // stop for the SIGKILL in its deinit.
        stopping[id] = service.supervisor
        service.supervisor.stop { [weak self] in
            self?.toMain {
                self?.stopping[id] = nil
                self?.reconcileServices()
            }
        }
    }

    // Quitting. Blocks until every service has gone or `timeout` passes, which
    // is the stop sequence's own worst case: a process left behind would carry
    // on running with nobody to stop it. The supervisors finish on their own
    // queues, so waiting here on main can't hold them up.
    func stopServices(waitingUpTo timeout: TimeInterval = 6) {
        shuttingDown = true
        wanted = [:]
        // Every supervisor is held until the wait is over: the stop runs on
        // its own queue, and one released before then would deinit and kill
        // its process outright instead of asking it to stop.
        let supervisors = running.values.map(\.supervisor) + Array(stopping.values)
        for id in running.keys { signals.release(id) }
        running = [:]
        services = [:]
        let group = DispatchGroup()
        for supervisor in supervisors {
            group.enter()
            supervisor.stop { group.leave() }
        }
        withExtendedLifetime(supervisors) {
            _ = group.wait(timeout: .now() + timeout)
        }
    }

    private func serviceEvent(_ event: ServiceSupervisor.Event, from id: String, token: UUID) {
        guard running[id]?.token == token else { return }
        switch event {
        case .state(let state):
            services[id] = state
            serviceStateChanged(id, state)
        case .document(let document):
            // Exactly the path a view fetch takes, so the tab can't tell them apart.
            finish(id, .ok(document))
        case .malformedDocument(let why):
            finish(id, .malformed(why))
        case .signal(let name, let value):
            if let refusal = signals.set(name, to: value, from: id) {
                log(id, "signal refused \u{2014} \(refusal.message)")
            }
        case .feed:
            // Accepted and dropped. Posting it means giving EventStore a source
            // per extension (`extension:<id>`, with its own cap), and
            // EventSource is a closed enum that the event log persists, so that
            // is its own change. Said once per process, not once per event.
            if reportedFeed.insert(id).inserted {
                log(id, "sent a feed event; those aren't shown yet, so it was dropped")
            }
        case .degraded(let why):
            log(id, "degraded \u{2014} \(why)")
        case .problem(let why):
            log(id, why)
        }
    }

    private func serviceStateChanged(_ id: String, _ state: ServiceSupervisor.State) {
        var pane = self.pane(id)
        switch state {
        case .starting:
            reportedFeed.remove(id)
            if pane.document == nil { pane.status = .loading }
        case .running:
            pane.status = pane.document == nil ? .loading : .idle
        case .restarting(let delay):
            // A dead holder must not leave the app acting on what it last said.
            signals.reset(id)
            let why = "restarting in \(Int(delay.rounded(.up)))s"
            pane.lastFailureWasTransient = true
            pane.status = pane.document == nil ? .broken(why) : .stale(why)
        case .broken(let termination):
            signals.reset(id)
            pane.lastFailureWasTransient = false
            pane.status = .broken(Self.brokenMessage(termination))
        case .stopping, .stopped:
            return
        }
        panes[id] = pane
        publishGlances()
    }

    static func brokenMessage(_ termination: ServiceSupervisor.Termination) -> String {
        switch termination {
        case .exited, .signalled:
            return "stopped restarting after repeated crashes; last \(termination.message)"
        case .unresponsive:
            return "stopped restarting after repeated crashes; the last one \(termination.message)"
        case .failedToStart, .incompatible:
            return termination.message
        }
    }

    private func log(_ id: String, _ message: String) {
        FileHandle.standardError.write(Data("stack-nudge: extension \"\(id)\" \(message)\n".utf8))
    }
}
