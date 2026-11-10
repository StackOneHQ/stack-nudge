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
//
// Holding also survives a relaunch. Who holds what is recorded in a host-owned
// file, so which of two extensions gets a signal doesn't come down to which one
// happened to start first this time. The record is dropped only when the holder
// can no longer hold it at all (see `forgetHolders`), not when it is merely
// stopped for an update or a quit.
final class SignalRegistry {

    static let defaultPath = "\(ExtensionRuntime.root)/.signals.json"

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
    // Called when who holds a signal changes, for Settings to say where a
    // signal comes from.
    var onHoldersChange: () -> Void = {}

    // Where the holders are recorded. nil keeps them in memory only, which is
    // what tests use so they never touch the real file.
    private let path: String?

    init(path: String? = nil) {
        self.path = path
        holders = path.map(Self.readRecord) ?? [:]
    }

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
        if holders[signal] != id {
            holders[signal] = id
            writeRecord()
        }
        if case .heldByAnother(let name, _)? = refusals[id], name == signal.rawValue {
            refusals[id] = nil
        }
        return true
    }

    // Drops every recorded holder that `keep` says can no longer hold its
    // signal: removed, refused, or demoted out of the grant. Its value goes
    // back to neutral with it, and the signal is free to claim.
    func forgetHolders(except keep: (AppSignal, String) -> Bool) {
        let gone = holders.filter { !keep($0.key, $0.value) }
        guard !gone.isEmpty else { return }
        for (signal, id) in gone {
            update(signal, to: signal.neutral)
            holders[signal] = nil
            refusals[id] = nil
        }
        writeRecord()
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

    // The holder's process stopped: an update, a change of grant, a quit.
    // Neutral, but it stays the holder, so its replacement claims it back
    // rather than racing every other extension for it.
    func release(_ id: String) {
        reset(id)
        refusals[id] = nil
    }

    // MARK: - The record

    // {"presence": "desk-sensor"}: each signal and the id of the extension
    // holding it. Missing or unreadable reads as nobody holding
    // anything, which only means the next claim decides again.
    private static func readRecord(_ path: String) -> [AppSignal: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var holders: [AppSignal: String] = [:]
        for (name, value) in object {
            guard let signal = AppSignal(rawValue: name), let id = value as? String,
                  ExtensionManifest.isValidID(id) else { continue }
            holders[signal] = id
        }
        return holders
    }

    // Every change of holder goes through here, so it is also where the
    // change is announced.
    private func writeRecord() {
        onHoldersChange()
        guard let path else { return }
        let object = Dictionary(uniqueKeysWithValues: holders.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
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
