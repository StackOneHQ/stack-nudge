import XCTest

@testable import StackNudgePanelCore

// Extensions offering tools and event types to MCP clients: the manifest's
// mcp block, the line protocol, and the host routing calls and events.
final class ExtensionMCPManifestTests: XCTestCase {

    private func parse(_ mcp: String) -> Result<ExtensionManifest, ExtensionManifest.ParseFailure> {
        ExtensionManifest.parse(Data("""
            {"id":"pylon","name":"Pylon","version":"1","schema":2,"mode":"service","capabilities":["mcp"],"mcp":\(mcp)}
            """.utf8))
    }

    func testAValidBlockIsRead() throws {
        let manifest = try parse("""
            {"tools":[{"name":"open_issues","description":"Issues waiting on a reply.",
                       "inputSchema":{"type":"object","properties":{"limit":{"type":"integer"}}}}],
             "events":[{"name":"sla_breach","description":"An issue is about to breach its SLA.",
                        "filters":{"team":"Only this team."},
                        "payloadSchema":{"type":"object","properties":{"issue":{"type":"string"}}}}]}
            """).get()
        XCTAssertEqual(manifest.mcp.tools.map(\.name), ["open_issues"])
        XCTAssertEqual(manifest.mcp.events.first?.filters, ["team": "Only this team."])
        XCTAssertTrue(manifest.capabilities.contains(.mcp))
        let tool = manifest.mcp.toolsJSON(owner: "pylon", name: "Pylon").first
        XCTAssertEqual(tool?["name"] as? String, "pylon.open_issues")
        XCTAssertEqual(manifest.mcp.eventTypes(owner: "pylon").first?.name, "pylon.sla_breach")
    }

    func testNoBlockIsEmpty() throws {
        let manifest = try ExtensionManifest.parse(Data("""
            {"id":"pylon","name":"Pylon","version":"1","schema":1}
            """.utf8)).get()
        XCTAssertTrue(manifest.mcp.isEmpty)
    }

