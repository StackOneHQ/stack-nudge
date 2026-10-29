import SwiftUI

// The states every skin draws. CompanionMode maps what the app knows onto
// this, so skin art stays independent of the app model.
enum SkinMode: CaseIterable {
    case idle, polling, thinking, pending, alert, error, sleeping, muted

    var label: String {
        switch self {
        case .idle:     return "Idle"
        case .polling:  return "Polling"
        case .thinking: return "Thinking"
        case .pending:  return "Pending"
        case .alert:    return "Alert"
        case .error:    return "Error"
        case .sleeping: return "Sleeping"
        case .muted:    return "Muted"
        }
    }
}
