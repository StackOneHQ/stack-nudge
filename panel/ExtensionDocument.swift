import Foundation

// What an extension prints on stdout: one JSON document describing a whole
// pane. The primitives are deliberately generic — "a grid of coloured cells"
// is one, "a horse" is not — because the host renders these and has no idea
// what any particular extension is about.
struct ExtensionDocument: Equatable {

    enum State: String, Equatable {
        case ok, empty, error
    }

    enum Tone: String, Equatable {
        case neutral, success, warning, danger
    }

    struct Badge: Equatable {
        let text: String
        let tone: Tone
    }

    struct Header: Equatable {
        let title: String
        let badge: Badge?
        let trailing: String?
    }

    // A bar with an optional paler bar behind it. The ghost is here because the
    // Usage tab's pace marker already needed exactly this shape, and an
    // extension that wants to show progress-against-expected shouldn't have to
    // invent it.
    struct Track: Equatable {
        let fill: Double
        let ghost: Double?
        let tint: String?
    }

    // An animated pixel grid. `frames` is an array of frames, each an array of
    // rows, each row a string of palette keys; "." is transparent. Rows may be
    // ragged and frames may differ in size — the renderer takes the maximum, so
    // a sloppy sprite draws small rather than crashing.
    struct Ornament: Equatable {
        let fps: Double
        let anchor: Anchor
        let palette: [String: String]
        let frames: [[String]]

        enum Anchor: String, Equatable {
            case fillEdge = "fill-edge"
            case leading, trailing
        }
    }

    struct Action: Equatable {
        let id: String
        let label: String
        let key: String?
    }

    struct Row: Equatable {
        let id: String
        let lead: String?
        let title: String
        let subtitle: String?
        let value: String?
        let footnote: String?
        let track: Track?
        let ornament: Ornament?
        let actions: [Action]
    }

    let schema: Int
    let state: State
    let message: String?
    let header: Header?
    let rows: [Row]
    let actions: [Action]

    // An empty or failed document still renders, so the pane says what happened
    // rather than sitting blank. The fallbacks exist because `message` is
    // optional in the schema and an extension that omits it still gets a pane
    // that reads as deliberate.
    var placeholder: String? {
        switch state {
        case .ok:    return rows.isEmpty ? (message ?? "Nothing to show") : nil
        case .empty: return message ?? "Nothing to show"
        case .error: return message ?? "The extension reported an error"
        }
    }

    // MARK: - Parsing

    enum ParseFailure: Error, Equatable {
        case malformed(String)
        case unsupportedSchema(Int)

        var message: String {
            switch self {
            case .malformed(let why):       return why
            case .unsupportedSchema(let n): return "sent schema \(n); this version reads \(ExtensionManifest.supportedSchema)"
            }
        }
    }

    static func parse(_ data: Data) -> Result<ExtensionDocument, ParseFailure> {
        let decoded: Decoded
        do {
            decoded = try JSONDecoder().decode(Decoded.self, from: data)
        } catch let error as DecodingError {
            return .failure(.malformed(describe(error)))
        } catch {
            return .failure(.malformed("not valid JSON"))
        }
        guard decoded.schema == ExtensionManifest.supportedSchema else {
            return .failure(.unsupportedSchema(decoded.schema))
        }
        // An unrecognised state is not a reason to throw the document away —
        // rows are the substance and they parsed. Treat it as ok, which is the
        // reading that shows the most.
        let state = decoded.state.flatMap(State.init(rawValue:)) ?? .ok

        // Rows sharing an id would collapse under ForEach and make actions
        // ambiguous — the action payload names a row by id and nothing else.
        var seen = Set<String>()
        let rows = decoded.rows?.compactMap { row -> Row? in
            guard !row.id.isEmpty, seen.insert(row.id).inserted else { return nil }
            return Row(id: row.id,
                       lead: row.lead,
                       title: row.title,
                       subtitle: row.subtitle,
                       value: row.value,
                       footnote: row.footnote,
                       track: row.track.map {
                           Track(fill: clampFraction($0.fill),
                                 ghost: $0.ghost.map(clampFraction),
                                 tint: $0.tint)
                       },
                       ornament: row.ornament.flatMap(ornament(from:)),
                       actions: actions(from: row.actions))
        } ?? []

        return .success(ExtensionDocument(
            schema: decoded.schema,
            state: state,
            message: decoded.message,
            header: decoded.header.map {
                Header(title: $0.title,
                       badge: $0.badge.map { Badge(text: $0.text,
                                                   tone: Tone(rawValue: $0.tone ?? "") ?? .neutral) },
                       trailing: $0.trailing)
            },
            rows: rows,
            actions: actions(from: decoded.actions)))
    }

