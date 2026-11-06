import Foundation

// A value an extension can set and the app reacts to. Defined by the app, not by
// extensions: the app owns the name, the values and what reacts, because a
// signal is how an extension changes what the app does. See
// docs/design/service-extensions.md, "Signals".
enum AppSignal: String, CaseIterable {
    case presence

    var allowedValues: [String] {
        switch self {
        case .presence: return ["present", "away"]
        }
    }

    // What the signal reads with nobody holding it, and what it falls back to
    // when its holder goes away. Always the value that makes the app do
    // nothing, so a dead extension can never leave the app locked or muted.
    var neutral: String {
        switch self {
        case .presence: return "present"
        }
    }

    // The grant an extension needs before it can hold this signal.
    var capability: ExtensionCapability {
        switch self {
        case .presence: return .signalPresence
        }
    }
}

// Who holds each signal and what it currently says. Main-thread only, like
// ExtensionHost, which owns it.
//
// One holder per signal. The first extension granted it keeps it; a second one
// asking is refused, and the reason is kept for Settings to show. Holding
// survives a crash and restart, so a flaky holder doesn't hand the signal to
// whichever extension restarts first, but its value doesn't: see `reset`.
final class SignalRegistry {

    enum Refusal: Error, Equatable {
        case unknownSignal(String)
        case unknownValue(signal: String, value: String)
        case heldByAnother(signal: String, holder: String)
        case notHolding(signal: String)

        var message: String {
            switch self {
            case .unknownSignal(let name):
                return "unknown signal \"\(name)\""
            case .unknownValue(let signal, let value):
                return "\"\(value)\" isn't a value of \(signal)"
            case .heldByAnother(let signal, let holder):
                return "\(signal) is held by \(holder)"
            case .notHolding(let signal):
                return "doesn't hold \(signal)"
            }
        }
    }

    private(set) var holders: [AppSignal: String] = [:]
    private var current: [AppSignal: String] = [:]
    // The latest refusal per extension, for Settings to show beside it.
    private(set) var refusals: [String: Refusal] = [:]

    // Called only when a value actually changes, so a reaction (a lock, a mute)
    // isn't repeated for an extension that says "away" every second.
    var onChange: (AppSignal, String) -> Void = { _, _ in }

    func value(_ signal: AppSignal) -> String { current[signal] ?? signal.neutral }

    var values: [AppSignal: String] {
        Dictionary(uniqueKeysWithValues: AppSignal.allCases.map { ($0, value($0)) })
    }

    // Asks to hold a signal. Idempotent for the holder, so a restart claiming
    // again is fine; refused for anybody else, with the reason recorded.
    @discardableResult
    func claim(_ signal: AppSignal, by id: String) -> Bool {
        if let holder = holders[signal], holder != id {
            refusals[id] = .heldByAnother(signal: signal.rawValue, holder: holder)
            return false
        }
        holders[signal] = id
        if case .heldByAnother(let name, _)? = refusals[id], name == signal.rawValue {
            refusals[id] = nil
        }
        return true
    }

    // A `signal` message from an extension. Names and values are checked against
    // the app's own table, and only the holder may set one. Returns why it was
    // refused, or nil when it was taken.
    @discardableResult
    func set(_ name: String, to value: String, from id: String) -> Refusal? {
        guard let signal = AppSignal(rawValue: name) else {
            return refuse(.unknownSignal(name), for: id)
        }
        guard signal.allowedValues.contains(value) else {
            return refuse(.unknownValue(signal: name, value: value), for: id)
        }
        guard holders[signal] == id else {
            return refuse(holders[signal].map { .heldByAnother(signal: name, holder: $0) }
                          ?? .notHolding(signal: name), for: id)
        }
        update(signal, to: value)
        return nil
    }

    // The holder crashed or is restarting: back to neutral, but it keeps the
    // signal, so what it says once it's back up still counts.
    func reset(_ id: String) {
        for (signal, holder) in holders where holder == id {
            update(signal, to: signal.neutral)
        }
    }

    // The holder stopped for good: it was disabled, removed, updated, or lost
    // the grant. Neutral, and the signal is free for the next one to claim.
    func release(_ id: String) {
        reset(id)
        holders = holders.filter { $0.value != id }
        refusals[id] = nil
    }

    private func refuse(_ refusal: Refusal, for id: String) -> Refusal? {
        refusals[id] = refusal
        return refusal
    }

    private func update(_ signal: AppSignal, to value: String) {
        guard self.value(signal) != value else { return }
        current[signal] = value
        onChange(signal, value)
    }
}
