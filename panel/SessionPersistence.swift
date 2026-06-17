import Foundation
import SwiftUI

// Bridges the agent names emitted on the wire (notify.sh uses
// "claude-code", "cursor", "gemini", "codex") to the names the
// SessionStore observes from the process list ("claude", "gemini",
// "codex"). Without canonicalization, an event for "claude-code" would
// never match a session for "claude" and the events tab would lose its
// session label.
enum Agent {
    static func canonical(_ raw: String) -> String {
        switch raw {
        case "claude-code", "cursor":              return "claude"
        case "antigravity", "antigravity-cli":     return "agy"
        default:                                   return raw
        }
    }
}

// Per-session settings that survive app restarts. Today the only thing
// we keep is the user-chosen display name; `lastSeenAt` exists so a
// future cleanup pass can evict long-dormant entries without us needing
// to re-shape the file. We deliberately do NOT store an entry for every
// session we ever observe — only entries the user has explicitly named.
// That keeps the file small, sidesteps cleanup for v1, and means an
// un-renamed session has zero on-disk footprint.
struct SessionEntry: Codable {
    var customName: String
    var lastSeenAt: TimeInterval
}

// Disk-backed store of session names, keyed by "<agent>::<projectPath>".
// PID is intentionally not part of the key — pids churn on every shell
// restart, and the user's mental model is "this is the auth project",
// not "this is pid 12345". `terminalApp` is also out: notify.sh derives
// it from env vars, which are unreliable for non-standard shells; using
// it would silently break event-tab name resolution.
//
// Concurrency: all reads/writes happen on the main thread. SessionStore's
// background poll queue produces raw Sessions and hands them to merge()
// (which is dispatched to main) where the persistence lookup happens.
final class SessionPersistence: ObservableObject {

    static let shared = SessionPersistence()

    @Published private(set) var entries: [String: SessionEntry] = [:]

    private let url: URL
    // Tracks which keys have already had lastSeenAt bumped this launch,
    // so background polling can't trigger a disk write every 3 seconds
    // even for active renamed sessions.
    private var seenThisLaunch: Set<String> = []

    init(path: URL? = nil) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".stack-nudge", isDirectory: true)
        self.url = path ?? dir.appendingPathComponent("sessions.json", isDirectory: false)
        load()
    }

    // MARK: - Lookup

    // Resolves a custom name for (agent, projectPath[, tabId]). Lookup
    // first tries the most specific key (with tabId), then falls back to
    // the (agent, projectPath) form — so renames written before Stage 2
    // (no tabId) still apply to every tab in that project, and a
    // tab-scoped rename overrides the generic one when present.
    func customName(agent: String, projectPath: String?, tabId: String? = nil) -> String? {
        guard let projectPath else { return nil }
        let canon = Agent.canonical(agent)
        if let tabId, !tabId.isEmpty {
            if let trimmed = entries[Self.key(agent: canon, projectPath: projectPath, tabId: tabId)]?.customName,
               !trimmed.isEmpty {
                return trimmed
            }
        }
        let trimmed = entries[Self.key(agent: canon, projectPath: projectPath, tabId: nil)]?.customName
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Mutation

    // Sets (or clears, when `name` is nil/empty) the custom name keyed
    // by (agent, projectPath[, tabId]). When tabId is provided we write
    // the per-tab key — that lets two tabs in the same cwd carry
    // different names without disturbing each other. Clearing removes
    // only the most specific entry; a parent (agent, projectPath) entry
    // (if any) keeps working as the fallback.
    func setCustomName(agent: String, projectPath: String?, tabId: String? = nil, _ name: String?) {
        guard let projectPath else { return }
        let key = Self.key(agent: Agent.canonical(agent), projectPath: projectPath, tabId: tabId)
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            guard entries.removeValue(forKey: key) != nil else { return }
        } else {
            entries[key] = SessionEntry(
                customName: trimmed,
                lastSeenAt: Date().timeIntervalSince1970
            )
        }
        save()
    }

    // Bump lastSeenAt for an existing entry, but only on the first sight
    // per launch — that way the file is rewritten once per active named
    // session per app run, not every poll tick. No-op for sessions we
    // don't have an entry for; we don't track unrenamed sessions. We
    // bump the most specific key that exists so per-tab entries get
    // their own freshness signal independently of any parent entry.
    func noteSeen(agent: String, projectPath: String?, tabId: String? = nil) {
        guard let projectPath else { return }
        let canon = Agent.canonical(agent)
        let candidates: [String] = {
            if let tabId, !tabId.isEmpty {
                return [
                    Self.key(agent: canon, projectPath: projectPath, tabId: tabId),
                    Self.key(agent: canon, projectPath: projectPath, tabId: nil),
                ]
            }
            return [Self.key(agent: canon, projectPath: projectPath, tabId: nil)]
        }()
        for key in candidates {
            guard !seenThisLaunch.contains(key), entries[key] != nil else { continue }
            seenThisLaunch.insert(key)
            entries[key]?.lastSeenAt = Date().timeIntervalSince1970
            save()
            return
        }
    }

    // MARK: - I/O

    // Stable across PID churn and restarts; shared with PanelNav.mutedSessions.
    static func key(agent: String, projectPath: String, tabId: String?) -> String {
        let canon = Agent.canonical(agent)
        if let tabId, !tabId.isEmpty {
            return "\(canon)::\(projectPath)::\(tabId)"
        }
        return "\(canon)::\(projectPath)"
    }

    // nil when the session has no projectPath — no stable identity possible.
    static func key(for session: Session) -> String? {
        guard let path = session.projectPath, !path.isEmpty else { return nil }
        return key(agent: session.agent, projectPath: path, tabId: session.tabId)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return }
        do {
            entries = try JSONDecoder().decode([String: SessionEntry].self, from: data)
        } catch {
            // Don't crash — a malformed file shouldn't take down the app.
            // Logging is enough; the next setCustomName call will rewrite.
            FileHandle.standardError.write(Data(
                "stack-nudge: sessions.json decode failed (\(error)); starting fresh\n".utf8))
            entries = [:]
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            // `.atomic` writes to a sibling temp file and rename()s — so
            // a killed app can't leave a half-written JSON behind.
            try data.write(to: url, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "stack-nudge: sessions.json save failed (\(error))\n".utf8))
        }
    }
}

// Deterministic per-session color. Used as a left-edge accent on session
// cards and event rows so the eye can connect "this nudge" to "this
// session" without reading the project label. Swift's built-in String
// hashing is randomized per launch (a security feature), so we roll our
// own FNV-1a — same project → same color across restarts.
enum SessionColor {

    static let palette: [Color] = [
        .blue, .teal, .mint, .indigo, .purple, .pink,
    ]

    static func color(agent: String, projectPath: String?, tabId: String? = nil) -> Color? {
        guard let projectPath, !projectPath.isEmpty else { return nil }
        var key = "\(Agent.canonical(agent))::\(projectPath)"
        if let tabId, !tabId.isEmpty {
            // Mixing tabId into the hash gives two iTerm tabs in the same
            // cwd distinct accent colors. Sessions without a tabId still
            // hash to the same key they did pre-Stage-2 — no migration
            // shuffle for existing users.
            key += "::\(tabId)"
        }
        let idx = Int(fnv1a(key) % UInt32(palette.count))
        return palette[idx]
    }

    private static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }
}