    // Clamped rather than rejected: a fill of 1.4 is an arithmetic slip in the
    // extension, and refusing the whole document over it would be a worse
    // outcome than drawing a full bar. The isFinite guard is insurance rather
    // than the front line — JSONDecoder refuses a literal that won't fit a
    // Double — but a non-finite width reaches CoreGraphics as a crash, which
    // isn't a thing to leave one decoder's behaviour away.
    private static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // `kind` is read but currently only "sprite" exists; anything else is
    // dropped rather than guessed at, so adding a second kind later can't be
    // mistaken for one the old host silently mis-rendered.
    private static func ornament(from raw: Decoded.Ornament) -> Ornament? {
        guard (raw.kind ?? "sprite") == "sprite" else { return nil }
        let frames = (raw.frames ?? []).filter { !$0.isEmpty }
        guard !frames.isEmpty else { return nil }
        // Zero or negative fps would divide by zero in the frame clock; a
        // single-frame sprite legitimately wants no animation at all.
        let fps = (raw.fps ?? 0) > 0 ? min(raw.fps ?? 0, 30) : 0
        return Ornament(fps: fps,
                        anchor: Ornament.Anchor(rawValue: raw.anchor ?? "") ?? .fillEdge,
                        palette: raw.palette ?? [:],
                        frames: frames)
    }

    // Actions with no id can't be dispatched and actions sharing one are
    // ambiguous, so both are dropped here rather than checked at press time.
    private static func actions(from raw: [Decoded.Action]?) -> [Action] {
        var seen = Set<String>()
        return (raw ?? []).compactMap { action in
            guard !action.id.isEmpty, seen.insert(action.id).inserted else { return nil }
            return Action(id: action.id, label: action.label,
                          key: ExtensionKey.grant(action.key))
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let ctx):
            let path = (ctx.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            return "missing \"\(path)\""
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "wrong type" : "wrong type for \"\(path)\""
        case .dataCorrupted: return "not valid JSON"
        @unknown default: return "unreadable"
        }
    }

    private struct Decoded: Decodable {
        struct Badge: Decodable { let text: String; let tone: String? }
        struct Header: Decodable { let title: String; let badge: Badge?; let trailing: String? }
        struct Track: Decodable { let fill: Double; let ghost: Double?; let tint: String? }
        struct Ornament: Decodable {
            let kind: String?
            let fps: Double?
            let anchor: String?
            let palette: [String: String]?
            let frames: [[String]]?
        }
        struct Action: Decodable { let id: String; let label: String; let key: String? }
        struct Row: Decodable {
            let id: String
            let lead: String?
            let title: String
            let subtitle: String?
            let value: String?
            let footnote: String?
            let track: Track?
            let ornament: Ornament?
            let actions: [Action]?
        }
        let schema: Int
        let state: String?
        let message: String?
        let header: Header?
        let rows: [Row]?
        let actions: [Action]?
    }
}

// Key bindings are requested, not granted. An extension asking for Esc would
// take away the only way out of the panel; ⌘-anything collides with the tab
// numbers; arrows are how you move between rows and tabs. So the host maps an
// allowlist and silently ignores the rest — the action still runs from its
// button, it just has no shortcut.
enum ExtensionKey {
    static func grant(_ requested: String?) -> String? {
        guard let requested else { return nil }
        let key = requested.lowercased()
        if key == "return" { return key }
        guard key.count == 1, let scalar = key.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar), scalar.isASCII
        else { return nil }
        return key
    }
}
