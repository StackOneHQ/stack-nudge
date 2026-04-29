import Foundation
import SwiftUI

enum NudgeKind: String {
    case stop
    case permission
    case other

    init(rawWireValue: String) {
        self = NudgeKind(rawValue: rawWireValue) ?? .other
    }
}

struct NudgeEvent: Identifiable, Equatable {
    let id: UUID
    let agent: String
    let kind: NudgeKind
    let title: String
    let message: String
    let projectPath: String?
    let bundleID: String?
    let windowTitle: String?
    let ipcHook: String?
    let hasActionButton: Bool
    let timestamp: Date

    init(agent: String, kind: NudgeKind, title: String, message: String,
         projectPath: String? = nil, bundleID: String? = nil,
         windowTitle: String? = nil, ipcHook: String? = nil,
         hasActionButton: Bool = false, timestamp: Date = Date()) {
        self.id = UUID()
        self.agent = agent
        self.kind = kind
        self.title = title
        self.message = message
        self.projectPath = projectPath
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.ipcHook = ipcHook
        self.hasActionButton = hasActionButton
        self.timestamp = timestamp
    }
}

final class EventStore: ObservableObject {

    @Published private(set) var events: [NudgeEvent] = []
    @Published var selectedID: NudgeEvent.ID?

    private let maxEvents = 5

    func append(_ event: NudgeEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events = Array(events.prefix(maxEvents))
        }
        if selectedID != event.id { selectedID = event.id }
        if ProcessInfo.processInfo.environment["STACKNUDGE_PANEL_DEBUG"] != nil {
            FileHandle.standardError.write(Data(
                "panel: received \(event.agent)/\(event.kind.rawValue): \(event.message)\n".utf8))
        }
    }

    func remove(id: NudgeEvent.ID) {
        events.removeAll { $0.id == id }
        if selectedID == id { selectedID = events.first?.id }
    }

    func selectNext() {
        guard !events.isEmpty else { return }
        let idx = events.firstIndex { $0.id == selectedID } ?? 0
        selectedID = events[min(idx + 1, events.count - 1)].id
    }

    func selectPrevious() {
        guard !events.isEmpty else { return }
        let idx = events.firstIndex { $0.id == selectedID } ?? 0
        selectedID = events[max(idx - 1, 0)].id
    }

    var selectedEvent: NudgeEvent? {
        events.first { $0.id == selectedID }
    }
}
