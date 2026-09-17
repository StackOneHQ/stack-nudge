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
        guard work[entry.id] == nil else { return }
        work[entry.id] = .installing
        background { [weak self] in
            guard let self else { return }
            let result = self.performInstall(entry)
            self.toMain { [weak self] in self?.finish(entry.id, result) }
        }
    }

    func remove(_ id: String) {
        guard work[id] == nil else { return }
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

    func dismissFailure(for id: String) {
        if case .failed = work[id] { work[id] = nil }
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
                    // Refusals first: a directory that looked like an extension
                    // and would not load is the thing somebody came here to
                    // understand. Until now it only ever reached stderr.
                    ForEach(host.refused, id: \.id) { refusal in
                        refusedRow(refusal)
                    }
                    catalogueBody
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(ThinScrollers())

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
        switch catalog.load {
        case .idle, .loading:
            note("Looking for extensions…")
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text(why).font(.caption).foregroundStyle(.orange)
                cardButton("Try again", prominent: true) { catalog.reload() }
            }
        case .loaded where catalog.entries.isEmpty:
            note("No extensions are published yet.")
        case .loaded:
            ForEach(catalog.entries, id: \.id) { entry in
                entryRow(entry)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - Rows

    private func entryRow(_ entry: ExtensionInstaller.IndexEntry) -> some View {
        let installed = host.manifest(entry.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: installed == nil ? "puzzlepiece.extension" : "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(installed == nil ? Color.secondary : Color.green)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.callout.weight(.medium))
                        Text(entry.version).font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if !entry.description.isEmpty {
                        Text(entry.description).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // What it will be able to read, before it is installed
                    // rather than after. The namespace is narrow by design, but
                    // narrow is not the same as nothing.
                    if !entry.config.isEmpty {
                        Text("Reads \(entry.config.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    if !entry.requires.isEmpty {
                        Text("Needs \(entry.requires.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                actionArea(entry, installed: installed)
            }
            if case .failed(let why) = catalog.work[entry.id] {
                HStack(spacing: 6) {
                    Text(why).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    cardButton("Dismiss") { catalog.dismissFailure(for: entry.id) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder
    private func actionArea(_ entry: ExtensionInstaller.IndexEntry,
                            installed: ExtensionManifest?) -> some View {
        switch catalog.work[entry.id] {
        case .installing, .removing:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        default:
            if let installed {
                VStack(alignment: .trailing, spacing: 4) {
                    if installed.version != entry.version {
                        cardButton("Update", prominent: true) { catalog.install(entry) }
                    }
                    cardButton("Remove") { catalog.remove(entry.id) }
                }
            } else {
                cardButton("Install", prominent: true) { catalog.install(entry) }
            }
        }
    }

    // A directory that looked like an extension and would not load. The reason
    // is the manifest parser's own message, so "needs manifest schema 2; this
    // version reads 1" is what the user sees rather than an absent tab.
    private func refusedRow(_ refusal: ExtensionRuntime.Refusal) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(.orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(refusal.id).font(.callout.weight(.medium))
                Text(refusal.reason).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            cardButton("Remove") { catalog.remove(refusal.id) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.orange.opacity(0.08)))
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
