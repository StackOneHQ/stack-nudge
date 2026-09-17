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

    let id: String
    let name: String
    let version: String
    let schema: Int
    let tab: Tab
    let run: String
    let requires: [String]
    let config: [String]
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
        let config = decoded.config ?? []
        if let stray = config.first(where: { !isPassableConfigKey($0) }) {
            return .failure(.invalidConfigKey(stray))
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
        let config: [String]?
        let refresh: Refresh?
    }
}
