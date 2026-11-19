import CryptoKit
import Foundation

// Downloading and installing an extension.
//
// Deliberately a caseless enum of pure statics with the I/O injected, in the
// style of GitHubAPI rather than of Updater. Updater proved these steps work and
// its checksum policy is right, but every pure function in it is a private
// instance method on an object holding a weak nav, so none of it is reachable
// from a test — and `grep Updater Tests/` returns nothing. The parsing, the
// checksum comparison and the archive guard are the parts worth testing, so they
// are the parts that take no I/O at all.
enum ExtensionInstaller {

    // What the published index says is installable. Our own format, so Codable —
    // GitHub's release JSON stays hand-parsed because it isn't ours.
    struct IndexEntry: Codable, Equatable {
        let id: String
        let name: String
        let version: String
        let description: String
        let asset: String
        let sha256: String
        let requires: [String]
        // Key *names* only, deliberately, even though a manifest's entry may
        // carry a label and help text. The index is a wire format read by
        // binaries of every version — it is fetched from /releases/latest, so
        // an old host reads the newest index — and the settings form never
        // needs this: it renders for an installed extension and reads that
        // extension's own manifest. Putting the object form here would have
        // made a strictly additive manifest change into a breaking index
        // change, for no gain.
        let config: [String]
        // The tier the reviewers gave it (extensions/tiers.json), as a name.
        // Optional, because indexes before tiers don't carry it, and a String
        // rather than an ExtensionTier so a tier this host doesn't know
        // degrades to `view` instead of failing the whole entry. Recorded at
        // install; see ExtensionTiers.
        var tier: String? = nil

        var reviewedTier: ExtensionTier { tier.flatMap(ExtensionTier.init(rawValue:)) ?? .view }

        // What the manifest asks for, as the index publishes it. nil from an
        // index that predates the field, which is not the same as asking for
        // nothing. Names this host doesn't know are dropped.
        var capabilities: [String]? = nil
        // "view" or "service", as the manifest says; nil from an older index.
        var mode: String? = nil
        // Which source listed it: nil for the app's own release, otherwise the
        // extra source's owner/repo. The host stamps it after parsing and the
        // index can't carry it (it is not in CodingKeys), so one source's index
        // can't claim an entry belongs to another.
        var source: String? = nil

        private enum CodingKeys: String, CodingKey {
            case id, name, version, description, asset, sha256, requires, config, tier,
                 capabilities, mode
        }

        var requestedCapabilities: [ExtensionCapability]? {
            capabilities.map { $0.compactMap(ExtensionCapability.init(rawValue:)) }
        }
    }

    enum Failure: Error, Equatable {
        case malformedIndex(String)
        case unsupportedIndexSchema(Int)
        case invalidEntry(String)
        case sidecarMissing(String)
        case checksumMismatch(expected: String, actual: String)
        case unsafeArchive(String)
        case missingRequirement(String)
        case requirementWontRun(String, path: String)
        case manifestRejected(String)
        case differsFromIndex(String)
        case downloadFailed(String)
        case catalogueUnavailable
        case sourceUnavailable(String, signedIn: Bool)
        case installedFromElsewhere(String)
        case extractFailed(String)
        case installFailed(String)