    func testABadBlockIsRefusedWithWhy() {
        let cases = [
            #"[]"#,
            #"{"tools":[{"name":"Open","description":"d"}]}"#,
            #"{"tools":[{"name":"open","description":""}]}"#,
            #"{"tools":[{"name":"open","description":"d","inputSchema":{"type":"string"}}]}"#,
            #"{"tools":[{"name":"open","description":"d"},{"name":"open","description":"d"}]}"#,
            #"{"events":[{"name":"x","description":"d","filters":{"team":3}}]}"#,
        ]
        for mcp in cases {
            guard case .failure(.invalidMCP) = parse(mcp) else { return XCTFail("accepted \(mcp)") }
        }
        let many = (0...ExtensionMCP.maxEach).map { #"{"name":"t\#($0)","description":"d"}"# }.joined(separator: ",")
        guard case .failure(.invalidMCP) = parse(#"{"tools":[\#(many)]}"#) else { return XCTFail("too many") }
    }

    func testOfferingToMCPIsForServicesAndAbove() {
        XCTAssertFalse(ExtensionTier.view.allows(.mcp))
        XCTAssertTrue(ExtensionTier.service.allows(.mcp))
        XCTAssertTrue(ExtensionTier.service.allows(.eventSettings))
        XCTAssertEqual(ExtensionCapability.event("settings"), .eventSettings)
    }
}

final class ExtensionMCPProtocolTests: XCTestCase {

    func testACallCarriesTheArgumentsAndTheCaller() throws {
        let line = ServiceProtocol.encode(.mcpCall(id: 4, tool: "open_issues", arguments: Data(#"{"limit":5}"#.utf8),
                                                   caller: ["client": .string("Claude Code"), "pid": .int(42)]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "mcp.call")
        XCTAssertEqual((object["arguments"] as? [String: Any])?["limit"] as? Int, 5)
        XCTAssertEqual((object["caller"] as? [String: Any])?["pid"] as? Int, 42)
        XCTAssertEqual(line.last, 0x0A)
    }

    func testResultsAndEventsAreDecodedAndCheckedForShape() {
        XCTAssertEqual(ServiceProtocol.decode(Data(#"{"type":"mcp.result","id":4,"result":"3 open"}"#.utf8)),
                       .message(.mcpResult(id: 4, result: Data(#""3 open""#.utf8), isError: false)))
        if case .message(.mcpResult(_, _, let isError)) = ServiceProtocol.decode(
            Data(#"{"type":"mcp.result","id":4,"result":{"n":3},"isError":true}"#.utf8)) {
            XCTAssertTrue(isError)
        } else { XCTFail("an object result") }
        if case .invalid = ServiceProtocol.decode(Data(#"{"type":"mcp.result","id":4,"result":3}"#.utf8)) {} else {
            XCTFail("a bare number isn't a result")
        }
        if case .message(.mcpEvent(let name, _, let eventID)) = ServiceProtocol.decode(
            Data(#"{"type":"mcp.event","name":"sla_breach","data":{"issue":"P-1"},"eventId":"e-1"}"#.utf8)) {
            XCTAssertEqual(name, "sla_breach")
            XCTAssertEqual(eventID, "e-1")
        } else { XCTFail("an event") }
        if case .invalid = ServiceProtocol.decode(Data(#"{"type":"mcp.event","name":"Bad Name","data":{}}"#.utf8)) {} else {
            XCTFail("a bad name")
        }
        if case .invalid = ServiceProtocol.decode(Data(#"{"type":"mcp.event","name":"x","data":"no"}"#.utf8)) {} else {
            XCTFail("data must be an object")
        }
    }
}

@MainActor
final class ExtensionHostMCPTests: XCTestCase {

    private var spawner = FakeSpawner()
    private var clock = FakeScheduler()
    private var tiers: [String: ExtensionTier] = ["pylon": .service]

    private func manifest(capabilities: [String] = ["mcp"]) -> ExtensionManifest {
        let list = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        guard case .success(let m) = ExtensionManifest.parse(Data("""
            {"id":"pylon","name":"Pylon","version":"1","schema":2,"mode":"service","capabilities":[\(list)],
             "mcp":{"tools":[{"name":"open_issues","description":"Open issues."}],
                    "events":[{"name":"sla_breach","description":"SLA about to breach."}]}}
            """.utf8)) else { fatalError("fixture manifest didn't parse") }
        return m
    }

    private func host() -> ExtensionHost {
        ExtensionHost(background: { $0() }, toMain: { $0() },
                      runner: { _, _, _ in .transient("stub") },
                      tiers: { [unowned self] in self.tiers },
                      makeSupervisor: { [unowned self] manifest, granted, onEvent in
                          ServiceSupervisor.fake(id: manifest.id, granted: granted,
                                                 spawner: self.spawner, scheduler: self.clock, onEvent: onEvent)
                      },
                      writeLog: { _ in })
    }

    func testToolsAreOfferedOnlyWhileTheServiceRuns() {
        let host = host()
        var changes = 0
        host.onMCPChanged = { changes += 1 }
        host.load(.init(installed: [manifest()]))
        XCTAssertTrue(host.mcpContributions.isEmpty, "not running yet")
        spawner.last.ready()
        XCTAssertEqual(host.mcpContributions.map(\.id), ["pylon"])
        XCTAssertGreaterThan(changes, 0)
    }

    func testWithoutTheCapabilityNothingIsOffered() {
        let host = host()
        host.load(.init(installed: [manifest(capabilities: [])]))
        spawner.last.ready()
        XCTAssertTrue(host.mcpContributions.isEmpty)
    }

    // The call reaches the extension with the caller as stack-nudge saw it,
    // and its answer comes back as the tool result.
    func testACallIsRoutedAndAnswered() {
        let host = host()
        host.load(.init(installed: [manifest()]))
        spawner.last.ready()
        var result: [String: Any]?
        host.callMCPTool("pylon.open_issues", arguments: ["limit": 5],
                         caller: ["client": .string("Claude Code")]) { result = $0 }
        let call = spawner.last.messages.last { $0["type"] as? String == "mcp.call" }
        XCTAssertEqual(call?["tool"] as? String, "open_issues")
        XCTAssertEqual((call?["caller"] as? [String: Any])?["client"] as? String, "Claude Code")
        let id = call?["id"] as? Int ?? -1
        spawner.last.say(#"{"type":"mcp.result","id":\#(id),"result":"3 open"}"#)
        XCTAssertEqual(((result?["content"] as? [[String: Any]])?.first)?["text"] as? String, "3 open")
        XCTAssertEqual(result?["isError"] as? Bool, false)
    }

    func testAnUnknownToolIsNoneOfTheHostsBusiness() {
        let host = host()
        host.load(.init(installed: [manifest()]))
        spawner.last.ready()
        var answered = false
        var result: [String: Any]? = ["unset": true]
        host.callMCPTool("pylon.nope", arguments: [:], caller: [:]) { result = $0; answered = true }
        XCTAssertTrue(answered)
        XCTAssertNil(result)
    }

    func testOnlyDeclaredEventsArePassedOn() {
        let host = host()
        var emitted: [String] = []
        host.onMCPEvent = { name, _, _ in emitted.append(name) }
        host.load(.init(installed: [manifest()]))
        spawner.last.ready()
        spawner.last.say(#"{"type":"mcp.event","name":"sla_breach","data":{"issue":"P-1"}}"#)
        spawner.last.say(#"{"type":"mcp.event","name":"undeclared","data":{}}"#)
        XCTAssertEqual(emitted, ["pylon.sla_breach"])
    }

    // Settings changes reach only the extensions granted event:settings.
    func testASettingsChangeReachesOnlyThoseGrantedIt() {
        let host = host()
        host.load(.init(installed: [manifest(capabilities: ["mcp", "event:settings"])]))
        spawner.last.ready()
        host.broadcast(event: "settings", fields: ["key": .string("STACKNUDGE_VOICE"), "value": .string("Off")])
        XCTAssertEqual(spawner.last.messages.last?["name"] as? String, "settings")

        let other = self.host()
        other.load(.init(installed: [manifest()]))
        spawner.last.ready()
        other.broadcast(event: "settings", fields: ["key": .string("STACKNUDGE_VOICE")])
        XCTAssertNotEqual(spawner.last.messages.last?["name"] as? String, "settings")
    }
}
