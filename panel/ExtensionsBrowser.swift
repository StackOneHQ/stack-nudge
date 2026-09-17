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
    let config: [String]

    var isInstalled: Bool { installedVersion != nil || refusedReason != nil }

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
                config: entry.config))
        }
        // Installed but unpublished — still listed, so it can be seen and
        // removed rather than being invisible and permanent.
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
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    catalogueBody
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // On the content, not on the ScrollView: ThinScrollers walks
                // superviews for the NSScrollView, and every other call site in
                // the tree attaches it this way.
                .background(ThinScrollers())
            }

            PageFooter {
                FooterHint(label: "Back", keys: ["Esc"])
                FooterHint(label: "Reload", keys: ["R"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { catalog.loadIfNeeded() }
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
    private var catalogueBody: some View {
        let rows = ExtensionCatalog.rows(catalogue: catalog.entries,
                                         installed: host.manifests,
                                         refused: host.refused)
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
                note("No extensions are published yet.")
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
                        Text("Reads \(row.config.joined(separator: ", "))")
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
                  ? Color.primary.opacity(0.05)
                  : Color.orange.opacity(0.08)))
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
                if row.isInstalled {
                    cardButton("Remove") { catalog.remove(row.id) }
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
    }
}