        var message: String {
            switch self {
            case .malformedIndex(let why):     return "the extension index didn't parse — \(why)"
            case .unsupportedIndexSchema(let n):
                return "the index is schema \(n); this version reads \(indexSchema)"
            case .invalidEntry(let id):        return "the index lists an invalid extension \"\(id)\""
            case .sidecarMissing(let asset):
                return "no .sha256 published for \(asset) — refusing to install unverified"
            case .checksumMismatch:            return "the download didn't match its checksum"
            case .unsafeArchive(let why):      return "the package contains \(why)"
            case .missingRequirement(let what): return "needs \(what), which isn't installed"
            case .requirementWontRun(let what, let path):
                return "needs \(what), and \(path) is there but failed to run"
            case .manifestRejected(let why):   return "the package's manifest was refused — \(why)"
            case .differsFromIndex(let what):
                return "the package asks for something other than the catalogue said (\(what)), so it wasn't installed"
            case .downloadFailed(let what):    return "couldn't download \(what)"
            case .catalogueUnavailable:
                // Both paths failed. Anonymous GitHub is sixty requests an hour
                // per machine, so this is usually a wait rather than a fault.
                return "couldn't reach GitHub — it may be rate-limiting this "
                    + "machine, or be unreachable. Installing the gh CLI lets "
                    + "stack-nudge use your own quota."
            case .sourceUnavailable(_, let signedIn):
                // A private repository answers 404 to anyone who can't see it,
                // so "not there" and "not allowed" look the same from here.
                // Shown after the source's name, so it doesn't repeat it.
                return signedIn
                    ? "couldn't read its latest release. Check the name, and that your "
                        + "GitHub account can see it."
                    : "couldn't read its latest release. If it's private, sign in to "
                        + "GitHub in Settings or with the gh CLI."
            case .installedFromElsewhere:
                // Not naming where it came from: a copy put there by hand, or
                // under STACKNUDGE_EXTENSIONS_LOCAL_TIERS, came from no
                // catalogue at all.
                return "the installed copy isn't from this catalogue, so this can't update it. "
                    + "Remove it to install this one."
            case .extractFailed(let why):      return "couldn't unpack the download — \(why)"
            case .installFailed(let why):      return "couldn't install — \(why)"
            }
        }
    }

    static let indexSchema = 1

    // MARK: - The index

    static func parseIndex(_ data: Data) -> Result<[IndexEntry], Failure> {
        // One unreadable entry must not cost the rest. The index is fetched
        // from /releases/latest by every host at every version, so a newer
        // release's index reaches older binaries — decoding the array strictly
        // makes any future entry-shape change a break rather than a degrade.
        struct Lenient: Decodable {
            let entry: IndexEntry?
            init(from decoder: Decoder) throws {
                entry = try? IndexEntry(from: decoder)
            }
        }
        struct Document: Decodable {
            let schema: Int
            let extensions: [Lenient]?
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            return .failure(.malformedIndex("not valid JSON"))
        }
        guard document.schema == indexSchema else {
            return .failure(.unsupportedIndexSchema(document.schema))
        }
        let entries = (document.extensions ?? []).compactMap(\.entry)
        // An id from the index becomes a directory name and an asset name, so it
        // is validated here rather than trusted because it came from our own
        // release. The index is fetched over the network; "ours" is a claim
        // about provenance, not about the bytes that arrived.
        if let bad = entries.first(where: { !ExtensionManifest.isValidID($0.id) }) {
            return .failure(.invalidEntry(bad.id))
        }
        if let bad = entries.first(where: { !isSafeAssetName($0.asset) }) {
            return .failure(.invalidEntry(bad.id))
        }
        return .success(entries)
    }

    // The asset name is appended to a URL and used as a filename, so it may not
    // carry a path of its own.
    static func isSafeAssetName(_ asset: String) -> Bool {
        !asset.isEmpty
            && !asset.contains("/")
            && !asset.contains("\\")
            && asset != "."
            && asset != ".."
            && asset.hasSuffix(".tar.gz")
    }

    // MARK: - Checksums

