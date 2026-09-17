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
        let parsed = decoded.rows?.compactMap { row -> Row? in
            // id and title are what a row *is* — one addresses it, the other is
            // the only thing guaranteed to be drawn. Everything else degrades.
            guard let id = row.id, !id.isEmpty, seen.insert(id).inserted,
                  let title = row.title
            else { return nil }
            return Row(id: id,
                       lead: clamp(row.lead),
                       title: clamp(title),  // non-optional overload
                       subtitle: clamp(row.subtitle),
                       value: clamp(row.value),
                       footnote: clamp(row.footnote),
                       track: row.track.flatMap { track in
                           track.fill.map {
                               Track(fill: clampFraction($0),
                                     ghost: track.ghost.map(clampFraction),
                                     tint: track.tint)
                           }
                       },
                       ornament: row.ornament.flatMap(ornament(from:)),
                       actions: actions(from: row.actions))
        } ?? []
        // Capped after parsing rather than before, so dropping a malformed row
        // doesn't cost a good one its place. What bounds the parse itself is the
        // output ceiling in ProcessOutput, which this sits behind.
        let rows = Array(parsed.prefix(maxRows))

        return .success(ExtensionDocument(
            schema: decoded.schema,
            state: state,
            message: clamp(decoded.message),
            header: decoded.header.flatMap { header in
                header.title.map {
                    Header(title: clamp($0),
                           badge: header.badge?.text.map {
                               Badge(text: clamp($0),
                                     tone: Tone(rawValue: header.badge?.tone ?? "") ?? .neutral)
                           },
                           trailing: clamp(header.trailing))
                }
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
    // Truncated rather than refused: an over-long title is a formatting slip in
    // the extension, and every text field is line-limited on screen anyway — the
    // cap is about what gets parsed and held, not what gets drawn.
    private static func clamp(_ text: String) -> String {
        text.count <= maxTextLength ? text : String(text.prefix(maxTextLength))
    }

    private static func clamp(_ text: String?) -> String? {
        text.map(clamp)
    }

    private static func clampFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // `kind` is read but currently only "sprite" exists; anything else is
    // dropped rather than guessed at, so adding a second kind later can't be
    // mistaken for one the old host silently mis-rendered.
    // A sprite is decoration on a 6pt bar, so these are generous rather than
    // tight. Capping fps alone was pointless: rows, columns and frame count were
    // all unbounded, and a single million-column frame parses happily and then
    // asks Canvas to fill a million cells on every tick.
    // Bounds on everything that arrives sized by the extension. The sprite got
    // these first; rows, actions and the strings themselves were left unbounded,
    // which is the same hole one level out — a script printing a million rows
    // inside the timeout is parsed in full before LazyVStack ever declines to
    // draw them. Generous enough that no honest document notices.
    static let maxRows = 500
    static let maxActions = 16
    static let maxTextLength = 256
    static let maxSpriteFrames = 32
    static let maxSpriteRows = 24
    static let maxSpriteColumns = 64
    static let maxSpriteFPS: Double = 30

    private static func ornament(from raw: Decoded.Ornament) -> Ornament? {
        guard (raw.kind ?? "sprite") == "sprite" else { return nil }
        let frames = (raw.frames ?? [])
            .prefix(maxSpriteFrames)
            .map { frame in
                frame.prefix(maxSpriteRows).map { String($0.prefix(maxSpriteColumns)) }
            }
            .filter { !$0.isEmpty }
        guard !frames.isEmpty else { return nil }
        // Zero or negative fps would divide by zero in the frame clock; a
        // single-frame sprite legitimately wants no animation at all.
        let fps = (raw.fps ?? 0) > 0 ? min(raw.fps ?? 0, maxSpriteFPS) : 0
        return Ornament(fps: fps,
                        anchor: Ornament.Anchor(rawValue: raw.anchor ?? "") ?? .fillEdge,
                        palette: raw.palette ?? [:],
                        frames: Array(frames))
    }

    // Actions with no id can't be dispatched and actions sharing one are
    // ambiguous, so both are dropped here rather than checked at press time.
    private static func actions(from raw: [Decoded.Action]?) -> [Action] {
        var seen = Set<String>()
        return (raw ?? []).prefix(maxActions).compactMap { action in
            guard let id = action.id, !id.isEmpty, seen.insert(id).inserted,
                  let label = action.label
            else { return nil }
            return Action(id: id, label: clamp(label),
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
        struct Badge: Decodable { let text: String?; let tone: String? }
        struct Header: Decodable { let title: String?; let badge: Badge?; let trailing: String? }
        // `fill` optional so a malformed track costs the track, not the row —
        // and so a future track that isn't a fraction isn't foreclosed.
        struct Track: Decodable { let fill: Double?; let ghost: Double?; let tint: String? }
        struct Ornament: Decodable {
            let kind: String?
            let fps: Double?
            let anchor: String?
            let palette: [String: String]?
            let frames: [[String]]?
        }
        struct Action: Decodable { let id: String?; let label: String?; let key: String? }
        // Every field optional, including the two the model requires. A row
        // that can't be read drops that row; it does not cost the pane the
        // other forty-nine. Strictness here used to be per-*field* rather than
        // per-row: an empty id dropped one row, but a missing title, a null, an
        // empty track object or an action without a label rejected the whole
        // document — so one malformed item in an API response blanked the tab.
        struct Row: Decodable {
            let id: String?
            let lead: String?
            let title: String?
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
// allowlist and ignores the rest.
//
// A refused key costs the action its shortcut, and — since extension panes are
// keyboard-driven and nothing here renders a button — that makes the action
// unreachable. That is a known limitation of the current pane, not a property
// of the schema: the action stays in the document, and giving it a reachable
// home is follow-up work.
enum ExtensionKey {
    static func grant(_ requested: String?) -> String? {
        guard let requested else { return nil }
        let key = requested.lowercased()
        if key == "return" { return key }
        // Scalars, not Characters. `count` is a grapheme count, so "a" plus a
        // variation selector, a ZWJ or a combining mark is one Character — and
        // inspecting only `unicodeScalars.first` left everything after the base
        // unexamined, including the isASCII test. Those all used to be granted,
        // producing a binding that can never fire (the key handler sees a plain
        // "a") and a footer hint advertising it anyway.
        guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
              scalar.isASCII, CharacterSet.alphanumerics.contains(scalar)
        else { return nil }
        return key
    }
}
