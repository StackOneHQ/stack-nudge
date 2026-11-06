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
// Nothing writes it yet. The design has the tier come from the extensions
// index and be recorded here at install time, and how the index carries it is
// still an open question (per repo or per extension), so for now the file is
// edited by hand and everything missing from it is `view`. An extension runs
// as the user and could edit this file too; like everything else here, that
// rests on review, not containment.
enum ExtensionTiers {

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
}
