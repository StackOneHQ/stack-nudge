import Foundation

// Which releases the updater follows. Stable is the tagged releases, read
// from GitHub's /releases/latest, which leaves pre-releases out, so nothing
// here can reach someone who never opted in. Nightly is the rolling
// `nightly` pre-release that nightly.yml rebuilds from main each night.
enum UpdateChannel: String, CaseIterable {
    case stable, nightly

    static let configKey = "STACKNUDGE_UPDATE_CHANNEL"

    var label: String {
        switch self {
        case .stable:  return "Stable"
        case .nightly: return "Nightly"
        }
    }

    // Anything but "nightly" is stable, so a typo never opts anyone in.
    static func from(config value: String?) -> UpdateChannel {
        value?.trimmingCharacters(in: .whitespaces).lowercased() == "nightly" ? .nightly : .stable
    }

    var releaseURL: URL {
        switch self {
        case .stable:  return URL(string: "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/latest")!
        case .nightly: return URL(string: "https://api.github.com/repos/StackOneHQ/stack-nudge/releases/tags/nightly")!
        }
    }

    var releaseGHPath: String {
        switch self {
        case .stable:  return "repos/StackOneHQ/stack-nudge/releases/latest"
        case .nightly: return "repos/StackOneHQ/stack-nudge/releases/tags/nightly"
        }
    }
}

// A build's identity. "2.10.1" is a release. "2.10.1-nightly.812" is a
// nightly: a semver pre-release of 2.10.1, the release main is heading for
// (nightly.yml reads it from release-please's open release PR), where 812 is
// main's commit count, so a later build always has a larger number. As in
// semver, it comes before 2.10.1 itself.
struct BuildVersion: Equatable {
    let base: String
    let nightly: Int?

    static let nightlyMarker = "-nightly."
    // Info.plist key nightly.yml adds; a release build has none.
    static let nightlyBuildKey = "StackNudgeNightlyBuild"

    init(base: String, nightly: Int? = nil) {
        self.base = base
        self.nightly = nightly
    }

    init(_ version: String) {
        let parts = version.components(separatedBy: Self.nightlyMarker)
        if parts.count == 2, let build = Int(parts[1]) {
            self.init(base: parts[0], nightly: build)
        } else {
            self.init(base: version)
        }
    }

    // How it's written in file names, the status file and the update row.
    var string: String { nightly.map { "\(base)\(Self.nightlyMarker)\($0)" } ?? base }

    // How Settings shows it.
    var display: String { nightly.map { "\(base) (nightly \($0))" } ?? base }

    static func current(bundle: Bundle = .main) -> BuildVersion? {
        guard let base = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }
        let build = (bundle.infoDictionary?[nightlyBuildKey] as? String).flatMap(Int.init)
            ?? bundle.infoDictionary?[nightlyBuildKey] as? Int
        return BuildVersion(base: base, nightly: build)
    }

    // The version in an app artifact's name, stack-nudge-<version>-macos-<arch>.tar.gz.
    static func fromArtifact(_ name: String, arch: String) -> BuildVersion? {
        let prefix = "stack-nudge-", suffix = "-macos-\(arch).tar.gz"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count
        else { return nil }
        return BuildVersion(String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    // The version a release offers this Mac. A stable release is its tag. A
    // nightly is read from this arch's artifact rather than the release,
    // since each arch's upload replaces its own files and the two can briefly
    // be different builds.
    static func offered(by json: [String: Any]?, channel: UpdateChannel, arch: String) -> BuildVersion? {
        switch channel {
        case .stable:
            guard let tag = json?["tag_name"] as? String else { return nil }
            return BuildVersion(UpdateChecker.stripV(tag))
        case .nightly:
            let names = (json?["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return names.lazy.compactMap { fromArtifact($0, arch: arch) }.first { $0.nightly != nil }
        }
    }
}

enum UpdateOffer {

    // Whether `available`, from `channel`'s release, is worth offering to
    // the build that's running. Semver order throughout: X-nightly.n comes
    // before X.
    //
    // Stable offers a newer release. To a nightly that includes the release
    // it was leading up to, so switching back to Stable waits for that
    // release rather than stepping back to the one before.
    //
    // Nightly offers a later nightly, or to a release build, a nightly of a
    // later version: one of its own version would be a step back.
    static func shouldOffer(_ available: BuildVersion, to current: BuildVersion, on channel: UpdateChannel) -> Bool {
        let newerBase = UpdateChecker.isNewer(available.base, than: current.base)
        switch channel {
        case .stable:
            guard available.nightly == nil else { return false }
            return newerBase || (current.nightly != nil && available.base == current.base)
        case .nightly:
            guard let build = available.nightly else { return false }
            guard let running = current.nightly else { return newerBase }
            return build > running && !UpdateChecker.isNewer(current.base, than: available.base)
        }
    }
}
