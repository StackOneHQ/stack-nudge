import SwiftUI

// One extension's declared config keys, as a form.
//
// The plumbing has worked since the runtime landed: ExtensionRuntime.environment
// reads the config file and passes every declared STACKNUDGE_EXT_ key through to
// the child. What was missing was anywhere to set one. That was fine while the
// only extension was `system`, which declares nothing — the Derby needs an
// organisation before it can draw anything at all, and "edit
// ~/.stack-nudge/config by hand" is not an answer for the first extension that
// actually needs a value.
//
// Every side effect is injected, like ExtensionCatalog's, so the save path can
// be driven in a test without touching the real config file.
final class ExtensionConfigModel: ObservableObject {

    let row: ExtensionRow
    // Where Back goes, which is not a constant: this page is reached both from
    // the Settings category that lists installed extensions and from the
    // browser. Sending everyone to the browser put people on a page they had
    // never opened, and told them so with a chevron reading "Extensions".
    let origin: PanelMode

    var backLabel: String { origin == .extensions ? "Browse" : "Settings" }

    var id: String { row.id }
    var name: String { row.name }
    var keys: [ExtensionManifest.ConfigKey] { row.configurableKeys }

    @Published var values: [String: String]
    // Cleared by the next edit, so the confirmation belongs to what is on
    // screen rather than to whatever was saved a minute ago.
    @Published private(set) var saved = false

    // Which field the keyboard is on while no field has focus. The page is a
    // list of fields and every other list in the panel is walked with the
    // arrows, but a focused text field is first responder and takes ↑↓ before
    // FloatingPanel.keyDown ever sees them, so the traversal has to live at the
    // level above the fields, exactly as the browser's does above its search
    // field. Seeded rather than left nil: arriving with nothing selected makes
    // the footer's Edit hint describe a key that does nothing.
    @Published var selectedKey: String?
    // Bumped to hand the selected field first-responder status, mirroring
    // ExtensionCatalog.searchFocusRequests. The page deliberately opens
    // *unfocused* so ⌘⌫, ↑↓ and Esc all work on arrival; ⏎ hands over.
    @Published private(set) var fieldFocusRequests = 0

    func focusSelectedField() {
        guard selectedKey != nil else { return }
        fieldFocusRequests += 1
    }

    private let persist: (String, String?) -> Void
    private let didChange: () -> Void
    let onRemove: () -> Void

    init(row: ExtensionRow,
         origin: PanelMode = .settings,
         read: () -> [String: String] = ConfigFile.read,
         persist: @escaping (String, String?) -> Void = ExtensionConfigModel.writeToConfigFile,
         didChange: @escaping () -> Void = {},
         onRemove: @escaping () -> Void = {}) {
        self.row = row
        self.origin = origin
        self.persist = persist
        self.didChange = didChange
        self.onRemove = onRemove

        // Only the declared keys. Reading the whole file into the form would
        // put forty unrelated settings — one of them a Slack token — behind an
        // extension's page.
        let existing = read()
        var seeded: [String: String] = [:]
        for key in row.configurableKeys { seeded[key.key] = existing[key.key] ?? "" }
        values = seeded
        selectedKey = row.configurableKeys.first?.key
    }

    // MARK: - Keyboard

    // Clamps rather than wrapping, like every other list in the panel. An
    // extension declaring no keys has nothing to move between, and one
    // declaring a single key has nowhere to go; both are no-ops rather than
    // special cases at the call site.
    func moveSelection(by delta: Int) {
        guard !keys.isEmpty else { return }
        let current = keys.firstIndex { $0.key == selectedKey }
        let next = current.map { min(max($0 + delta, 0), keys.count - 1) }
            ?? (delta > 0 ? 0 : keys.count - 1)
        selectedKey = keys[next].key
    }

    func selectEdge(top: Bool) {
        guard !keys.isEmpty else { return }
        selectedKey = top ? keys.first?.key : keys.last?.key
    }

