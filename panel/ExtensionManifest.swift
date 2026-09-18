import Foundation

// An extension's manifest: who it is, what tab it contributes, and how to run
// it. Codable rather than JSONSerialization because it's our own format, like
// EventLog — GitHub's release JSON stays hand-parsed because it isn't.
struct ExtensionManifest: Equatable {

    struct Tab: Equatable {
        let label: String
    }

    struct Refresh: Equatable {
        let onOpen: Bool
        let intervalSeconds: Int?
        let whileFocusedOnly: Bool

        static let never = Refresh(onOpen: true, intervalSeconds: nil, whileFocusedOnly: true)
    }

    // A config key the extension declares. A bare string is the original form
    // and stays valid; the object form adds what a settings form needs in order
    // to render a field for it rather than a raw environment variable name.
    //
    // One list rather than two. The tempting shape is to leave `config` as names
    // and add a parallel array describing them — which is the same mistake as
    // the asset name that used to be written in both the packer and the index
    // writer. The two drift, and what you get is a form field for a key that is
    // never passed, or a passed key with nowhere to set it.
    struct ConfigKey: Equatable {
        let key: String
        let label: String?
        let help: String?
        let placeholder: String?

        // What a form puts next to the field. Falling back to the key with its
        // namespace stripped is not pretty, but it is always right and it is
        // better than the bare STACKNUDGE_EXT_DERBY_ORG — an extension that
        // doesn't bother still gets a usable field.
        var displayLabel: String {
            if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
            return String(key.dropFirst(key.hasPrefix(ExtensionManifest.configPrefix) ? ExtensionManifest.configPrefix.count : 0))
        }
    }

    let id: String
    let name: String
    let version: String
    let schema: Int
    let tab: Tab
    let run: String
    let requires: [String]
    let config: [ConfigKey]
    let refresh: Refresh

    var tabEntry: ExtensionTab { ExtensionTab(id: id, label: tab.label) }

    // MARK: - Validation

    // The schema the host speaks. A document or manifest declaring anything
    // else is refused with its number quoted rather than coerced: additive
    // fields are the only compatible change, so a bump means "this host can't".
    static let supportedSchema = 1

    // Floor on a manifest-declared poll interval. Each tick is a process spawn,
    // so an extension asking for 1s would be spawning a script sixty times a
    // minute for as long as its tab is open. Nothing legitimate needs that, and
    // the value arrives from the package rather than from us.
    static let minimumIntervalSeconds = 5

    // Extensions live in their own environment namespace. See
    // ExtensionRuntime.environment for why a bare STACKNUDGE_ prefix was not a
    // filter. Enforced here as well as there, so a key outside the namespace is
    // a refusal a reviewer reads in the PR rather than an empty variable a
    // script discovers at runtime.
    static let configPrefix = "STACKNUDGE_EXT_"

    static func isPassableConfigKey(_ key: String) -> Bool {
        key.hasPrefix(configPrefix) && key.count > configPrefix.count
    }

    // The tab strip is a row of buttons across a fixed-width panel, and the id
    // is strictly validated while the label was not — so an empty or 300-character
    // label went straight into the strip and pushed every other tab off it.
    // Falls back to the id rather than rendering a nameless tab.
    static let maxTabLabelLength = 16

