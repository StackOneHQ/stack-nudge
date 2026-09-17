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
