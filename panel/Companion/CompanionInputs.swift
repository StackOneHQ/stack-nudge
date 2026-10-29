import Foundation

// Values other parts of the app feed to the companion. Each defaults to doing
// nothing, so it works the moment something sets it, and nothing here polls
// or ticks. A new source of reactions adds its published value here and reads
// it into CompanionSignals in CompanionController.refreshModel. PanelNav owns
// the one instance (nav.companionInputs).
final class CompanionInputs: ObservableObject {
    // Bumped by the Debug menu's "Info (nod)"; the companion plays one nod per change.
    @Published var nodRequests = 0
}
