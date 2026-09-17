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
        let config: [String]
    }

    enum Failure: Error, Equatable {
        case malformedIndex(String)
        case unsupportedIndexSchema(Int)
        case invalidEntry(String)
        case sidecarMissing(String)
        case checksumMismatch(expected: String, actual: String)
        case unsafeArchive(String)
        case missingRequirement(String)
        case manifestRejected(String)
        case downloadFailed(String)
        case catalogueUnavailable
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
            case .manifestRejected(let why):   return "the package's manifest was refused — \(why)"
            case .downloadFailed(let what):    return "couldn't download \(what)"
            case .catalogueUnavailable:
                // Both paths failed. Anonymous GitHub is sixty requests an hour
                // per machine, so this is usually a wait rather than a fault.
                return "couldn't reach GitHub — it may be rate-limiting this "
                    + "machine, or be unreachable. Installing the gh CLI lets "
                    + "stack-nudge use your own quota."
            case .extractFailed(let why):      return "couldn't unpack the download — \(why)"
            case .installFailed(let why):      return "couldn't install — \(why)"
            }
        }
    }

    static let indexSchema = 1

    // MARK: - The index

    static func parseIndex(_ data: Data) -> Result<[IndexEntry], Failure> {
        struct Document: Decodable {
            let schema: Int
            let extensions: [IndexEntry]?
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
        let entries = document.extensions ?? []
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

    // Executed, not resolved. `command -v python3` succeeds on the Command Line
    // Tools stub and then fails the moment anything runs, which is precisely the
    // failure this check exists to catch before an extension is installed rather
    // than after its tab first opens.
    static func missingRequirement(
        in requires: [String],
        probe: (String) -> Bool = { ExtensionInstaller.interpreterWorks($0) }
    ) -> String? {
        requires.first { !probe($0) }
    }

    // MARK: - Installing

    // Where the index and the packages live: attached to the app's own release,
    // so there is one trust anchor and one fetch path rather than two.
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
                        probeRequirement: (String) -> Bool = interpreterWorks)
        -> Result<String, Failure> {

        guard ExtensionManifest.isValidID(entry.id) else {
            return .failure(.invalidEntry(entry.id))
        }
        if let missing = missingRequirement(in: entry.requires, probe: probeRequirement) {
            return .failure(.missingRequirement(missing))
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
        case .success:
            break
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

    // MARK: - Talking to the release

    // Asset name -> download URL, from the release JSON. Hand-parsed, because
    // this one is GitHub's format rather than ours — the same split the manifest
    // and the index already follow.
    static func assets(fromReleaseJSON data: Data) -> [String: URL] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = object["assets"] as? [[String: Any]]
        else { return [:] }
        var result: [String: URL] = [:]
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let raw = asset["browser_download_url"] as? String,
                  let url = URL(string: raw)
            else { continue }
            result[name] = url
        }
        return result
    }

    static let indexAssetName = "extensions-index.json"

    // The catalogue lives on the app's own latest release, so there is one trust
    // anchor and one fetch path rather than two. A release with no index at all
    // is an older one, which is an empty catalogue rather than an error.
    static func catalogue(fromReleaseJSON data: Data,
                          fetch: (URL) -> Data?) -> Result<[IndexEntry], Failure> {
        let published = assets(fromReleaseJSON: data)
        guard let indexURL = published[indexAssetName] else { return .success([]) }
        guard let indexData = fetch(indexURL) else {
            return .failure(.downloadFailed(indexAssetName))
        }
        return parseIndex(indexData)
    }

    static func fetchCatalogue() -> Result<[IndexEntry], Failure> {
        guard let release = releaseJSON() else { return .failure(.catalogueUnavailable) }
        return catalogue(fromReleaseJSON: release, fetch: httpGET)
    }

    static func releaseSources() -> Sources {
        Sources(assets: releaseJSON().map(assets(fromReleaseJSON:)) ?? [:], fetch: httpGET)
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
        return URLSession(configuration: configuration)
    }()

    // Synchronous, because every caller is already on a background queue. The
    // wait has no deadline of its own on purpose: an abandoning wait returns
    // while the task is still running, so the completion writes the captured
    // result after the reader has read it — a data race, and one that leaves
    // the download running while the user is told it failed. The session's
    // resource timeout is what bounds this now, so the completion always fires
    // and always fires before the wait returns.
    private static func httpGET(_ url: URL) -> Data? {
        var request = URLRequest(url: url)
        request.setValue("stack-nudge", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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

    static func interpreterWorks(_ name: String) -> Bool {
        // Only a bare name, never a path: `requires` comes from a manifest and
        // this ends up as an executable.
        guard name.range(of: "^[A-Za-z0-9._+-]{1,32}$", options: .regularExpression) != nil
        else { return false }
        guard let resolved = ProcessOutput.read("/usr/bin/env", ["sh", "-c", "command -v \(name)"],
                                                timeout: 5)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !resolved.isEmpty
        else { return false }
        let completion = ProcessOutput.run(resolved, ["--version"], timeout: 5)
        return completion?.status == 0
    }
}
