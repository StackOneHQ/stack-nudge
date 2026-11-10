import Foundation

// The rules for a value written to an extension's config key, wherever it is
// written from: a text row on the extension's page, a picker, or a value a
// service offered. Pure, so they are testable without a page.
enum ExtensionConfigValue {

    // Two things are refused, and neither is about trusting the user — the
    // config file is theirs and they can write anything into it by hand.
    //
    // A value naming a scheme must name https. An extension handed an http://
    // endpoint sends a request the user believes is encrypted, and nothing
    // downstream would ever say so; the Derby's own script refuses one too, but
    // the field is where a person can still be told about it.
    //
    // A line break is refused because the config file is line-based. ConfigFile
    // rewrites the single line that sets a key, so a pasted value carrying one
    // doesn't set a long value — it sets a short one and appends whatever
    // followed as its own directive. Checked on the raw value, before the trim
    // a save applies, so a leading or trailing one is named too.
    static func problem(with value: String) -> String? {
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return "Line breaks aren't allowed here."
        }
        // Everything else invisible, named for what it is. A tab pasted out of
        // a spreadsheet is a control character and not a line break, and being
        // told about line breaks you didn't type is worse than being told
        // nothing.
        if value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.newlines.contains($0)
                || CharacterSet.illegalCharacters.contains($0)
        }) {
            return "That contains a character that can't be stored here."
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("://") else { return nil }
        guard trimmed.lowercased().hasPrefix("https://") else {
            return "Only https:// addresses are allowed."
        }
        return nil
    }

    // A typed key may only be saved as one of its values. Empty clears it, as
    // for any key, and what's already saved stays acceptable even if a service
    // isn't offering it right now.
    static func problem(with value: String, for key: ExtensionManifest.ConfigKey,
                        offered: [ConfigOption], saved: String?) -> String? {
        if let problem = problem(with: value) { return problem }
        guard !value.isEmpty, !key.kind.isText, value != saved,
              !key.kind.accepts(value, offered: offered) else { return nil }
        let options = key.kind.options(offered: offered, saved: nil).map(\.value)
        if options.isEmpty { return "That isn't one of the values it offers right now." }
        return "Use one of: " + options.prefix(8).joined(separator: ", ")
            + (options.count > 8 ? ", …" : "") + "."
    }

    // An unset key is removed rather than written empty: the runtime treats a
    // declared-but-empty key as absent, so writing "" would leave a line in the
    // config file that means nothing and reads like a configured value.
    static func writeToConfigFile(_ key: String, _ value: String?) {
        if let value {
            // Refused here as well as on the page and in ConfigFile itself.
            guard !ConfigFile.containsLineBreak(value) else { return }
            ConfigFile.write(key: key, value: value)
        } else {
            ConfigFile.remove(key: key)
        }
    }
}
