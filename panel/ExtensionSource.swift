import Foundation

// Where extensions come from. The app's own release is always the first
// source and works as it always has. Others are GitHub repositories named in
// STACKNUDGE_EXTENSIONS_SOURCES (comma separated owner/repo), each publishing
// the same index and packages on its own latest release, so a team can run a
// catalogue of its own, a private one included, next to the public one.
//
// What an extra source may grant is capped here, in the binary, and never by
// configuration. Its index carries the tiers that repo's reviewers gave each
// extension. A repository on the reviewed list keeps them, because its review
// is ours, and every other one is held to `view`. A setting could not be the
// ceiling: anything that can write ~/.stack-nudge/config could then add a
// repository that grants itself `trusted`.
//
// The list names repositories, not an owner. Being StackOneHQ's says nothing
// about who reviews a repository's releases: anyone who can publish a release
// on any of its repositories could attach an index granting `trusted`, and the
// config could name that repository. Adding a catalogue here is a reviewed
// change to the app.
struct ExtensionSource: Equatable, Hashable {
    let owner: String
    let repo: String

    var slug: String { "\(owner)/\(repo)" }

    static let builtIn = ExtensionSource(owner: "StackOneHQ", repo: "stack-nudge")
    static let configKey = "STACKNUDGE_EXTENSIONS_SOURCES"

    // The catalogues whose reviewers are ours, besides the app's own.
    static let reviewed = [ExtensionSource(owner: "StackOneHQ", repo: "stack-nudge-internal-marketplace")]

    // GitHub compares names without case, so these do too: StackOneHQ and
    // stackonehq are the same owner, and listing the app's own repository
    // again in lowercase must not make it a second source.
    var isBuiltIn: Bool { sameRepository(as: .builtIn) }

    func sameRepository(as other: ExtensionSource) -> Bool {
        owner.caseInsensitiveCompare(other.owner) == .orderedSame
            && repo.caseInsensitiveCompare(other.repo) == .orderedSame
    }

    // The most this source's index can give an extension.
    var ceiling: ExtensionTier {
        if isBuiltIn || Self.reviewed.contains(where: sameRepository) { return .trusted }
        return .view
    }

    // Whether an owner/repo, as an entry or a record carries it (nil for the
    // app's own), names the same repository as another.
    static func same(_ slug: String?, _ other: String?) -> Bool {
        switch (slug, other) {
        case (nil, nil): return true
        case (let slug?, let other?):
            guard let source = ExtensionSource(slug: slug), let otherSource = ExtensionSource(slug: other)
            else { return false }
            return source.sameRepository(as: otherSource)
        default: return false
        }
    }

    // owner/repo, as GitHub allows them. Both end up in an API path, so
    // anything else is refused rather than escaped.
    init?(slug: String) {
        let parts = slug.trimmingCharacters(in: .whitespaces).split(separator: "/",
                                                                    omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), repo = String(parts[1])
        guard owner.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$", options: .regularExpression) != nil,
              repo.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil,
              repo != ".", repo != ".."
        else { return nil }
        self.init(owner: owner, repo: repo)
    }

    init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    // The extra sources the config names, in its order, without repeats and
    // without the app's own repository, which is always there already. An
    // entry that isn't owner/repo is skipped and named, so the browser can say
    // which one it ignored.
    static func configured(_ config: [String: String]) -> (sources: [ExtensionSource], ignored: [String]) {
        guard let value = config[configKey] else { return ([], []) }
        var sources: [ExtensionSource] = []
        var ignored: [String] = []
        for item in value.split(separator: ",") {
            let text = item.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let source = ExtensionSource(slug: text) else {
                ignored.append(text)
                continue
            }
            guard !source.isBuiltIn,
                  !sources.contains(where: { $0.sameRepository(as: source) })
            else { continue }
            sources.append(source)
        }
        return (sources, ignored)
    }
}
