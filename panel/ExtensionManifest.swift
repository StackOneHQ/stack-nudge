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
        // What a service extension gets whatever it declared. Its process
        // pushes documents when it has something to say, so there is nothing
        // for the host to poll, and spawning `run` as a one-shot fetch would
        // start a second copy of a program written to stay up.
        static let pushed = Refresh(onOpen: false, intervalSeconds: nil, whileFocusedOnly: true)
    }

    // How the host runs `run`. A view extension is spawned per fetch and prints
    // one document; a service is kept running and talks the line protocol in
    // ServiceProtocol. See docs/design/service-extensions.md.
    enum Mode: String, Equatable {
        case view, service
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
    // Whether the widget may show this extension's header badge while it says
    // something urgent. Opt-in: the pill has room for one chip, and an
    // extension that never asked for it shouldn't be able to take it. Last and
    // defaulted, so every existing memberwise construction stays valid.
    var glance = false
    // Also last and defaulted, for the same reason as `glance`.
    var mode: Mode = .view
    // What the extension asks the app for, in manifest order without repeats.
    // Asking is not having: see ExtensionTier.grants for what it is given.
    var capabilities: [ExtensionCapability] = []

    var tabEntry: ExtensionTab { ExtensionTab(id: id, label: tab.label) }

    // MARK: - Validation

    // The schema the host speaks. A document or manifest declaring anything
    // else is refused with its number quoted rather than coerced: additive
    // fields are the only compatible change, so a bump means "this host can't".
    //
    // This is the *document* schema, and it is what STACKNUDGE_EXT_SCHEMA
    // tells a script. Manifests have their own range below: a service manifest
    // says 2 so that an older host, which checks for 1, refuses it with a
    // reason instead of running it as a view and waiting for a document that
    // never comes. Passing the manifest number to the script would tell a view
    // extension on schema 2 to print a document schema this host can't read.
    static let supportedSchema = 1

    // The manifest schemas this host reads. 1 is every view extension; 2 is
    // what service mode needs, and a view extension may say it too.
    static let supportedManifestSchemas = 1...2

    // The lowest manifest schema that may declare `"mode": "service"`.
    static let serviceManifestSchema = 2

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

    // Shape, not just prefix. A prefix test alone asks whether the key *starts*
    // in our namespace and says nothing about what follows, so a key could
    // carry a newline — and the settings form writes keys into
    // ~/.stack-nudge/config, which is line-based. A manifest declaring
    //
    //     "STACKNUDGE_EXT_DERBY_ORG\nSTACKNUDGE_CLAUDE_PATH=/tmp/evil\n#"
    //
    // rendered a labelled "Organisation" field; saving it wrote three lines,
    // the middle one setting the claude CLI path that ProcessOutput.claude()
    // executes and notify.sh sources. The user's typed value landed in the
    // discarded "#=" tail, so nothing looked wrong.
    //
    // Worth being exact about why this mattered under a curation model where an
    // extension already runs as the user: the injected line **outlives the
    // extension**. Uninstalling removes the directory and leaves the config
    // line, and a "\n" inside a JSON string in a config array is about as
    // invisible as a manifest gets — so it defeated the review that is supposed
    // to be the control, and persisted past the removal that is supposed to be
    // the remedy.
    //
    // Matches notify.sh's own reader, which accepts STACKNUDGE_[A-Z0-9_]+.
    //
    // \A and \z rather than ^ and $ because the two regex APIs disagree about
    // the end anchor, and the whole guard rests on it. With "$", the pattern is
    // safe under String.range(of:options:.regularExpression) — which treats it
    // as end-of-string — and unsafe under NSRegularExpression, where "$" also
    // matches before a single trailing line terminator, so a key ending in "\n"
    // would pass. Hoisting this into a compiled NSRegularExpression is an
    // obvious enough refactor that the pattern should not depend on nobody
    // doing it. \z is absolute in both.
    static func isPassableConfigKey(_ key: String) -> Bool {
        key.range(of: "\\A\(configPrefix)[A-Z0-9_]+\\z", options: .regularExpression) != nil
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
        case unknownMode(String)
        case serviceNeedsSchema(Int)    // "mode": "service" on a schema 1 manifest
        case unknownCapability(String)

        var message: String {
            switch self {
            case .malformed(let why):        return why
            case .unsupportedSchema(let n):
                return "needs manifest schema \(n); this version reads up to \(supportedManifestSchemas.upperBound)"
            case .invalidID(let id):         return "invalid id \"\(id)\""
            case .invalidRunPath(let run):   return "invalid run path \"\(run)\""
            case .invalidConfigKey(let key):
                return "config key \"\(key)\" is outside \(configPrefix)*"
            case .unknownMode(let mode):     return "unknown mode \"\(mode)\""
            case .serviceNeedsSchema(let n):
                return "service mode needs manifest schema \(serviceManifestSchema), not \(n)"
            case .unknownCapability(let name):
                return "unknown capability \"\(name)\""
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
        guard supportedManifestSchemas.contains(decoded.schema) else {
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

        let modeName = decoded.mode ?? Mode.view.rawValue
        guard let mode = Mode(rawValue: modeName) else { return .failure(.unknownMode(modeName)) }
        // Refused rather than quietly run as a view: a schema 1 manifest is one
        // an older host also reads, and there it would be a view extension that
        // never prints. The number is the signal to both hosts, so it has to be
        // right.
        if mode == .service, decoded.schema < serviceManifestSchema {
            return .failure(.serviceNeedsSchema(decoded.schema))
        }
        // An unknown capability is refused, not dropped. A capability is a
        // request a reviewer reads and the install prompt will list, so one
        // this host doesn't know is either a typo that would silently cost the
        // extension a feature, or something from a newer host that this one
        // can't honour. Either way the author should hear about it.
        var capabilities: [ExtensionCapability] = []
        for name in decoded.capabilities ?? [] {
            guard let capability = ExtensionCapability(rawValue: name) else {
                return .failure(.unknownCapability(name))
            }
            if !capabilities.contains(capability) { capabilities.append(capability) }
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
            refresh: mode == .service
                ? .pushed
                : Refresh(onOpen: decoded.refresh?.onOpen ?? true,
                          intervalSeconds: decoded.refresh?.intervalSeconds
                              .map { max($0, minimumIntervalSeconds) },
                          whileFocusedOnly: decoded.refresh?.whileFocusedOnly ?? true),
            glance: decoded.glance ?? false,
            mode: mode,
            capabilities: capabilities))
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
        let glance: Bool?
        let mode: String?
        let capabilities: [String]?
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

// What an extension may ask the app for. The app can only enforce what passes
// through it (signals, events and feed events) and refuses those unless they
// were granted. `bluetooth` is a declaration for review and the install prompt,
// not a gate: a child process inherits the app's TCC access whether it declared
// it or not.
enum ExtensionCapability: String, CaseIterable, Equatable {
    case bluetooth
    case signalPresence = "signal:presence"
    case eventIdle = "event:idle"
    case eventPanel = "event:panel"
    case eventSession = "event:session"
    case eventNudge = "event:nudge"
    case feed

    // The capability that gates an `event` or `signal` message by its name, so
    // the supervisor can check one without a table of its own.
    static func event(_ name: String) -> ExtensionCapability? {
        ExtensionCapability(rawValue: "event:\(name)")
    }

    static func signal(_ name: String) -> ExtensionCapability? {
        ExtensionCapability(rawValue: "signal:\(name)")
    }
}
