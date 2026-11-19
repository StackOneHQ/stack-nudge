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

    // MARK: - Editing the setting

    // Why the Other catalogues page didn't add what was typed, said under its
    // field rather than saved and left for the browser to complain about.
    enum EditProblem: Error, Equatable {
        case notOwnerRepo
        case builtIn
        case alreadyAdded

        var message: String {
            switch self {
            case .notOwnerRepo: return "That isn't a repository. Write it as owner/repo, like StackOneHQ/stack-nudge-internal-marketplace."
            case .builtIn:      return "StackOneHQ/stack-nudge is always read. It doesn't need adding."
            case .alreadyAdded: return "That repository is already in the list."
            }
        }
    }

    // The setting's entries as written, in order. Kept as text rather than
    // parsed, so one that isn't owner/repo is still on the page to be removed
    // instead of vanishing from a list it is still in.
    static func entries(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // The setting with one more repository at the end. Refused rather than
    // written when it couldn't be read anyway: not owner/repo, the app's own,
    // or one already there under any case.
    static func adding(_ text: String, to value: String?) -> Result<String, EditProblem> {
        guard let source = ExtensionSource(slug: text) else { return .failure(.notOwnerRepo) }
        guard !source.isBuiltIn else { return .failure(.builtIn) }
        let existing = entries(value)
        let taken = existing.contains { ExtensionSource(slug: $0)?.sameRepository(as: source) ?? false }
        guard !taken else { return .failure(.alreadyAdded) }
        return .success((existing + [source.slug]).joined(separator: ","))
    }

    // The setting without an entry, and without anything else naming the same
    // repository, so a repeat written by hand goes with it. Nil once nothing
    // is left, which the page takes as removing the key.
    static func removing(_ entry: String, from value: String?) -> String? {
        let gone = ExtensionSource(slug: entry)
        let kept = entries(value).filter { item in
            if item == entry { return false }
            guard let gone, let source = ExtensionSource(slug: item) else { return true }
            return !source.sameRepository(as: gone)
        }
        return kept.isEmpty ? nil : kept.joined(separator: ",")
    }
}
