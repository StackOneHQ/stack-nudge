import XCTest

@testable import StackNudgePanelCore

// Settings → MCP → Set up for…: what each client's setup copies, and whether
// its config already has stack-nudge.
final class MCPClientsTests: XCTestCase {

    private let binary = "/Users/me/Applications/StackNudge.app/Contents/MacOS/stack-nudge"

    func testEachSetupPointsAtTheAppsOwnBinary() {
        XCTAssertEqual(MCPClient.claudeCode.setup(binary: binary),
                       "claude mcp add --scope user stack-nudge -- \(binary) --mcp")
        XCTAssertEqual(MCPClient.codex.setup(binary: binary), "codex mcp add stack-nudge -- \(binary) --mcp")
        XCTAssertEqual(MCPClient.claudeDesktop.setup(binary: binary),
                       #""stack-nudge": {"command": "\#(binary)", "args": ["--mcp"]}"#)
    }

    // What Desktop gets pasted into its JSON has to stay JSON.
    func testDesktopsEntryParsesInsideMCPServers() throws {
        let entry = MCPClient.claudeDesktop.setup(binary: "/Users/a \"b\"/stack-nudge")
        let config = "{\"mcpServers\": {\(entry)}}"
        XCTAssertTrue(MCPClient.claudeDesktop.hasBridge(in: config))
    }

    func testAPathWithASpaceIsQuotedForTheShell() {
        XCTAssertEqual(MCPClient.codex.setup(binary: "/Apps/Stack Nudge/stack-nudge"),
                       "codex mcp add stack-nudge -- '/Apps/Stack Nudge/stack-nudge' --mcp")
    }

    func testClaudeCodeIsFoundAtUserOrProjectScope() {
        let user = #"{"mcpServers": {"nudge": {"type": "stdio", "command": "\#(binary)", "args": ["--mcp"]}}}"#
        let project = #"{"projects": {"/r": {"mcpServers": {"stack-nudge": {"command": "\#(binary)", "args": ["--mcp"]}}}}}"#
        XCTAssertTrue(MCPClient.claudeCode.hasBridge(in: user), "found whatever it was named")
        XCTAssertTrue(MCPClient.claudeCode.hasBridge(in: project))
    }

    func testOtherServersAndTheAppWithoutTheFlagDontCount() {
        let other = #"{"mcpServers": {"x": {"command": "npx", "args": ["stack-nudge", "--mcp"]}}}"#
        let noFlag = #"{"mcpServers": {"x": {"command": "\#(binary)", "args": []}}}"#
        XCTAssertFalse(MCPClient.claudeDesktop.hasBridge(in: other))
        XCTAssertFalse(MCPClient.claudeDesktop.hasBridge(in: noFlag))
        XCTAssertFalse(MCPClient.claudeDesktop.hasBridge(in: "not json"))
    }

    func testCodexsTableIsFound() {
        let config = """
            model = "gpt-5"

            [mcp_servers.other]
            command = "npx"
            args = ["-y", "thing"]

            [mcp_servers.stack-nudge]
            command = "\(binary)"
            args = [
              "--mcp",
            ]
            """
        XCTAssertTrue(MCPClient.codex.hasBridge(in: config))
        XCTAssertFalse(MCPClient.codex.hasBridge(in: "[mcp_servers.other]\ncommand = \"npx\"\nargs = [\"--mcp\"]"))
        XCTAssertFalse(MCPClient.codex.hasBridge(in: "[profiles.x]\ncommand = \"\(binary)\"\nargs = [\"--mcp\"]"))
    }

    // Extra Claude config dirs and Codex homes count as much as the defaults.
    func testAClientIsTickedFromAnyOfItsConfigs() {
        let codexEntry = "[mcp_servers.n]\ncommand = \"\(binary)\"\nargs = [\"--mcp\"]"
        let files = ["/work/.claude/.claude.json": #"{"mcpServers": {"n": {"command": "\#(binary)", "args": ["--mcp"]}}}"#,
                     "/h/.codex/config.toml": codexEntry]
        let configured = MCPClient.configured(home: "/h", claudeDirs: ["/work/.claude"], codexHomes: [],
                                              read: { files[$0] })
        XCTAssertEqual(configured, [.claudeCode, .codex])
    }
}

// The MCP category and the page below it, reached and left as an integration
// page is.
@MainActor
final class MCPSettingsTests: XCTestCase {

    func testTheCategoryHoldsTheDoorAndTheWritesSwitch() {
        let nav = PanelNav()
        XCTAssertEqual(nav.rows(in: .mcp), [.mcpSetupClients, .mcpWrites])
        XCTAssertEqual(nav.rows(in: .mcpSetupPage), MCPClient.allCases.map { .mcpClient($0) })
        XCTAssertFalse(nav.rows(in: .actions).contains(.mcpWrites))
        XCTAssertEqual(SettingsCategory.allCases.firstIndex(of: .mcp),
                       SettingsCategory.allCases.firstIndex(of: .extensions).map { $0 + 1 })
    }

    func testThePageOpensFromItsRowAndGoesBackToIt() {
        let nav = PanelNav()
        nav.settingsCategory = .mcp
        nav.settingsDetailFocused = true
        nav.selectFirstCategoryRow()
        XCTAssertEqual(nav.selectedRow, .mcpSetupClients)
        XCTAssertTrue(nav.selectedRowOpensOnRight)
        nav.openMCPSetupPage()
        XCTAssertEqual(nav.settingsCategory, .mcpSetupPage)
        XCTAssertEqual(nav.sidebarCategory, .mcp, "MCP stays lit while its page is open")
        XCTAssertEqual(nav.settingsBackLabel, "MCP")
        nav.settingsBack()
        XCTAssertEqual(nav.settingsCategory, .mcp)
        XCTAssertEqual(nav.selectedRow, .mcpSetupClients)
    }

    func testTheWritesSwitchIsListedUnderMCP() {
        XCTAssertEqual(SettingsRegistry.spec("STACKNUDGE_MCP_WRITES")?.category, "mcp")
    }
}
