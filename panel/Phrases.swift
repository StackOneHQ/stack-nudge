import AppKit
import SwiftUI

// User-managed phrase pools layered on top of the shipped phrases/<lang>.sh
// defaults. Two pools per language: response (stop events) and notification
// (permission events). The user can:
//   - Add custom phrases (kept in the JSON)
//   - Disable individual defaults (kept in the JSON as a parallel set)
// notify.sh reads both and produces  defaults\disabled ∪ custom  at fire time.
//
// Storage at ~/.stack-nudge/phrases.user.json:
//   { "en": { "response":     { "custom": [...], "disabled": [...] },
//             "notification": { ... } } }
enum PhrasePool: String, CaseIterable {
    case response, notification

    var title: String {
        switch self {
        case .response:     return "Task complete"
        case .notification: return "Permission request"
        }
    }

    var subtitle: String {
        switch self {
        case .response:     return "Spoken when an agent finishes a turn."
        case .notification: return "Spoken when an agent pauses for approval."
        }
    }
}

struct PhraseStore {

    // Sample repo name used for the editor preview. Hard-coded so users see
    // a realistic substitution without us having to know their current dir.
    static let previewRepo = "stack-nudge"

    static var jsonURL: URL {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".stack-nudge")
        return URL(fileURLWithPath: dir).appendingPathComponent("phrases.user.json")
    }

    struct PoolState: Equatable {
        var custom:   [String] = []
        var disabled: [String] = []   // subset of shipped defaults the user has muted
    }

    typealias LangState = [PhrasePool: PoolState]

    // Load all user state for the given language. Tolerant of missing or
    // malformed file — returns empty pools then.
    static func load(lang: String) -> LangState {
        var out: LangState = [:]
        for pool in PhrasePool.allCases { out[pool] = PoolState() }

        guard let data = try? Data(contentsOf: jsonURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let langDict = raw[lang] as? [String: Any]
        else { return out }

        for pool in PhrasePool.allCases {
            guard let poolDict = langDict[pool.rawValue] as? [String: Any] else { continue }
            var state = PoolState()
            if let arr = poolDict["custom"] as? [String]   { state.custom   = arr }
            if let arr = poolDict["disabled"] as? [String] { state.disabled = arr }
            out[pool] = state
        }
        return out
    }

    static func save(lang: String, state: LangState) {
        let dir = jsonURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var raw: [String: Any] = [:]
        if let data = try? Data(contentsOf: jsonURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = existing
        }

        var langDict: [String: Any] = [:]
        for pool in PhrasePool.allCases {
            let s = state[pool] ?? PoolState()
            var poolDict: [String: Any] = [:]
            if !s.custom.isEmpty   { poolDict["custom"]   = s.custom }
            if !s.disabled.isEmpty { poolDict["disabled"] = s.disabled }
            if !poolDict.isEmpty   { langDict[pool.rawValue] = poolDict }
        }

        if langDict.isEmpty { raw.removeValue(forKey: lang) }
        else                 { raw[lang] = langDict }

        let data = (try? JSONSerialization.data(
            withJSONObject: raw, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        try? data.write(to: jsonURL, options: .atomic)
    }

    // Read shipped defaults for a given language by sourcing the bash file
    // and printing the arrays as JSON. We don't want to maintain two sources
    // of truth for the defaults — they live in phrases/<lang>.sh.
    static func defaults(lang: String) -> [PhrasePool: [String]] {
        let phrasesDir = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".stack-nudge/phrases")
        let path = "\(phrasesDir)/\(lang).sh"
        guard FileManager.default.fileExists(atPath: path) else { return [:] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [
            "-c",
            "source \"\(path)\"; printf '%s\\0' \"${TEMPLATES_RESPONSE[@]}\"; printf '\\0'; printf '%s\\0' \"${TEMPLATES_NOTIFICATION[@]}\"",
        ]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let parts = data.split(separator: 0x00, maxSplits: .max,
                                omittingEmptySubsequences: false)
        var responseItems: [String] = []
        var notificationItems: [String] = []
        var crossedBoundary = false
        for part in parts {
            if part.isEmpty {
                if !crossedBoundary { crossedBoundary = true }
                continue
            }
            let s = String(data: Data(part), encoding: .utf8) ?? ""
            guard !s.isEmpty else { continue }
            if !crossedBoundary { responseItems.append(s) }
            else                 { notificationItems.append(s) }
        }
        return [.response: responseItems, .notification: notificationItems]
    }
}

// MARK: - View model

final class PhrasesViewModel: ObservableObject {
    @Published var lang: String = "en"
    @Published var state: PhraseStore.LangState = [:]
    @Published var defaults: [PhrasePool: [String]] = [:]
    @Published var draft: String = ""
    @Published var draftPool: PhrasePool = .response
    @Published var error: String?
    @Published var selectedRow: Row?

    struct Row: Equatable {
        let pool: PhrasePool
        let phrase: String
        let isDefault: Bool
    }

    func load() {
        state = PhraseStore.load(lang: lang)
        defaults = PhraseStore.defaults(lang: lang)
    }

    func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var s = state[draftPool] ?? .init()
        guard !s.custom.contains(trimmed) else {
            error = "Already in your list."
            return
        }
        s.custom.append(trimmed)
        state[draftPool] = s
        draft = ""
        error = nil
        persist()
    }

    func removeCustom(pool: PhrasePool, phrase: String) {
        var s = state[pool] ?? .init()
        s.custom.removeAll { $0 == phrase }
        state[pool] = s
        if selectedRow?.phrase == phrase { selectedRow = nil }
        persist()
    }

    // Toggle a shipped default phrase between enabled and disabled.
    func toggleDefault(pool: PhrasePool, phrase: String) {
        var s = state[pool] ?? .init()
        if let idx = s.disabled.firstIndex(of: phrase) {
            s.disabled.remove(at: idx)
        } else {
            s.disabled.append(phrase)
        }
        state[pool] = s
        persist()
    }

    func isDisabled(pool: PhrasePool, phrase: String) -> Bool {
        state[pool]?.disabled.contains(phrase) ?? false
    }

    private func persist() {
        PhraseStore.save(lang: lang, state: state)
    }

    // Flat list of every visible row in display order, used by ↑/↓.
    var navigableRows: [Row] {
        var rows: [Row] = []
        for pool in PhrasePool.allCases {
            for phrase in defaults[pool] ?? [] {
                rows.append(Row(pool: pool, phrase: phrase, isDefault: true))
            }
            for phrase in state[pool]?.custom ?? [] {
                rows.append(Row(pool: pool, phrase: phrase, isDefault: false))
            }
        }
        return rows
    }

    func selectNext() {
        let rows = navigableRows
        guard !rows.isEmpty else { return }
        if let current = selectedRow,
           let idx = rows.firstIndex(of: current),
           idx + 1 < rows.count {
            selectedRow = rows[idx + 1]
        } else {
            selectedRow = rows.first
        }
    }

    func selectPrevious() {
        let rows = navigableRows
        guard !rows.isEmpty else { return }
        if let current = selectedRow,
           let idx = rows.firstIndex(of: current),
           idx - 1 >= 0 {
            selectedRow = rows[idx - 1]
        } else {
            selectedRow = rows.last
        }
    }

    // Space: toggle a default on/off if a default is selected. No-op on custom.
    func toggleSelected() {
        guard let row = selectedRow, row.isDefault else { return }
        toggleDefault(pool: row.pool, phrase: row.phrase)
    }

    // ⌫: remove the selected custom row. No-op on default.
    @discardableResult
    func removeSelected() -> Bool {
        guard let row = selectedRow, !row.isDefault else { return false }
        removeCustom(pool: row.pool, phrase: row.phrase)
        return true
    }
}

// MARK: - View

struct PhrasesView: View {

    @ObservedObject var model: PhrasesViewModel
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pool(.response)
                        pool(.notification)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(ThinScrollers())
                }
                .onChange(of: model.selectedRow) { newValue in
                    guard let row = newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(rowID(row), anchor: .center)
                    }
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { model.load() }
    }

    // Stable scroll target for a row. Pool + isDefault + phrase keeps custom
    // and default rows that share text (unlikely but possible) distinct.
    private func rowID(_ row: PhrasesViewModel.Row) -> String {
        "\(row.pool.rawValue)|\(row.isDefault ? "d" : "c")|\(row.phrase)"
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

            Text("Phrases")
                .font(.subheadline.weight(.medium))
                .padding(.leading, 6)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func pool(_ pool: PhrasePool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(pool.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                let custom = model.state[pool]?.custom.count ?? 0
                let disabled = model.state[pool]?.disabled.count ?? 0
                Text("\(custom) custom · \(disabled) muted")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(pool.subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            // Defaults — toggleable on/off.
            ForEach(model.defaults[pool] ?? [], id: \.self) { phrase in
                defaultRow(pool: pool, phrase: phrase)
            }

            // Custom additions.
            ForEach(model.state[pool]?.custom ?? [], id: \.self) { phrase in
                customRow(pool: pool, phrase: phrase)
            }

            inputField(for: pool)
        }
    }

    @ViewBuilder
    private func defaultRow(pool: PhrasePool, phrase: String) -> some View {
        let row = PhrasesViewModel.Row(pool: pool, phrase: phrase, isDefault: true)
        let disabled = model.isDisabled(pool: pool, phrase: phrase)
        let selected = model.selectedRow == row
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                model.toggleDefault(pool: pool, phrase: phrase)
            } label: {
                Image(systemName: disabled ? "circle" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(disabled ? Color.tertiaryLabelColor : Color.accentColor.opacity(0.8))
            }
            .buttonStyle(.plain)
            .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(phrase)
                    .font(.callout)
                    .foregroundStyle(disabled ? .tertiary : .secondary)
                    .strikethrough(disabled, color: Color.tertiaryLabelColor)
                Text(preview(of: phrase))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(rowBackground(selected: selected, dim: disabled))
        .contentShape(Rectangle())
        .id(rowID(row))
        .onTapGesture {
            model.selectedRow = row
        }
    }

    @ViewBuilder
    private func customRow(pool: PhrasePool, phrase: String) -> some View {
        let row = PhrasesViewModel.Row(pool: pool, phrase: phrase, isDefault: false)
        let selected = model.selectedRow == row
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "diamond.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor.opacity(0.7))
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(phrase)
                    .font(.callout)
                Text(preview(of: phrase))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            Button {
                model.removeCustom(pool: pool, phrase: phrase)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(rowBackground(selected: selected, dim: false))
        .contentShape(Rectangle())
        .id(rowID(row))
        .onTapGesture {
            model.selectedRow = row
        }
    }

    private func rowBackground(selected: Bool, dim: Bool) -> some View {
        let fill: Color = selected ? Color.accentColor.opacity(0.22)
                                    : Color.primary.opacity(dim ? 0.03 : 0.06)
        return RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
    }

    @ViewBuilder
    private func inputField(for pool: PhrasePool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Add a phrase. Use %s for the repo name.",
                          text: Binding(
                            get: { model.draftPool == pool ? model.draft : "" },
                            set: {
                                model.draft = $0
                                model.draftPool = pool
                                if !$0.isEmpty { model.selectedRow = nil }
                            }
                          ))
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .onSubmit {
                        model.draftPool = pool
                        model.add()
                    }

                Button {
                    model.draftPool = pool
                    model.add()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(model.draftPool != pool ||
                          model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.draftPool == pool, !model.draft.isEmpty {
                Text("Preview: \(preview(of: model.draft))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if model.draftPool == pool, let err = model.error {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        PageFooter {
            FooterHint(label: "Add",    keys: ["⏎"], primary: true)
            FooterHint(label: "Toggle", keys: ["␣"])
            FooterHint(label: "Remove", keys: ["⌫"])
            FooterHint(label: "Back",   keys: ["Esc"])
        }
    }

    private func preview(of template: String) -> String {
        let repo = PhraseStore.previewRepo
        guard let range = template.range(of: "%s") else { return template }
        return template.replacingCharacters(in: range, with: repo)
    }
}

private extension Color {
    static var tertiaryLabelColor: Color {
        Color(nsColor: .tertiaryLabelColor)
    }
}
