import Foundation

// How far the app trusts an extension, which decides what it may be granted.
// The manifest says what an extension asks for; the tier says what it can
// have, and the grant is the overlap. See docs/design/service-extensions.md,
// "Privilege tiers".
//
// Ordered, so "service or higher" reads as a comparison.
enum ExtensionTier: String, Comparable, CaseIterable {
    case view, service, trusted

    static func < (lhs: ExtensionTier, rhs: ExtensionTier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    // Whether the host will run this extension's process as a service at all.
    // A view-tier extension asking for service mode is refused rather than
    // demoted to a view: its `run` was written to stay up and talk the line
    // protocol, so spawning it per fetch would only ever time out.
    var allowsServiceMode: Bool { self >= .service }

    // The allowance table. Written as a switch over every capability rather
    // than as cumulative sets, so adding a capability is a compile error here
    // until somebody decides which tier it belongs to.
    func allows(_ capability: ExtensionCapability) -> Bool {
        switch capability {
        case .eventIdle, .eventPanel, .feed:
            return self >= .service
        case .signalPresence, .eventSession, .eventNudge, .bluetooth:
            return self >= .trusted
        }
    }

    // Declared ∩ allowed, in the manifest's order. A view extension gets
    // nothing: nothing it could be given passes through a one-shot fetch.
    static func grants(for manifest: ExtensionManifest, tier: ExtensionTier) -> [ExtensionCapability] {
        guard manifest.mode == .service, tier.allowsServiceMode else { return [] }
        return manifest.capabilities.filter(tier.allows)
    }
}

// The host-owned record of each extension's tier: a JSON object mapping id to
// tier name, at ~/.stack-nudge/extensions/.tiers.json. The leading dot keeps it
// out of discovery, which skips anything that isn't a valid id.
//
// The tier comes from the extensions index, which carries what the reviewers
// gave each extension (extensions/tiers.json in its catalogue's repository,
// held to that catalogue's ceiling: see ExtensionSource), and is written here
// when an extension is installed from it. Every later index fetch re-checks
// it against the source it was installed from: the record can go down to what
// that source's index now says, never up, and an extension that source no
// longer lists drops to `view`, unless the source didn't answer. A promotion
// takes an install or an update, so the package the user has is the one
// reviewed for it. Anything missing from the file is `view`, which is also
// what an extension put on disk by hand gets.
//
// Which source that was is kept beside it, in .sources.json (id -> owner/repo,
// only for extensions from an extra source; none means the app's own). Another
// source listing the same id says nothing about the copy on disk, so it
// neither vouches for that copy's tier nor offers it an update.
//
// For developing and testing an extension that no release's index lists yet,
// STACKNUDGE_EXTENSIONS_LOCAL_TIERS=true in ~/.stack-nudge/config makes the
// file authoritative: index fetches never re-check it, so a tier written by
// hand stays. Installing from the index still records the index's tier.
//
// An extension runs as the user and could edit this file too, or that
// setting; like everything else here, that rests on review, not containment.
enum ExtensionTiers {

    static let localTiersKey = "STACKNUDGE_EXTENSIONS_LOCAL_TIERS"

    // Whether an index fetch gets to re-check the recorded tiers.
    static func indexReconciles(config: [String: String]) -> Bool {
        !ConfigFile.bool(config, localTiersKey, default: false)
    }

    static let path = "\(ExtensionRuntime.root)/.tiers.json"
    static let sourcesPath = sourcesPath(beside: path)

    // Always the tier file's neighbour, so the two can't be pointed apart.
    static func sourcesPath(beside tiersPath: String) -> String {
        "\((tiersPath as NSString).deletingLastPathComponent)/.sources.json"
    }

    // Missing, unreadable or malformed reads as empty, so every extension
    // falls back to `view`: the failure mode is fewer privileges, never more.
    // An entry naming a tier this host doesn't know is dropped the same way.
    static func read(path: String = ExtensionTiers.path,
                     fileManager: FileManager = .default) -> [String: ExtensionTier] {
        guard let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var tiers: [String: ExtensionTier] = [:]
        for (id, value) in object {
            guard ExtensionManifest.isValidID(id),
                  let name = value as? String, let tier = ExtensionTier(rawValue: name)
            else { continue }
            tiers[id] = tier
        }
        return tiers
    }

    static func write(_ tiers: [String: ExtensionTier], path: String = ExtensionTiers.path) {
        writeJSON(tiers.mapValues(\.rawValue), path: path)
    }

    // The extra source each extension came from. An entry that isn't a valid
    // id and owner/repo is dropped, which reads as the app's own: an extra
    // source's listing then no longer matches it, so the failure mode is
    // again fewer privileges.
    static func readSources(path: String = ExtensionTiers.sourcesPath,
                            fileManager: FileManager = .default) -> [String: String] {
        guard let data = fileManager.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var sources: [String: String] = [:]
        for (id, value) in object {
            guard ExtensionManifest.isValidID(id), let slug = value as? String,
                  ExtensionSource(slug: slug) != nil
            else { continue }
            sources[id] = slug
        }
        return sources
    }

