import Foundation

// Static map from Anthropic model-name prefix → context window size in
// tokens. Used to render "tokens / limit (xx%)" in the Sessions tab
// when we recognise the model; new models gracefully fall through to
// "tokens only" until this table is updated.
//
// Match by prefix because Anthropic suffixes model IDs with release
// dates (e.g. "claude-sonnet-4-7-20250606") — checking the family
// prefix lets one entry cover a whole minor-version run.
enum ModelLimits {

    // (prefix, limit) pairs. Order doesn't matter; longest match wins
    // if you add overlapping entries.
    private static let table: [(prefix: String, limit: Int)] = [
        // Claude 4.x family — all default to 200K. The 1M-context
        // Sonnet beta is opt-in via the anthropic-beta header and
        // doesn't change the model id, so we can't distinguish it
        // from the standard variant here. Users running 1M will see
        // an inflated percent; documented as a known limitation.
        ("claude-opus-4",   200_000),
        ("claude-sonnet-4", 200_000),
        ("claude-haiku-4",  200_000),
        // Claude 3.x family — same 200K window.
        ("claude-opus-3",   200_000),
        ("claude-sonnet-3", 200_000),
        ("claude-haiku-3",  200_000),
    ]

    static func limit(for model: String?) -> Int? {
        guard let model else { return nil }
        return table.first { model.hasPrefix($0.prefix) }?.limit
    }
}
