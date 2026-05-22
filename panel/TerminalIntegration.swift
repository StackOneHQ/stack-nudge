import Foundation

// Snapshot of one tab/pane/window the terminal-side integration knows
// about. Surface is intentionally narrow — anything terminal-specific
// (iTerm tab groups, VSCode workspace paths) gets squeezed into these
// three fields so the rest of the app doesn't need to branch per
// terminal. If a fourth field becomes load-bearing it earns its place;
// until then this stays small.
struct TabInfo: Equatable {
    let tabId: String
    let tabName: String?
    let windowTitle: String?
}

// Strategy for enriching a discovered Session with terminal-specific
// tab identity (tabId / tabName). Each conformer handles the terminals
// it understands and passes other sessions through unchanged. Why a
// batch shape (`[Session] -> [Session]`) instead of per-session
// `tabInfo(forProcessID:)`: terminals like iTerm2 and VSCode can
// resolve N sessions in one subprocess spawn, and we already saw
// what per-session shelling-out does to the main thread.
protocol TerminalIntegration {
    var name: String { get }

    // Called from SessionStore's background poll queue. Must not touch
    // SwiftUI / @Published state. Returns the same array with applicable
    // sessions enriched in place.
    func enrich(_ sessions: [Session]) -> [Session]
}

// Composes the registered integrations into a single pipeline.
// SessionStore.scan() calls TerminalRegistry.enrich(...) once per poll;
// each integration in `all` gets a chance to enrich the sessions it
// recognises. Order matters only when two integrations would claim the
// same session — keep specific (iTerm2) ahead of generic (Terminal.app)
// as more conformers land.
enum TerminalRegistry {

    // Mutable to support tests injecting a fake roster. Production
    // callers should treat it as read-only.
    static var integrations: [TerminalIntegration] = [
        ITerm2Integration.shared,
        TerminalAppIntegration.shared,
        VSCodeIntegration.shared,
        // Warp + Ghostty both set TERM_SESSION_ID in the agent's env;
        // a single generic conformer covers both terminals. Tab names
        // aren't accessible from outside today — could be layered in
        // via AX later. The terminalApp strings here match what
        // SessionStore.walkParentChain emits.
        EnvVarTerminalIntegration(
            name: "Warp",
            terminalApps: ["Warp", "WarpTerminal"],
            envVar: "TERM_SESSION_ID"
        ),
        EnvVarTerminalIntegration(
            name: "Ghostty",
            terminalApps: ["Ghostty", "ghostty"],
            envVar: "TERM_SESSION_ID"
        ),
    ]

    static func enrich(_ sessions: [Session]) -> [Session] {
        integrations.reduce(sessions) { acc, integration in
            integration.enrich(acc)
        }
    }
}