    // Keeps the selection on a key this extension still declares. The model is
    // rebuilt per visit so this cannot drift today, but a form that grew its
    // fields from anywhere other than the constructor would dangle here first.
    func reconcileSelection() {
        guard let selectedKey else { return }
        if !keys.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = keys.first?.key
        }
    }

    // An unset key is removed rather than written empty: the runtime treats a
    // declared-but-empty key as absent, so writing "" would leave a line in the
    // config file that means nothing and reads like a configured value.
    static func writeToConfigFile(_ key: String, _ value: String?) {
        if let value {
            ConfigFile.write(key: key, value: value)
        } else {
            ConfigFile.remove(key: key)
        }
    }

    func binding(for key: ExtensionManifest.ConfigKey) -> Binding<String> {
        Binding(get: { [weak self] in self?.values[key.key] ?? "" },
                // Only a real change clears the confirmation. A field commits
                // its value when it loses focus, and ⏎ both saves and hands
                // focus back, so an unguarded setter wrote the same string
                // straight back and cleared "Saved" in the same frame it was
                // set: the save happened, and the only thing that said so
                // flickered out of existence.
                set: { [weak self] newValue in
                    guard let self, self.values[key.key] != newValue else { return }
                    self.values[key.key] = newValue
                    self.saved = false
                })
    }

    // MARK: - Validation

    // Pure, so the rules are testable without a form.
    //
    // Two things are refused, and neither is about trusting the user — the
    // config file is theirs and they can write anything into it by hand.
    //
    // A value naming a scheme must name https. An extension handed an http://
    // endpoint sends a request the user believes is encrypted, and nothing
    // downstream would ever say so; the Derby's own script refuses one too, but
    // the field is where a person can still be told about it.
    //
    // A newline is refused because the config file is line-based. ConfigFile
    // rewrites the single line that sets a key, so a pasted value carrying a
    // newline doesn't set a long value — it sets a short one and appends
    // whatever followed as its own directive.
    static func problem(with value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return "Line breaks aren't allowed here."
        }
        // Everything else invisible, named for what it is. A tab pasted out of
        // a spreadsheet is a control character and not a line break, and being
        // told about line breaks you didn't type is worse than being told
        // nothing.
        if trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
                || CharacterSet.illegalCharacters.contains($0)
        }) {
            return "That contains a character that can't be stored here."
        }
        guard trimmed.contains("://") else { return nil }
        guard trimmed.lowercased().hasPrefix("https://") else {
            return "Only https:// addresses are allowed."
        }
        return nil
    }

    func problem(for key: ExtensionManifest.ConfigKey) -> String? {
        Self.problem(with: values[key.key] ?? "")
    }

    var isValid: Bool { keys.allSatisfy { problem(for: $0) == nil } }

    // MARK: - Saving

    func save() {
        // The button is disabled too, but a return key press routes here
        // directly and a form that silently writes a rejected value would be
        // worse than one that does nothing.
        guard isValid else { return }
        for key in keys {
            let value = (values[key.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            persist(key.key, value.isEmpty ? nil : value)
        }
        saved = true
        // Re-running the extension is the whole point: a new organisation
        // should fill the tab without a restart.
        didChange()
    }
}

// MARK: - The view

struct ExtensionConfigView: View {

    @ObservedObject var model: ExtensionConfigModel
    let onBack: () -> Void

    // Which field is first responder, or nil while the page itself owns the
    // keyboard. A String? rather than the Bool this started as: with one Bool
    // bound to every field there is no way to say *which* field to focus, so
    // the form could only be entered with the mouse or with Tab, and it opened
    // with nothing focused at all, which left ⏎ advertised and dead.
    @FocusState private var focusedKey: String?

    // Two levels, the shape the browser uses above its search field and the
    // Usage tab above its detail. Level one owns ↑↓, ⏎ and ⌘⌫; level two is a
    // focused field, which takes every key before FloatingPanel.keyDown runs.
    private var editing: Bool { focusedKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        summary
                        if model.keys.isEmpty {
                            // Not a dead page. Every installed extension opens
                            // one, because this is where Remove lives and a row
                            // that opened nothing would make Enter mean
                            // something different depending on the extension.
                            Text("This extension has no settings.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(model.keys, id: \.key) { field($0) }
                        }
                        footerRow
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    // On the content, not on the ScrollView: ThinScrollers walks
                    // superviews for the NSScrollView, as every other call site
                    // in this tree does.
                    .background(ThinScrollers())
                }
                // Nearest-edge, matching the Settings detail pane: centring
                // re-scrolls the whole form on every ↑/↓ to park the selection
                // mid-pane, so fields slide under the cursor in a form tall
                // enough to scroll and sit still in one that isn't. Without any
                // of this the highlight moved somewhere the user could not see,
                // which at the panel's 260pt minimum is the second field on.
                .onChange(of: model.selectedKey) { key in
                    guard let key else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(key, anchor: nil)
                    }
                }
            }

            PageFooter {
                let hints = Self.footerHints(keyCount: model.keys.count,
                                             editing: editing, valid: model.isValid)
                ForEach(hints.indices, id: \.self) { FooterHintRow(spec: hints[$0]) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            // Deliberately NOT focused, for the reason the browser states on its
            // own search field: a focused field is first responder and
            // FloatingPanel.keyDown only fires for what the first responder
            // declines, so focusing on arrival hands the field Esc and ⌘⌫ and
            // leaves both hints describing keys that no longer do anything. ⏎
            // hands over.
            focusedKey = nil
            model.reconcileSelection()
        }
        .onChange(of: model.fieldFocusRequests) { _ in focusedKey = model.selectedKey }
        // A click into a field is a selection too, or ↑/↓ after Esc would resume
        // from wherever the keyboard last was rather than from the field in
        // front of you; the same disagreement between mouse and keyboard the
        // Settings cards fixed by moving the index on tap.
        .onChange(of: focusedKey) { key in
            if let key { model.selectedKey = key }
        }
    }

    // The bar as data, so the two levels can be asserted rather than read. Every
    // hint is true at the level it appears on. ⌘⌫ is the exception that has to
    // stay on both: it is a field-editor binding (deleteToBeginningOfLine) and a
    // focused field takes it first, so it dims rather than disappearing; the
    // bar must not reflow as focus moves.
    static func footerHints(keyCount: Int, editing: Bool,
                            valid: Bool = true) -> [FooterHintSpec] {
        var hints: [FooterHintSpec] = []
        if editing {
            // Dimmed on a value the form will refuse, which is the same answer
            // the Save button gives by disabling itself. save() guards too: a
            // form that silently wrote a rejected value would be worse than one
            // that does nothing.
            hints.append(FooterHintSpec(label: "Save", keys: ["⏎"],
                                        primary: true, dimmed: !valid))
            if keyCount > 1 {
                hints.append(FooterHintSpec(label: "Next field", keys: ["⇥"], shedOrder: 0))
            }
            hints.append(FooterHintSpec(label: "Done", keys: ["Esc"]))
        } else {
            // Only where there is something to edit. This page opens for every
            // installed extension, including ones declaring no keys, and a
            // refused one, which is the most common case of all, so an
            // unconditional hint promises a key with no handler behind it.
            if keyCount > 0 {
                hints.append(FooterHintSpec(label: "Edit", keys: ["⏎"], primary: true))
            }
            if keyCount > 1 {
                hints.append(FooterHintSpec(label: "Move", keys: ["↑↓", "⌘↑↓"]))
            }
            // The only way to commit an edit backed out of with Esc, and the
            // only Save at all once the field has given focus back. Level one
            // only: a focused field swallows ⌘S the way it swallows ⌘⌫, which
            // is why the editing bar names ⏎ instead.
            if keyCount > 0 {
                hints.append(FooterHintSpec(label: "Save", keys: ["⌘S"],
                                            dimmed: !valid, shedOrder: 1))
            }
            hints.append(FooterHintSpec(label: "Back", keys: ["Esc"]))
        }
        hints.append(FooterHintSpec(label: "Remove", keys: ["⌘⌫"], dimmed: editing))
        return hints
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text(model.backLabel).font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(model.name).font(.subheadline.weight(.medium)).padding(.leading, 6)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // What the card in Settings showed, so arriving here doesn't lose the
    // context you clicked from.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let version = model.row.installedVersion {
                    Text(version).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if model.row.updateAvailable, let available = model.row.availableVersion {
                    Text("update to \(available)").font(.caption2).foregroundStyle(.orange)
                }
            }
            if let reason = model.row.refusedReason {
                Text(reason).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.row.description.isEmpty {
                Text(model.row.description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.row.requires.isEmpty {
                Text("Needs \(model.row.requires.joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func field(_ key: ExtensionManifest.ConfigKey) -> some View {
        // Selected is the keyboard's position while nothing is focused. Once a
        // field is first responder the field's own ring says where you are, and
        // a second highlight behind it reads as two cursors.
        let selected = model.selectedKey == key.key && !editing
        return VStack(alignment: .leading, spacing: 4) {
            Text(key.displayLabel).font(.caption.weight(.medium))
            TextField(key.placeholder ?? "", text: model.binding(for: key))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .focused($focusedKey, equals: key.key)
                // Saves and hands the keyboard back, so ↑↓ and ⌘⌫ work again
                // without a separate keystroke. The browser's search field
                // releases on Enter for the same reason.
                .onSubmit {
                    model.save()
                    focusedKey = nil
                }
                // A focused field is first responder, and FloatingPanel.keyDown
                // only fires for what the first responder declines, so without
                // this, Esc did nothing at all from inside a field. It steps out
                // to the page rather than off it: two levels, two Escs, exactly
                // as the browser's search field and the history filter behave.
                .onExitCommand { focusedKey = nil }
            if let problem = model.problem(for: key) {
                Text(problem).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help = key.help, !help.isEmpty {
                Text(help).font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The key itself, because it is still settable by hand and because
            // a reviewer reading the extension's PR sees the same name here.
            Text(key.key).font(.system(size: 9).monospaced()).foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.accentColor.opacity(selected ? 0.12 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
        // No tap gesture on the container, and no combined accessibility
        // element: both would sit between the click and the text field inside
        // it. The mouse already picks a field by focusing it, which syncs the
        // selection back through onChange(of: focusedKey).
        //
        // The scroll anchor. Keyed by the config key because that is what the
        // selection is keyed by; an index would go stale against a form whose
        // fields came from a manifest.
        .id(key.key)
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if !model.keys.isEmpty {
                CardButton(title: "Save", prominent: true, enabled: model.isValid) {
                    model.save()
                }
                if model.saved {
                    Text("Saved").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Here rather than on the Settings card, so Enter on an installed
            // extension opens it instead of deleting it.
            CardButton(title: "Remove") { model.onRemove() }
        }
        .padding(.top, 6)
    }
}