    static func writeSources(_ sources: [String: String], path: String = ExtensionTiers.sourcesPath) {
        writeJSON(sources, path: path)
    }

    private static func writeJSON(_ object: [String: String], path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .prettyPrinted])
        else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Rules, without the file

    // Installing (or updating) from the index takes the index's tier as it
    // is, up or down: this is the package that was reviewed for it.
    static func recording(_ entry: ExtensionInstaller.IndexEntry,
                          in tiers: [String: ExtensionTier]) -> [String: ExtensionTier] {
        var tiers = tiers
        tiers[entry.id] = entry.reviewedTier
        return tiers
    }

    static func recordingSource(of entry: ExtensionInstaller.IndexEntry,
                                in sources: [String: String]) -> [String: String] {
        var sources = sources
        sources[entry.id] = entry.source
        return sources
    }

    // A fresh index, re-checked against what's recorded. Each recorded tier is
    // checked against the listing from the source it was installed from
    // (`sources`; none is the app's own): it goes down to that listing's tier
    // if it now says less, and to `view` if that source no longer lists it.
    // Nothing goes up: the installed copy may be an older version than the one
    // the index now vouches for.
    //
    // `unavailable` is the extra sources that didn't answer, as owner/repo.
    // An extension from one of those is missing from the index because its
    // source was out of reach, not because it was withdrawn, so it keeps its
    // tier until its source answers. Nothing else waits on them: one
    // unreachable source, a mistyped one included, holds up no other source's
    // withdrawals. The app's own never appears here, since its failing fails
    // the whole fetch.
    static func reconciling(_ tiers: [String: ExtensionTier],
                            installedFrom sources: [String: String] = [:],
                            with listings: [ExtensionInstaller.IndexEntry],
                            unavailable: Set<String> = []) -> [String: ExtensionTier] {
        tiers.reduce(into: [:]) { result, pair in
            let source = sources[pair.key]
            if let listing = listings.first(where: { $0.id == pair.key && ExtensionSource.same($0.source, source) }) {
                result[pair.key] = min(pair.value, listing.reviewedTier)
            } else if let source, unavailable.contains(where: { ExtensionSource.same($0, source) }) {
                result[pair.key] = pair.value
            } else {
                result[pair.key] = .view
            }
        }
    }

    // Whether installing `entry` would put one source's package over a copy
    // another source installed. Only the source a copy came from can update
    // it; anything else is a different extension that happens to share its id.
    static func installedFromElsewhere(_ entry: ExtensionInstaller.IndexEntry, isInstalled: Bool,
                                       sources: [String: String]) -> Bool {
        isInstalled && !ExtensionSource.same(entry.source, sources[entry.id])
    }

    // An extension that's removed has no tier to keep. Reinstalling records
    // it afresh from the index.
    static func forgetting(_ id: String, in tiers: [String: ExtensionTier]) -> [String: ExtensionTier] {
        var tiers = tiers
        tiers[id] = nil
        return tiers
    }

    // MARK: - On the file

    // Every read-and-rewrite of the two files goes through this. Installs of
    // different extensions run at once, and two rewrites racing would drop
    // one's record. A lost source is the worse loss: the copy then reads as
    // the app's own, falls to `view`, and is refused the update from its real
    // source that would have put it right.
    private static let fileLock = NSLock()

    static func record(_ entry: ExtensionInstaller.IndexEntry, path: String = ExtensionTiers.path) {
        fileLock.lock()
        defer { fileLock.unlock() }
        // The source first: a tier recorded without it would be read, until
        // the source caught up, as the app's own extension's.
        let sourcesPath = sourcesPath(beside: path)
        writeSources(recordingSource(of: entry, in: readSources(path: sourcesPath)), path: sourcesPath)
        write(recording(entry, in: read(path: path)), path: path)
    }

    // True when anything changed, so the caller knows to restart what runs
    // with a grant it no longer has.
    @discardableResult
    static func reconcile(with listings: [ExtensionInstaller.IndexEntry],
                          unavailable: Set<String> = [],
                          path: String = ExtensionTiers.path,
                          config: [String: String] = ConfigFile.read()) -> Bool {
        guard indexReconciles(config: config) else { return false }
        fileLock.lock()
        defer { fileLock.unlock() }
        let recorded = read(path: path)
        let next = reconciling(recorded, installedFrom: readSources(path: sourcesPath(beside: path)),
                               with: listings, unavailable: unavailable)
        guard next != recorded else { return false }
        write(next, path: path)
        return true
    }

    static func forget(_ id: String, path: String = ExtensionTiers.path) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let recorded = read(path: path)
        if recorded[id] != nil { write(forgetting(id, in: recorded), path: path) }
        let sourcesPath = sourcesPath(beside: path)
        var sources = readSources(path: sourcesPath)
        if sources.removeValue(forKey: id) != nil { writeSources(sources, path: sourcesPath) }
    }
}