    static func tabLabel(_ raw: String, id: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return id }
        return String(trimmed.prefix(maxTabLabelLength))
    }

    // An id becomes a directory name under ~/.stack-nudge/extensions, so it is
    // validated before it ever reaches a path — the same shape guard as
    // ClaudeCliQuotaProbe.removeSessionFile, for the same reason. "..", a
    // leading slash and an empty string all fail this, which is the point.
    static func isValidID(_ id: String) -> Bool {
        // Must start with a letter or digit. A leading dash is read as an
        // option by anything that takes the id as an argument — the packaging
        // script handed it to tar, which refused with "Can't specify both -x
        // and -c" after validation had already passed it.
        id.range(of: "^[a-z0-9][a-z0-9-]{0,31}$", options: .regularExpression) != nil
    }

    // `run` is joined onto the extension's own directory, so it must stay
    // inside it. Absolute paths and any ".." component are refused outright
    // rather than normalised — there is no legitimate manifest that needs them.
    static func isValidRunPath(_ run: String) -> Bool {
        guard !run.isEmpty, !run.hasPrefix("/"), !run.hasPrefix("~") else { return false }
        return !run.split(separator: "/").contains("..")
    }

    // MARK: - Parsing

    enum ParseFailure: Error, Equatable {
        case malformed(String)          // not JSON, or a required field missing
        case unsupportedSchema(Int)     // well-formed, but from a newer host
        case invalidID(String)
        case invalidRunPath(String)
        case invalidConfigKey(String)

        var message: String {
            switch self {
            case .malformed(let why):        return why
            case .unsupportedSchema(let n):  return "needs manifest schema \(n); this version reads \(supportedSchema)"
            case .invalidID(let id):         return "invalid id \"\(id)\""
            case .invalidRunPath(let run):   return "invalid run path \"\(run)\""
            case .invalidConfigKey(let key):
                return "config key \"\(key)\" is outside \(configPrefix)*"
            }
        }
    }

    static func parse(_ data: Data) -> Result<ExtensionManifest, ParseFailure> {
        let decoded: Decoded
        do {
            decoded = try JSONDecoder().decode(Decoded.self, from: data)
        } catch let error as DecodingError {
            return .failure(.malformed(Self.describe(error)))
        } catch {
            return .failure(.malformed("not valid JSON"))
        }

        // Schema first: a newer manifest may well fail the field checks below
        // for reasons that are none of its business, and "invalid id" would be
        // a misleading thing to say about a manifest we simply can't read.
        guard decoded.schema == supportedSchema else {
            return .failure(.unsupportedSchema(decoded.schema))
        }
        guard isValidID(decoded.id) else { return .failure(.invalidID(decoded.id)) }
        let run = decoded.run ?? "./run"
        guard isValidRunPath(run) else { return .failure(.invalidRunPath(run)) }
        // Deduplicated by key, first occurrence winning. A manifest naming the
        // same key twice is a typo rather than a refusal, but the settings form
        // renders one field per entry and two fields writing one key is a form
        // where the answer depends on which box you filled in last.
        var seenConfigKeys = Set<String>()
        let config = (decoded.config ?? []).filter { seenConfigKeys.insert($0.key).inserted }
        if let stray = config.first(where: { !isPassableConfigKey($0.key) }) {
            return .failure(.invalidConfigKey(stray.key))
        }

        return .success(ExtensionManifest(
            id: decoded.id,
            name: decoded.name,
            version: decoded.version,
            schema: decoded.schema,
            tab: Tab(label: Self.tabLabel(decoded.tab?.label ?? decoded.name, id: decoded.id)),
            run: run,
            requires: decoded.requires ?? [],
            config: config,
            refresh: Refresh(onOpen: decoded.refresh?.onOpen ?? true,
                             intervalSeconds: decoded.refresh?.intervalSeconds
                                 .map { max($0, minimumIntervalSeconds) },
                             whileFocusedOnly: decoded.refresh?.whileFocusedOnly ?? true)))
    }

    // The decoder's own description names the field, which is the one thing a
    // extension author needs to fix it. Everything else in it is Swift noise.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "wrong type" : "wrong type for \"\(path)\""
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "unreadable"
        }
    }

    // Optionality lives here rather than on the model, so every caller of
    // ExtensionManifest gets settled values and the defaults are stated once.
    private struct Decoded: Decodable {
        struct Tab: Decodable { let label: String? }
        struct Refresh: Decodable {
            let onOpen: Bool?
            let intervalSeconds: Int?
            let whileFocusedOnly: Bool?
        }
        let id: String
        let name: String
        let version: String
        let schema: Int
        let tab: Tab?
        let run: String?
        let requires: [String]?
        let config: [ConfigKey]?
        let refresh: Refresh?
    }
}

// Decoded from either a bare key name or an object describing it. Written back
// in whichever form it came in, so a round-trip through the index doesn't turn
// every extension's plain key list into a wall of objects.
extension ExtensionManifest.ConfigKey: Codable {

    private enum CodingKeys: String, CodingKey {
        case key, label, help, placeholder
    }

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let name = try? single.decode(String.self) {
            self.init(key: name, label: nil, help: nil, placeholder: nil)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(key: try container.decode(String.self, forKey: .key),
                  label: try container.decodeIfPresent(String.self, forKey: .label),
                  help: try container.decodeIfPresent(String.self, forKey: .help),
                  placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder))
    }

    func encode(to encoder: Encoder) throws {
        guard label != nil || help != nil || placeholder != nil else {
            var single = encoder.singleValueContainer()
            return try single.encode(key)
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encodeIfPresent(label, forKey: .label)
        try container.encodeIfPresent(help, forKey: .help)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
    }
}
