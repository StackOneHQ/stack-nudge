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

    let id: String
    let name: String
    let keys: [ExtensionManifest.ConfigKey]

    @Published var values: [String: String]
    // Cleared by the next edit, so the confirmation belongs to what is on
    // screen rather than to whatever was saved a minute ago.
    @Published private(set) var saved = false

    private let persist: (String, String?) -> Void
    private let didChange: () -> Void

    init(id: String,
         name: String,
         keys: [ExtensionManifest.ConfigKey],
         read: () -> [String: String] = ConfigFile.read,
         persist: @escaping (String, String?) -> Void = ExtensionConfigModel.writeToConfigFile,
         didChange: @escaping () -> Void = {}) {
        self.id = id
        self.name = name
        self.keys = keys
        self.persist = persist
        self.didChange = didChange

        // Only the declared keys. Reading the whole file into the form would
        // put forty unrelated settings — one of them a Slack token — behind an
        // extension's page.
        let existing = read()
        var seeded: [String: String] = [:]
        for key in keys { seeded[key.key] = existing[key.key] ?? "" }
        values = seeded
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
                set: { [weak self] newValue in
                    self?.values[key.key] = newValue
                    self?.saved = false
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.keys, id: \.key) { field($0) }
                    footerRow
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                // On the content, not on the ScrollView: ThinScrollers walks
                // superviews for the NSScrollView, as every other call site
                // in this tree does.
                .background(ThinScrollers())
            }

            PageFooter {
                FooterHint(label: "Back", keys: ["Esc"])
                FooterHint(label: "Save", keys: ["⏎"])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.caption.weight(.semibold))
                    Text("Extensions").font(.caption)
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

    private func field(_ key: ExtensionManifest.ConfigKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.displayLabel).font(.caption.weight(.medium))
            TextField(key.placeholder ?? "", text: model.binding(for: key))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { model.save() }
                // A focused field is first responder, and FloatingPanel.keyDown
                // only fires for what the first responder declines — so without
                // this, Esc stopped going back the moment anyone clicked into a
                // field, while the footer went on advertising it.
                .onExitCommand { onBack() }
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
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            CardButton(title: "Save", prominent: true, enabled: model.isValid) {
                model.save()
            }
            if model.saved {
                Text("Saved").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 2)
    }
}
