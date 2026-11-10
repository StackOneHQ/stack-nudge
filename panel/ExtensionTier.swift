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
// gave each extension (extensions/tiers.json in the repo), and is written here
// when an extension is installed from it. Every later index fetch re-checks
// it: the record can go down to what the index now says, never up, and an
// extension the index no longer lists drops to `view`. A promotion takes an
// install or an update, so the package the user has is the one reviewed for
// it. Anything missing from the file is `view`, which is also what an
// extension put on disk by hand gets.
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
        let object = tiers.mapValues(\.rawValue)
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

    // A fresh index, re-checked against what's recorded. Each recorded tier
    // goes down to the index's if the index now says less, and to `view` if
    // the index no longer lists the extension at all. Nothing goes up: the
    // installed copy may be an older version than the one the index now
    // vouches for.
    static func reconciling(_ tiers: [String: ExtensionTier],
                            with index: [ExtensionInstaller.IndexEntry]) -> [String: ExtensionTier] {
        let listed = Dictionary(index.map { ($0.id, $0.reviewedTier) },
                                uniquingKeysWith: { first, _ in first })
        return tiers.reduce(into: [:]) { result, pair in
            result[pair.key] = min(pair.value, listed[pair.key] ?? .view)
        }
    }

    // An extension that's removed has no tier to keep. Reinstalling records
    // it afresh from the index.
    static func forgetting(_ id: String, in tiers: [String: ExtensionTier]) -> [String: ExtensionTier] {
        var tiers = tiers
        tiers[id] = nil
        return tiers
    }

    // MARK: - On the file

    static func record(_ entry: ExtensionInstaller.IndexEntry, path: String = ExtensionTiers.path) {
        write(recording(entry, in: read(path: path)), path: path)
    }

    // True when anything changed, so the caller knows to restart what runs
    // with a grant it no longer has.
    @discardableResult
    static func reconcile(with index: [ExtensionInstaller.IndexEntry],
                          path: String = ExtensionTiers.path,
                          config: [String: String] = ConfigFile.read()) -> Bool {
        guard indexReconciles(config: config) else { return false }
        let recorded = read(path: path)
        let next = reconciling(recorded, with: index)
        guard next != recorded else { return false }
        write(next, path: path)
        return true
    }

    static func forget(_ id: String, path: String = ExtensionTiers.path) {
        let recorded = read(path: path)
        guard recorded[id] != nil else { return }
        write(forgetting(id, in: recorded), path: path)
    }
}