    // The sidecar is `<hex>  <name>`, so the hash is the first whitespace-
    // separated token. Matches what release.yml writes and what Updater reads.
    static func expectedHex(fromSidecar raw: String) -> String? {
        let token = raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
        guard let token, token.count == 64,
              token.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return token.lowercased()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ data: Data, expectedHex expected: String) -> Result<Void, Failure> {
        let actual = sha256Hex(data)
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            return .failure(.checksumMismatch(expected: expected.lowercased(), actual: actual))
        }
        return .success(())
    }

    // MARK: - The archive

    // The guard Updater never had. Its extractTarball is a bare `tar -xzf` with
    // no entry validation at all, so the only thing between a hostile archive and
    // an arbitrary write is the checksum and GitHub's TLS. That is an acceptable
    // bet for our own app bundle, signed and notarized by us; it is not one to
    // inherit for a package whose whole point is that somebody else wrote it.
    //
    // Pure over the listing text (`tar -tzf`), so every hostile shape is testable
    // without building an archive.
    //
    // This rests on one property of tar that is worth naming because nothing in
    // the format guarantees it: bsdtar *escapes* control characters in a listing,
    // so a filename containing a newline prints as the literal two characters
    // \n on one line rather than splitting into two. One entry is always one
    // line. Splitting can therefore only add lines, and every line is validated
    // independently — the parse gets stricter, never looser. GNU tar quotes
    // differently again, so a test pins the assumption rather than trusting it.
    static func safeEntries(fromListing listing: String, id: String) -> Result<[String], Failure> {
        var entries: [String] = []
        for line in listing.split(separator: "\n") {
            let entry = String(line)
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("/") {
                return .failure(.unsafeArchive("an absolute path (\(entry))"))
            }
            // Checked per component so "..foo" stays legal while "../" doesn't.
            let components = entry.split(separator: "/", omittingEmptySubsequences: true)
            if components.contains("..") {
                return .failure(.unsafeArchive("a path that escapes it (\(entry))"))
            }
            // Everything must live under the id directory, which is what the
            // packaging script's `tar -C` produces. An archive that unpacks
            // somewhere else is not the extension it claims to be.
            guard components.first.map(String.init) == id else {
                return .failure(.unsafeArchive("a path outside \(id)/ (\(entry))"))
            }
            entries.append(entry)
        }
        guard !entries.isEmpty else { return .failure(.unsafeArchive("no files")) }
        guard entries.contains("\(id)/manifest.json") else {
            return .failure(.unsafeArchive("no manifest.json"))
        }
        return .success(entries)
    }

    // `tar -tvz` prefixes each line with a mode string, so a symlink entry starts
    // with "l" and a device with "b"/"c". Only regular files and directories are
    // allowed through — the same rule the packaging script enforces at review
    // time, applied again to the bytes that actually arrived.
    static func rejectsNonRegularEntries(inVerboseListing listing: String) -> Failure? {
        for line in listing.split(separator: "\n") {
            guard let kind = line.first else { continue }
            switch kind {
            case "-", "d": continue
            case "l":      return .unsafeArchive("a symlink")
            case "h":      return .unsafeArchive("a hard link")
            default:       return .unsafeArchive("a special file")
            }
        }
        return nil
    }

    // MARK: - Requirements

    // What checking one requirement found. Found-but-broken is its own answer:
    // a Command Line Tools stub left broken by an Xcode update resolves and then
    // fails, and "isn't installed" sent people looking for an interpreter they
    // already had rather than at Xcode.
    enum RequirementCheck: Equatable {
        case works
        case missing
        case wontRun(path: String)
    }

    // A requirement this Mac doesn't meet, as the extensions browser shows it.
    struct UnmetRequirement: Equatable {
        let name: String
        let check: RequirementCheck
    }

    // Executed, not resolved. `command -v python3` succeeds on the Command Line
    // Tools stub and then fails the moment anything runs, which is precisely the
    // failure this check exists to catch before an extension is installed rather
    // than after its tab first opens.
    static func unmetRequirement(
        in requires: [String],
        probe: (String) -> RequirementCheck = { ExtensionInstaller.checkRequirement($0) }
    ) -> Failure? {
        for name in requires {
            switch probe(name) {
            case .works:              continue
            case .missing:            return .missingRequirement(name)
            case .wontRun(let path):  return .requirementWontRun(name, path: path)
            }
        }
        return nil
    }

    // MARK: - Installing

    // Where the index lives on a release: the app's own, or an extra source's
    // (see ExtensionSource), each carrying its own packages beside it.
    static func indexURL(forRelease assets: [String: URL]) -> URL? {
        assets["extensions-index.json"]
    }

    struct Sources {
        // Asset name -> download URL, from the release JSON. The installer never
        // builds a URL itself, so a hostile index cannot point the fetch
        // anywhere the release doesn't already publish.
        let assets: [String: URL]
        let fetch: (URL) -> Data?
    }

    // The whole install, with every side effect injected. Returns the id on
    // success so the caller can persist it.
    //
    // Order matters and is the point: verify the bytes before unpacking them,
    // inspect the archive before extracting it, and validate the manifest before
    // committing anything to the extensions directory.
    static func install(_ entry: IndexEntry,
                        from sources: Sources,
                        into root: String = ExtensionRuntime.root,
                        fileManager: FileManager = .default,
                        listArchive: (String) -> (plain: String, verbose: String)? = tarListing,
                        extract: (String, String) -> Bool = untar,
                        probeRequirement: (String) -> RequirementCheck = { checkRequirement($0) })
        -> Result<String, Failure> {

        guard ExtensionManifest.isValidID(entry.id) else {
            return .failure(.invalidEntry(entry.id))
        }
        if let unmet = unmetRequirement(in: entry.requires, probe: probeRequirement) {
            return .failure(unmet)
        }
        guard let assetURL = sources.assets[entry.asset] else {
            return .failure(.downloadFailed(entry.asset))
        }
        // The sidecar is fatal when absent, not advisory. A release missing one
        // is tampered or incomplete, and installing unverified is the thing this
        // whole path exists to avoid.
        guard let sidecarURL = sources.assets["\(entry.asset).sha256"] else {
            return .failure(.sidecarMissing(entry.asset))
        }
        guard let payload = sources.fetch(assetURL) else {
            return .failure(.downloadFailed(entry.asset))
        }
        guard let sidecarData = sources.fetch(sidecarURL),
              let sidecar = String(data: sidecarData, encoding: .utf8),
              let expected = expectedHex(fromSidecar: sidecar)
        else { return .failure(.sidecarMissing(entry.asset)) }

        // The index carries a hash too, but it is the same document that named
        // the asset — agreeing with itself proves nothing. The sidecar is a
        // separate artifact, so it is the one that counts.
        if case .failure(let failure) = verify(payload, expectedHex: expected) {
            return .failure(failure)
        }
        guard expected.caseInsensitiveCompare(entry.sha256) == .orderedSame else {
            return .failure(.checksumMismatch(expected: entry.sha256.lowercased(),
                                              actual: expected))
        }

        sweepStaleStaging(fileManager: fileManager)
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return .failure(.installFailed("couldn't create a staging directory"))
        }

        let archive = staging.appendingPathComponent("\(entry.id).tar.gz")
        do { try payload.write(to: archive) } catch {
            return .failure(.installFailed("couldn't write the download"))
        }

        // Look before unpacking. Updater extracts first and asks nothing.
        guard let listing = listArchive(archive.path) else {
            return .failure(.extractFailed("couldn't read the archive"))
        }
        if let unsafe = rejectsNonRegularEntries(inVerboseListing: listing.verbose) {
            return .failure(unsafe)
        }
        if case .failure(let failure) = safeEntries(fromListing: listing.plain, id: entry.id) {
            return .failure(failure)
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        } catch {
            return .failure(.installFailed("couldn't create an unpack directory"))
        }
        guard extract(archive.path, unpacked.path) else {
            return .failure(.extractFailed("tar refused it"))
        }

        let source = unpacked.appendingPathComponent(entry.id, isDirectory: true)
        guard let manifestData = fileManager.contents(
            atPath: source.appendingPathComponent("manifest.json").path)
        else { return .failure(.manifestRejected("no manifest.json")) }

        // Validated against the same parser the runtime uses, before anything is
        // committed — so a package whose manifest the host would refuse never
        // reaches the extensions directory to be refused later.
        switch ExtensionManifest.parse(manifestData) {
        case .failure(let failure):
            return .failure(.manifestRejected(failure.message))
        case .success(let manifest) where manifest.id != entry.id:
            return .failure(.manifestRejected("manifest declares id \"\(manifest.id)\""))
        case .success(let manifest):
            // The user confirmed what the index described; don't install
            // something else.
            if let difference = differenceFromIndex(manifest, entry) {
                return .failure(.differsFromIndex(difference))
            }
        }

        guard let destination = ExtensionRuntime.directory(for: entry.id, in: root) else {
            return .failure(.invalidEntry(entry.id))
        }
        stripQuarantine(source.path)
        do {
            try fileManager.createDirectory(atPath: root, withIntermediateDirectories: true)
            // Replace rather than merge: leftovers from an older version would
            // otherwise survive alongside the new one.
            try? fileManager.removeItem(atPath: destination)
            try fileManager.moveItem(atPath: source.path, toPath: destination)
        } catch {
            return .failure(.installFailed(error.localizedDescription))
        }
        return .success(entry.id)
    }

    static let stagingPrefix = "stack-nudge-extension-"

    // The defer that removes a staging directory only runs on a normal return,
    // so a quit or a crash mid-install leaves one behind for good. Updater has
    // sweepStaleTempDirs for precisely this; this path copied its steps and not
    // its cleanup. Swept on the way in, since that is the moment we know no
    // install of ours is using one.
    static func sweepStaleStaging(fileManager: FileManager = .default,
                                  in directory: String = NSTemporaryDirectory()) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix(stagingPrefix) {
            try? fileManager.removeItem(atPath: "\(directory)/\(name)")
        }
    }

    static func remove(_ id: String,
                       from root: String = ExtensionRuntime.root,
                       fileManager: FileManager = .default) -> Result<String, Failure> {
        // Goes through the same id guard as everything else, so a crafted id
        // cannot delete a directory outside the extensions root.
        guard let directory = ExtensionRuntime.directory(for: id, in: root) else {
            return .failure(.invalidEntry(id))
        }
        guard fileManager.fileExists(atPath: directory) else { return .success(id) }
        do { try fileManager.removeItem(atPath: directory) } catch {
            return .failure(.installFailed(error.localizedDescription))
        }
        return .success(id)
    }

    // What the package's manifest says that its index entry didn't, where the
    // entry said anything: how it runs, and what it asks for. nil when they
    // agree, or when the index predates the fields.
    static func differenceFromIndex(_ manifest: ExtensionManifest, _ entry: IndexEntry) -> String? {
        if let mode = entry.mode, mode != manifest.mode.rawValue {
            return "runs as \(manifest.mode.rawValue), not \(mode)"
        }
        if let listed = entry.capabilities,
           Set(listed) != Set(manifest.capabilities.map(\.rawValue)) {
            return "capabilities differ"
        }
        return nil
    }

    // MARK: - Talking to the release

    // Which of an asset's URLs to download it from. The app's own release is
    // public, so the browser link works with no token. An extra source may be
    // private, and a private release's browser link only works for a signed-in
    // browser, so its assets come through the API instead: the asset's own
    // `url`, asked for as application/octet-stream with the token.
    enum AssetLink: Equatable {
        case browserDownload
        case api(ExtensionSource)
    }

    // Asset name -> download URL, from the release JSON. Hand-parsed, because
    // this one is GitHub's format rather than ours — the same split the manifest
    // and the index already follow.
    static func assets(fromReleaseJSON data: Data,
                       via link: AssetLink = .browserDownload) -> [String: URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]]
        else { return [:] }
        var result: [String: URL] = [:]
        for asset in assets {
            let field: String
            switch link {
            case .browserDownload: field = "browser_download_url"
            case .api: field = "url"
            }
            guard let name = asset["name"] as? String,
                  let raw = asset[field] as? String,
                  let url = URL(string: raw),
                  // A release JSON could name any scheme, and file:// fails
                  // closed only because httpGET insists on an HTTPURLResponse.
                  // Saying so here means it does not depend on that.
                  url.scheme?.lowercased() == "https"
            else { continue }
            // The token goes with these requests, so an API link has to be one
            // of this repository's own release assets. A release JSON naming
            // anywhere else would otherwise be sent the token.
            if case .api(let source) = link, !isAssetAPIURL(url, of: source) { continue }
            result[name] = url
        }
        return result
    }

    static func isAssetAPIURL(_ url: URL, of source: ExtensionSource) -> Bool {
        guard url.host?.lowercased() == "api.github.com", url.port == nil, url.query == nil,
              url.user == nil
        else { return false }
        let prefix = "/repos/\(source.owner)/\(source.repo)/releases/assets/".lowercased()
        let path = url.path.lowercased()
        guard path.hasPrefix(prefix) else { return false }
        let id = path.dropFirst(prefix.count)
        return !id.isEmpty && id.allSatisfy(\.isNumber)
    }

    static let indexAssetName = "extensions-index.json"

    // The app's catalogue lives on its own latest release. A release with no
    // index at all is an older one, which is an empty catalogue rather than an
    // error. An extra source's is read the same way, from its own release.
    static func catalogue(fromReleaseJSON data: Data,
                          via link: AssetLink = .browserDownload,
                          fetch: (URL) -> Data?) -> Result<[IndexEntry], Failure> {
        let published = assets(fromReleaseJSON: data, via: link)
        guard let indexURL = published[indexAssetName] else { return .success([]) }
        guard let indexData = fetch(indexURL) else {
            return .failure(.downloadFailed(indexAssetName))
        }
        return parseIndex(indexData)
    }

    // Every source's entries in one list, the app's own first, and what
    // couldn't be read. Built with an array literal it is a catalogue whose
    // sources all loaded, which is what every caller before extra sources
    // meant by one.
    struct Catalogue: Equatable, ExpressibleByArrayLiteral {
        // One per id, the first source's: what can be browsed and installed.
        var entries: [IndexEntry]
        // Every source's entries, an id another source took first included,
        // each stamped and capped like `entries`. What an installed
        // extension's tier is re-checked against: the listing from the source
        // it was installed from, which need not be the one `entries` kept.
        var listings: [IndexEntry]
        // Extra sources that failed, owner/repo -> why. The app's own failing
        // fails the whole fetch, as it always has.
        var unavailable: [String: String] = [:]
        // Entries in the sources setting that aren't owner/repo.
        var ignored: [String] = []

        init(entries: [IndexEntry], listings: [IndexEntry]? = nil,
             unavailable: [String: String] = [:], ignored: [String] = []) {
            self.entries = entries
            self.listings = listings ?? entries
            self.unavailable = unavailable
            self.ignored = ignored
        }

        init(arrayLiteral elements: IndexEntry...) {
            self.init(entries: elements)
        }
    }

    // The app's own entries, then each extra source's in the order the setting
    // lists them. An id is the directory it installs to, so the first source
    // to list one keeps it: an extra source can never stand in for one of the
    // app's own extensions, or for one an earlier source already lists. Each
    // extra entry is stamped with its source and its tier held to that source's
    // ceiling, so everything after this (the install confirmation, the
    // recorded tier, the grant) sees the capped tier and nothing else. An
    // entry whose id was taken is still kept in `listings`, for the tier
    // re-check of a copy installed from its source.
    static func merging(builtIn: [IndexEntry],
                        extra: [(source: ExtensionSource, result: Result<[IndexEntry], Failure>)])
        -> Catalogue {
        var catalogue = Catalogue(entries: builtIn)
        var taken = Set(builtIn.map(\.id))
        for (source, result) in extra {
            switch result {
            case .failure(let failure):
                catalogue.unavailable[source.slug] = failure.message
            case .success(let entries):
                for var entry in entries {
                    entry.source = source.slug
                    entry.tier = min(entry.reviewedTier, source.ceiling).rawValue
                    catalogue.listings.append(entry)
                    if taken.insert(entry.id).inserted { catalogue.entries.append(entry) }
                }
            }
        }
        return catalogue
    }

    static func fetchCatalogue(config: [String: String] = ConfigFile.read()) -> Result<Catalogue, Failure> {
        guard let release = releaseJSON() else { return .failure(.catalogueUnavailable) }
        let builtIn: [IndexEntry]
        switch catalogue(fromReleaseJSON: release, fetch: httpGET) {
        case .success(let entries): builtIn = entries
        case .failure(let failure): return .failure(failure)
        }
        let configured = ExtensionSource.configured(config)
        let tokens = configured.sources.isEmpty ? [] : githubTokens()
        let extra = configured.sources.map { source in
            (source: source, result: sourceCatalogue(source, tokens: tokens))
        }
        var merged = merging(builtIn: builtIn, extra: extra)
        merged.ignored = configured.ignored
        return .success(merged)
    }

    // Where to download an entry from: its own source's release, never
    // another's, since the entry's asset names mean something only there.
    static func releaseSources(for entry: IndexEntry) -> Sources {
        guard let slug = entry.source else { return releaseSources() }
        guard let source = ExtensionSource(slug: slug) else {
            return Sources(assets: [:], fetch: { _ in nil })
        }
        let tokens = githubTokens()
        guard let (release, token) = sourceReleaseJSON(source, tokens: tokens) else {
            return Sources(assets: [:], fetch: { _ in nil })
        }
        return Sources(assets: assets(fromReleaseJSON: release, via: .api(source)),
                       fetch: { assetGET($0, token: token) })
    }

    static func releaseSources() -> Sources {
        Sources(assets: releaseJSON().map { assets(fromReleaseJSON: $0) } ?? [:], fetch: httpGET)
    }

    // MARK: - Extra sources

    static func sourceCatalogue(_ source: ExtensionSource, tokens: [String]) -> Result<[IndexEntry], Failure> {
        guard let (release, token) = sourceReleaseJSON(source, tokens: tokens) else {
            return .failure(.sourceUnavailable(source.slug, signedIn: !tokens.isEmpty))
        }
        return catalogue(fromReleaseJSON: release, via: .api(source),
                         fetch: { assetGET($0, token: token) })
    }

    static func sourceReleaseURL(_ source: ExtensionSource) -> URL? {
        URL(string: "https://api.github.com/repos/\(source.owner)/\(source.repo)/releases/latest")
    }

    // The source's latest release, and the token that read it, which is the
    // one its assets are then fetched with. Each token in turn, then none: a
    // public source needs no token, and a private one answers 404 to a token
    // that can't see it, so the next one gets its chance.
    static func sourceReleaseJSON(_ source: ExtensionSource, tokens: [String],
                                  get: (URL, String?) -> Data? = { apiGET($0, token: $1) })
        -> (release: Data, token: String?)? {
        guard let url = sourceReleaseURL(source) else { return nil }
        for token in tokens.map(Optional.some) + [nil] {
            if let data = get(url, token) { return (data, token) }
        }
        return nil
    }

    // The tokens a private source can be read with: the one stack-nudge's own
    // GitHub sign-in holds, then the gh CLI's, without repeats. Read only when
    // the config names an extra source, so a Mac without one never touches
    // either.
    static func githubTokens(signIn: () -> String? = GitHubAuth.token,
                             gh: () -> String? = ghToken) -> [String] {
        var tokens: [String] = []
        for token in [signIn(), gh()].compactMap({ $0 }) where !tokens.contains(token) {
            tokens.append(token)
        }
        return tokens
    }

    static func ghToken() -> String? {
        guard let gh = ProcessOutput.gh(),
              let output = ProcessOutput.read(gh, ["auth", "token"], timeout: 10)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty, !output.contains(where: \.isWhitespace)
        else { return nil }
        return output
    }

    // The anonymous GitHub API is rate-limited per IP — sixty an hour, shared
    // with everything else on the machine — so a 403 here is ordinary rather
    // than exceptional, and it has nothing to do with the release being absent.
    // UpdateChecker already falls back to the local gh CLI for this; without the
    // same fallback the browser reports "couldn't download the release list" to
    // somebody whose network is fine.
    //
    // Only the API call needs it. The assets themselves are served from a
    // different host and are not rate-limited this way.
    static func releaseJSON(http: (URL) -> Data? = httpGET,
                            gh: (String) -> Data? = ghAPI) -> Data? {
        if let data = http(UpdateChecker.latestReleaseURL) { return data }
        return gh(UpdateChecker.latestGHPath)
    }

    static func ghAPI(_ path: String) -> Data? {
        guard let gh = ProcessOutput.gh() else { return nil }
        guard let output = ProcessOutput.read(gh, ["api", path], timeout: 20),
              !output.isEmpty
        else { return nil }
        return output.data(using: .utf8)
    }

    // Its own session rather than URLSession.shared, so the *resource* timeout
    // is ours: URLRequest.timeoutInterval is an idle timeout, and a response
    // that trickles a byte at a time never trips it. shared's resource timeout
    // is seven days.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    // A private release asset answers the API with a redirect to a signed
    // storage URL on another host. The token must not follow it there: the
    // storage host has no use for it, and a request carrying both its own
    // signature and a token is refused. A redirect off https is refused
    // outright.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(ExtensionInstaller.redirect(request, from: task.originalRequest?.url))
        }
    }

    static func redirect(_ request: URLRequest, from original: URL?) -> URLRequest? {
        guard request.url?.scheme?.lowercased() == "https" else { return nil }
        guard request.value(forHTTPHeaderField: "Authorization") != nil,
              request.url?.host?.lowercased() != original?.host?.lowercased()
        else { return request }
        var stripped = request
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        return stripped
    }

    // Synchronous, because every caller is already on a background queue. The
    // wait has no deadline of its own on purpose: an abandoning wait returns
    // while the task is still running, so the completion writes the captured
    // result after the reader has read it — a data race, and one that leaves
    // the download running while the user is told it failed. The session's
    // resource timeout is what bounds this now, so the completion always fires
    // and always fires before the wait returns.
    private static func httpGET(_ url: URL) -> Data? {
        get(url, token: nil, accept: "application/vnd.github+json")
    }

    // The GitHub API, with a token when there is one.
    static func apiGET(_ url: URL, token: String?) -> Data? {
        get(url, token: token, accept: "application/vnd.github+json")
    }

    // An extra source's release asset, through the API: octet-stream is what
    // makes GitHub send the file rather than a description of it.
    static func assetGET(_ url: URL, token: String?) -> Data? {
        get(url, token: token, accept: "application/octet-stream")
    }

    private static func get(_ url: URL, token: String?, accept: String) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("stack-nudge", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                payload = data
            }
            done.signal()
        }
        task.resume()
        done.wait()
        return payload
    }

    // MARK: - The real side effects

    // Both listings come from stdout. That matters more than it looks: the
    // symlink and hard-link guard reads the verbose listing, ProcessOutput
    // discards stderr, and if tar wrote its listing there instead the guard
    // would be a silent no-op with nothing failing.
    static func tarListing(_ archive: String) -> (plain: String, verbose: String)? {
        guard let plain = ProcessOutput.read("/usr/bin/tar", ["-tzf", archive], timeout: 20),
              let verbose = ProcessOutput.read("/usr/bin/tar", ["-tvzf", archive], timeout: 20)
        else { return nil }
        return (plain, verbose)
    }

    static func untar(_ archive: String, into directory: String) -> Bool {
        ProcessOutput.run("/usr/bin/tar", ["-xzf", archive, "-C", directory],
                          timeout: 60)?.status == 0
    }

    private static func stripQuarantine(_ path: String) {
        // Exit status ignored deliberately: xattr reports success even when the
        // attribute was never set, and its absence is not a failure to install.
        _ = ProcessOutput.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", path],
                              timeout: 20)
    }

    // Looked up and run with the environment an extension gets, not the app's
    // own: see ExtensionRuntime.searchPath.
    //
    // One that doesn't answer `--version` within `timeout` won't run either.
    // The likely cause is a first run stuck after an Xcode update, which is
    // what that message points at, and the catalogue checks again next load.
    static func checkRequirement(_ name: String,
                                 environment: [String: String] = ExtensionRuntime.probeEnvironment(),
                                 timeout: TimeInterval = 5,
                                 stubDirectory: String = "/usr/bin",
                                 developerToolsInstalled: () -> Bool = ExtensionInstaller.developerToolsInstalled)
        -> RequirementCheck {
        // Only a bare name, never a path: `requires` comes from a manifest and
        // this ends up as an executable.
        guard name.range(of: "^[A-Za-z0-9._+-]{1,32}$", options: .regularExpression) != nil
        else { return .missing }
        // A path, or it isn't a program: `command -v echo` answers "echo", a
        // shell builtin, which no extension can run as its interpreter.
        guard let resolved = ProcessOutput.read("/bin/sh", ["-c", "command -v \(name)"],
                                                timeout: 5, env: environment)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            resolved.hasPrefix("/")
        else { return .missing }
        let completion = ProcessOutput.run(resolved, ["--version"], timeout: timeout, env: environment)
        if completion?.status == 0 { return .works }
        // Without the Command Line Tools, /usr/bin/python3 and swiftc are
        // stubs that only offer to install them. That is missing, not broken:
        // "Needs swiftc" is the true answer there, and "won't run" would send
        // someone looking for an Xcode install they never had.
        if (resolved as NSString).deletingLastPathComponent == stubDirectory, !developerToolsInstalled() {
            return .missing
        }
        return .wontRun(path: resolved)
    }

    // Whether a developer directory is selected at all, which is what the
    // /usr/bin stubs need to run anything.
    static func developerToolsInstalled() -> Bool {
        ProcessOutput.run("/usr/bin/xcode-select", ["-p"], timeout: 5)?.status == 0
    }
}
