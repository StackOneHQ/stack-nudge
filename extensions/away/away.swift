// Away: tells StackNudge when you've walked away from the Mac with your phone.
//
// A service extension (docs/design/service-extensions.md). It runs for as long
// as it's enabled, speaks the line protocol on stdin and stdout, and sets the
// app's `presence` signal to "away" or "present". It never locks the screen
// itself: the app does that when the signal changes, if the user asked for it,
// so turning locking off is an app setting and a crashed extension can't leave
// anything locked.
//
// How it decides. A paired phone advertises over Bluetooth LE under an
// identifier macOS keeps stable through the pairing, whether or not its screen
// is on, so a passive scan hears it without connecting to anything or
// installing anything on the phone. You count as away once the Mac has been
// idle for the configured time AND the phone hasn't been heard for the
// configured silence (two minutes unless set). Signal strength can't tell
// leaving from lying still: measured on a Galaxy S25+, an idle phone on the
// desk went 75 s between advertisements with readings as low as -99 dBm, no
// stronger than the last readings while walking out. So only a long silence
// counts.
//
// Built by ./run with `swiftc -O` on first start, so what a reviewer reads is
// what runs. stdout carries protocol lines and nothing else; anything for a
// human goes to stderr, which the host discards.

import AppKit
import CoreBluetooth
import CoreGraphics
import Foundation
import IOBluetooth

// MARK: - The rule

enum PresenceState: Equatable {
    case present
    case away
}

// The decision, as a value with no Bluetooth in it, so `--self-test` can drive
// it with timestamps. Away takes the phone being silent *and* the Mac being
// idle, so the screen never locks under someone who's typing.
struct PresenceTracker {
    struct Rule: Equatable {
        // No advertisement for this long means the phone is out of range.
        var missingAfter: TimeInterval = TimeInterval(AwayConfig.defaultSilence)
        // And nobody has touched the Mac for this long.
        var idleAtLeast: TimeInterval = TimeInterval(AwayConfig.defaultIdle)
        // A reading at least this strong brings you back.
        var backRSSI: Int = -80

        // The two config keys, independent of each other. The silence is
        // floored by AwayConfig at 90 s: an idle phone on the desk was measured
        // going 75 s without advertising, and a 20 s floor in the prototype
        // locked the screen under the user dozens of times a day.
        init(idle: TimeInterval, silence: TimeInterval) {
            idleAtLeast = idle
            missingAfter = silence
        }

        init() {}
    }

    var rule = Rule()
    private(set) var state: PresenceState = .present
    private(set) var lastSeen: Date?

    init(rule: Rule = Rule()) { self.rule = rule }

    // One advertisement from the phone.
    mutating func observe(rssi: Int, at now: Date) {
        // CoreBluetooth reports 127 when it has no reading.
        guard rssi < 0 else { return }
        lastSeen = now
        if state == .away && rssi >= rule.backRSSI { state = .present }
    }

    // A stretch in which silence says nothing about where the phone is: the
    // Mac asleep, or Bluetooth off. Away then needs the phone heard afresh,
    // rather than counting the gap as the phone having gone.
    mutating func forgetHeard() {
        lastSeen = nil
    }

    // Called on a timer. Input on the Mac always means you're there.
    @discardableResult
    mutating func evaluate(now: Date, idle: TimeInterval) -> PresenceState {
        if idle < rule.idleAtLeast {
            state = .present
            return state
        }
        guard state == .present else { return state }
        if let lastSeen, now.timeIntervalSince(lastSeen) >= rule.missingAfter {
            state = .away
            // After input brings you back, away needs the phone heard afresh.
            // Otherwise a phone left at home or switched off would lock the
            // screen after every pause.
            self.lastSeen = nil
        }
        return state
    }
}

// Notices that the Mac slept, from the clock jumping between ticks. A timer
// doesn't fire while the Mac is asleep, so the first tick after waking comes
// long after the one before. NSWorkspace's sleep notifications say the same
// thing when they reach this process; this is the check that doesn't depend
// on them.
struct SleepGap {
    // Ticks are a second apart; ten seconds between two is not a busy run loop.
    static let threshold: TimeInterval = 10
    private var lastTick: Date?

    mutating func slept(tickAt now: Date) -> Bool {
        defer { lastTick = now }
        guard let lastTick else { return false }
        return now.timeIntervalSince(lastTick) > Self.threshold
    }
}

// MARK: - Names

// Phone names are typed by people and printed by phones, so they're compared
// loosely: a curly apostrophe (what iOS and Android put in "Alex’s iPhone")
// matches a straight one, case doesn't matter, and surrounding space is
// ignored. Used for the configured name and the paired names alike.
enum PhoneName {
    static func normalised(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

// MARK: - Which device is the phone

// Decides which identifier is the phone, from the paired devices advertising
// the configured name. Pure, so the self-test can drive it.
//
// A name can be shared (two "iPhone"s, or a phone and a watch), and a phone
// might be bound to the wrong one of them. So when two identifiers with the
// name have both been heard within the silence window, it binds to neither,
// and Away never goes away until that's resolved. And when the bound one has
// gone silent for the whole window while exactly one other with the name is
// being heard, it moves to that one.
struct PhoneBinding {
    enum Status: Equatable {
        case notFound
        case bound(UUID)
        case ambiguous(count: Int)
    }

    private(set) var bound: UUID?
    private var heard: [UUID: Date] = [:]

    // An advertisement from a paired device carrying the configured name.
    mutating func observe(_ id: UUID, at now: Date) {
        heard[id] = now
    }

    mutating func resolve(now: Date, window: TimeInterval) -> Status {
        heard = heard.filter { now.timeIntervalSince($0.value) < window * 4 }
        let recent = heard.filter { now.timeIntervalSince($0.value) < window }.map(\.key)
        if recent.count > 1 { return .ambiguous(count: recent.count) }
        if let only = recent.first, only != bound {
            // Nothing bound yet, or the bound one has been silent for the whole
            // window while this one is heard.
            bound = only
        }
        return bound.map(Status.bound) ?? .notFound
    }
}

// MARK: - Configuration

struct AwayConfig: Equatable {
    static let phoneKey = "STACKNUDGE_EXT_AWAY_PHONE"
    static let idleKey = "STACKNUDGE_EXT_AWAY_IDLE"
    static let silenceKey = "STACKNUDGE_EXT_AWAY_SILENCE"
    static let defaultIdle = 30
    static let idleRange = 10...120
    static let defaultSilence = 120
    // Above the longest gap measured from an idle phone on a desk (75 s).
    static let silenceRange = 90...600

    // The phone's Bluetooth name, as Settings offers it. nil until set.
    var phone: String?
    var idleSeconds: Int = defaultIdle
    var silenceSeconds: Int = defaultSilence

    // The host omits a key that isn't set, so a missing key and an empty one
    // are the same thing here. A value that isn't a number falls back to the
    // default rather than to a bound, since it says nothing about intent.
    init(values: [String: String]) {
        let phone = values[Self.phoneKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phone = (phone?.isEmpty ?? true) ? nil : phone
        idleSeconds = Self.seconds(values[Self.idleKey], default: Self.defaultIdle, in: Self.idleRange)
        silenceSeconds = Self.seconds(values[Self.silenceKey], default: Self.defaultSilence,
                                      in: Self.silenceRange)
    }

    var rule: PresenceTracker.Rule {
        PresenceTracker.Rule(idle: TimeInterval(idleSeconds), silence: TimeInterval(silenceSeconds))
    }

    private static func seconds(_ raw: String?, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), let n = Int(raw) else { return fallback }
        return min(max(n, range.lowerBound), range.upperBound)
    }
}

// MARK: - Output

// One protocol line on stdout. Sorted keys so the same state prints the same
// bytes, which is what lets `publish` skip a document that hasn't changed.
enum Out {
    // The host's ceiling for anything but a document is 64 KB; a document may
    // be bigger, but this one never needs to be, so every line stays under it.
    static let maxLineBytes = 64 * 1024

    static func line(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    static func send(_ object: [String: Any]) {
        guard let data = line(object), data.count < maxLineBytes else {
            FileHandle.standardError.write(Data("away: dropped an oversized line\n".utf8))
            return
        }
        FileHandle.standardOutput.write(data)
    }
}

// MARK: - The tab

// A device the scan has heard from.
struct Nearby: Equatable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeen: Date
}

// Everything the tab shows, gathered so the document can be built (and
// tested) without a scan.
struct Snapshot {
    enum Phone: Equatable {
        case notChosen
        // The configured name isn't among the Mac's paired devices.
        case notPaired
        case notFound
        case ambiguous(count: Int)
        case bound
    }

    var config: AwayConfig
    var issue: String?
    var scanning: Bool
    var phone: Phone
    var state: PresenceState
    var rssi: Int?
    var heard: Date?
    var others: [Nearby]
    var now: Date
}

enum Tab {
    // "4 s", "3 min", "2 h". Signals arrive seconds apart, so seconds are
    // worth showing until they stop being readable.
    static func duration(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h"
    }

    // A real minus sign, which reads as a sign rather than a dash.
    static func dBm(_ rssi: Int) -> String {
        rssi < 0 ? "\u{2212}\(-rssi) dBm" : "\(rssi) dBm"
    }

    // The tab's document, schema 1.
    static func document(_ s: Snapshot) -> [String: Any] {
        let silence = s.config.silenceSeconds
        let ago = s.heard.map { max(0, Int(s.now.timeIntervalSince($0))) }
        let silent = ago.map { $0 > silence } ?? false

        let badge: (String, String)
        if let issue = s.issue {
            badge = (issue, "warning")
        } else {
            switch s.phone {
            case .notChosen:  badge = ("No phone chosen", "neutral")
            case .notPaired:  badge = ("Phone not paired", "warning")
            case .notFound:   badge = ("Looking for phone", "neutral")
            case .ambiguous:  badge = ("Rename your phone", "warning")
            case .bound:
                if s.state == .away { badge = ("Away", "warning") }
                else if silent || ago == nil { badge = ("Phone silent", "neutral") }
                else { badge = ("Present", "success") }
            }
        }
        let header: [String: Any] = [
            "title": "Away",
            "badge": ["text": badge.0, "tone": badge.1],
            "trailing": "idle \(Tab.duration(s.config.idleSeconds)) · silent \(Tab.duration(silence))",
        ]

        var rows: [[String: Any]] = []
        if let name = s.config.phone {
            var row: [String: Any] = ["id": "phone", "title": name, "subtitle": "Your phone"]
            switch s.phone {
            case .notChosen:
                break
            case .notPaired:
                row["value"] = "not paired"
                row["footnote"] = "Pair it in System Settings \u{2192} Bluetooth. Away can't "
                    + "recognise an unpaired phone, so it never locks."
            case .ambiguous(let count):
                row["value"] = "\(count) devices"
                row["footnote"] = "\(count) devices named \(name) nearby \u{2014} rename your phone "
                    + "so Away can tell which is yours. It won't lock until then."
            case .notFound:
                row["value"] = "not heard yet"
                row["footnote"] = "Paired, but not heard. Keep it nearby and unlocked for a moment."
            case .bound:
                if let ago, let rssi = s.rssi, !silent {
                    row["value"] = ago < 2 ? "\(Tab.dBm(rssi)) · just now"
                                           : "\(Tab.dBm(rssi)) · \(Tab.duration(ago)) ago"
                    row["footnote"] = "Its Bluetooth signal, not a connection: heard every few "
                        + "seconds in use, up to a minute or more lying idle."
                    row["track"] = ["fill": signalFill(rssi), "tint": "#7FD1B9"]
                } else if let ago {
                    row["value"] = "not heard for \(Tab.duration(ago))"
                    row["footnote"] = "Silent longer than \(Tab.duration(silence)), so it counts "
                        + "as gone while the Mac is idle."
                } else {
                    row["value"] = "not heard yet"
                    row["footnote"] = "Waiting to hear it again."
                }
            }
            rows.append(row)
        }
        // Strongest first, a dozen at most: enough to find your own phone in a
        // busy office, and a line that stays far under the host's limit.
        for device in s.others.sorted(by: { ($0.rssi, $0.name) > ($1.rssi, $1.name) }).prefix(12) {
            rows.append([
                "id": "device-\(device.id.uuidString)",
                "title": device.name,
                "subtitle": "Paired, nearby",
                "value": Tab.dBm(device.rssi),
                "footnote": "set Phone to this name to use it",
                "track": ["fill": signalFill(device.rssi), "tint": "#8A8A8A"],
            ])
        }

        var document: [String: Any] = ["schema": 1, "header": header, "rows": rows]
        if rows.isEmpty {
            document["state"] = "empty"
            document["message"] = s.issue != nil || !s.scanning
                ? "Bluetooth isn't scanning, so no devices can be listed."
                : "No paired devices heard yet. Keep your phone nearby and unlocked for a moment."
        }
        return document
    }

    // A bar from -100 dBm (empty) to -40 dBm (full). Only a rough picture:
    // readings swing by 15 dB lying still.
    static func signalFill(_ rssi: Int) -> Double {
        min(max(Double(rssi + 100) / 60, 0), 1)
    }
}

// MARK: - Choices

// What Settings offers for the Phone key: the paired devices heard lately,
// sent to the host as a `choices` message (the key is declared "dynamic").
// The value is the name exactly as it matched, so picking one saves a name
// that matches; the configured phone is always in the list, heard or not, so
// Settings can show what's set.
enum PhoneChoices {
    // The host's limits for a choices message: more options, a longer value
    // or label, or a value with a line break or control character in it, and
    // it refuses the whole message. So one odd device name is left out here
    // rather than costing every other choice.
    static let maxOptions = 64
    static let maxLength = 256
    // Room for " · −100 dBm" after the name, within maxLength.
    static let maxNameLength = maxLength - 16

    static func usable(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxNameLength,
              !trimmed.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
              })
        else { return nil }
        return trimmed
    }

    static func options(nearby: [Nearby], configured: String?) -> [[String: String]] {
        let configured = configured.flatMap(usable)
        let wanted = configured.map(PhoneName.normalised)
        // One entry per name, the strongest reading: a phone can show up under
        // a fresh identifier while the old one is still remembered.
        var strongest: [String: Nearby] = [:]
        for var device in nearby {
            guard let usableName = usable(device.name) else { continue }
            device = Nearby(id: device.id, name: usableName, rssi: device.rssi, lastSeen: device.lastSeen)
            let name = PhoneName.normalised(device.name)
            if let seen = strongest[name], seen.rssi >= device.rssi { continue }
            strongest[name] = device
        }
        var options: [[String: String]] = strongest.values
            .sorted { ($0.name.lowercased(), $0.id.uuidString) < ($1.name.lowercased(), $1.id.uuidString) }
            .map { device in
                // The configured spelling, when it's this device, so the saved
                // value is the one Settings finds selected.
                let isConfigured = PhoneName.normalised(device.name) == wanted
                let value = isConfigured ? (configured ?? device.name) : device.name
                return ["value": value, "label": "\(value) · \(Tab.dBm(device.rssi))"]
            }
        if let configured, !strongest.keys.contains(PhoneName.normalised(configured)) {
            options.insert(["value": configured, "label": "\(configured) · not heard"], at: 0)
        }
        return Array(options.prefix(maxOptions))
    }

    static func message(_ options: [[String: String]]) -> [String: Any] {
        ["type": "choices", "key": AwayConfig.phoneKey, "options": options]
    }
}

// MARK: - The scan

// Owns the CoreBluetooth scan, the tracker and everything the tab shows.
// Main-thread only: the central manager delivers on the main queue, and stdin
// lines are hopped there before they reach this.
final class Away: NSObject, CBCentralManagerDelegate {

    private var config = AwayConfig(values: [:])
    private var mayHoldPresence = false
    private var central: CBCentralManager?
    private var tracker = PresenceTracker(rule: AwayConfig(values: [:]).rule)
    private var binding = PhoneBinding()
    private var phone: Snapshot.Phone = .notChosen
    private var sleepGap = SleepGap()
    private var targetRSSI: Int?
    private var targetHeard: Date?
    private var nearby: [UUID: Nearby] = [:]
    // Normalised, as PhoneName compares them.
    private var pairedNames: Set<String> = []
    private var pairedNamesAt = Date.distantPast
    private var bluetoothIssue: String?
    private var reported: PresenceState?
    private var lastDocument: Data?
    private var lastDocumentAt = Date.distantPast
    private var timer: Timer?
    private var offered: [[String: String]]?
    private var offeredAt = Date.distantPast
    // Nothing goes to stdout before `ready`: the host reads the first line as
    // the answer to its hello.
    private var ready = false

    // `hello`. Starting the scan is what asks for Bluetooth permission, so
    // nothing touches CoreBluetooth before the host has said hello.
    func start(granted: [String], values: [String: String]) {
        mayHoldPresence = granted.contains("signal:presence")
        configure(values)
        ready = true
        Out.send(["type": "ready", "protocol": 1])
        report(.present)
        central = CBCentralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // The clock-gap check catches a sleep whether or not these arrive.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.forgetHeard(because: "the Mac slept")
            }
        }
        publish(force: true)
    }

    // `config`, and the environment at launch. A new phone name forgets the
    // old one's identifier and everything heard from it; a new wait or silence
    // keeps what's been heard, so it applies at once.
    func configure(_ values: [String: String]) {
        let next = AwayConfig(values: values)
        if next.phone.map(PhoneName.normalised) != config.phone.map(PhoneName.normalised) {
            binding = PhoneBinding()
            targetRSSI = nil
            targetHeard = nil
            tracker = PresenceTracker(rule: tracker.rule)
            // Nothing is known about the new phone yet, and nothing gets
            // judged until it's found, so an "away" about the old one must
            // not stand in the meantime.
            report(.present)
        }
        tracker.rule = next.rule
        config = next
        // Re-read, so the paired check sees the new name straight away.
        pairedNamesAt = .distantPast
        tick()
    }

    // Seconds since the last keyboard, mouse or trackpad event in this login
    // session. Needs no permission: it's a count, not the events themselves.
    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    private func forgetHeard(because why: String) {
        tracker.forgetHeard()
        FileHandle.standardError.write(Data("away: forgot the phone's last signal: \(why)\n".utf8))
    }

    private func tick() {
        let now = Date()
        if sleepGap.slept(tickAt: now) { forgetHeard(because: "the clock jumped") }
        refreshPairedNames(now)
        phone = currentPhone(now)
        switch phone {
        case .bound:
            report(tracker.evaluate(now: now, idle: Self.idleSeconds()))
        case .ambiguous, .notPaired, .notFound, .notChosen:
            // Nothing to judge, or nothing certain: never away.
            report(.present)
        }
        publish()
    }

    private func currentPhone(_ now: Date) -> Snapshot.Phone {
        guard let name = config.phone else { return .notChosen }
        guard pairedNames.contains(PhoneName.normalised(name)) else { return .notPaired }
        switch binding.resolve(now: now, window: TimeInterval(config.silenceSeconds)) {
        case .notFound:              return .notFound
        case .ambiguous(let count):  return .ambiguous(count: count)
        case .bound:                 return .bound
        }
    }

    private func refreshPairedNames(_ now: Date) {
        // Re-read now and then, so a phone paired after this started shows up.
        guard now.timeIntervalSince(pairedNamesAt) >= 30 else { return }
        pairedNames = Self.pairedDeviceNames()
        pairedNamesAt = now
    }

    // The signal, only when it changes, so the app reacts once per change.
    private func report(_ state: PresenceState) {
        guard ready, state != reported else { return }
        reported = state
        FileHandle.standardError.write(Data("away: \(state)\n".utf8))
        guard mayHoldPresence else { return }
        Out.send(["type": "signal", "name": "presence",
                  "value": state == .away ? "away" : "present"])
    }

    // MARK: CoreBluetooth

    static func issue(for state: CBManagerState) -> String? {
        switch state {
        case .poweredOn:            return nil
        case .poweredOff:           return "Bluetooth off"
        case .unauthorized:         return "Bluetooth not allowed"
        case .unsupported:          return "No Bluetooth LE"
        case .resetting, .unknown:  return nil
        @unknown default:           return nil
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothIssue = Self.issue(for: central.state)
        guard central.state == .poweredOn else {
            // Nothing heard while Bluetooth is off says nothing about where the
            // phone is, so forget it rather than count the silence.
            tracker = PresenceTracker(rule: tracker.rule)
            targetRSSI = nil
            targetHeard = nil
            nearby = [:]
            report(.present)
            publish(force: true)
            return
        }
        // Duplicates on: each advertisement is a reading, not just the first.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        publish(force: true)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let now = Date()
        let rssi = RSSI.intValue
        refreshPairedNames(now)
        guard let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !name.isEmpty else { return }
        let normalised = PhoneName.normalised(name)
        // Only a paired device can be the phone, or be listed. CoreBluetooth
        // has no public way from a scan result to a pairing, so it goes by the
        // name the pairing recorded, which is also the name a paired phone
        // advertises.
        guard pairedNames.contains(normalised) else { return }

        if let phone = config.phone, normalised == PhoneName.normalised(phone) {
            binding.observe(peripheral.identifier, at: now)
            if case .bound = currentPhone(now), peripheral.identifier == binding.bound {
                tracker.observe(rssi: rssi, at: now)
                if rssi < 0 {
                    targetRSSI = rssi
                    targetHeard = now
                }
                // Coming back on a strong reading is reported straight away,
                // not on the next tick, so the app hears it as soon as possible.
                if tracker.state == .present, reported == .away { report(.present) }
            }
        }

        // The list the user copies the name from: paired, named, heard lately.
        guard rssi < 0 else { return }
        nearby[peripheral.identifier] = Nearby(id: peripheral.identifier, name: name,
                                               rssi: rssi, lastSeen: now)
    }

    static func pairedDeviceNames() -> Set<String> {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return Set(paired.compactMap { $0.name }.filter { !$0.isEmpty }.map(PhoneName.normalised))
    }

    // MARK: The tab

    // At most every 2 s, and only when what it shows changed. A busy room
    // advertises many times a second; the tab needn't redraw that often.
    private func publish(force: Bool = false) {
        let now = Date()
        guard ready, force || now.timeIntervalSince(lastDocumentAt) >= 2 else { return }
        nearby = nearby.filter { now.timeIntervalSince($0.value.lastSeen) < 60 }
        offerChoices(now)
        let bound = binding.bound
        let document = Tab.document(Snapshot(
            config: config, issue: bluetoothIssue, scanning: central != nil, phone: phone,
            state: reported ?? .present, rssi: targetRSSI, heard: targetHeard,
            others: nearby.values.filter { $0.id != bound }, now: now))
        guard let data = Out.line(["type": "document", "document": document]),
              data != lastDocument else { return }
        lastDocument = data
        lastDocumentAt = now
        Out.send(["type": "document", "document": document])
    }

    // Sent when the devices on offer change, and otherwise at most every 10 s
    // to keep the signal strengths in the labels roughly current. publish
    // already holds this to once every 2 s.
    private func offerChoices(_ now: Date) {
        let options = PhoneChoices.options(nearby: Array(nearby.values), configured: config.phone)
        let values = options.map { $0["value"] ?? "" }
        let changedSet = values != (offered?.map { $0["value"] ?? "" } ?? [])
        guard offered == nil || changedSet
                || (options != offered! && now.timeIntervalSince(offeredAt) >= 10) else { return }
        offered = options
        offeredAt = now
        Out.send(PhoneChoices.message(options))
    }
}

// MARK: - stdin

// Lines from the host, read on a background thread and handled on main, where
// CoreBluetooth and the timer live.
func readHost(_ away: Away) {
    let thread = Thread {
        var started = false
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            DispatchQueue.main.async {
                switch type {
                case "hello":
                    guard !started else { return }
                    started = true
                    let granted = object["capabilities"] as? [String] ?? []
                    away.start(granted: granted, values: ProcessInfo.processInfo.environment)
                case "config":
                    away.configure(object["values"] as? [String: String] ?? [:])
                case "ping":
                    // Echoed as it came: the host matches it to the ping it sent.
                    Out.send(["type": "pong", "id": object["id"] ?? 0])
                case "stop":
                    exit(0)
                default:
                    // Unknown types are how the protocol grows; skip them.
                    break
                }
            }
        }
        // stdin closed: the host has gone, and nobody is left to tell.
        DispatchQueue.main.async { exit(0) }
    }
    thread.start()
}

// MARK: - Self-test

// Replays recorded timings through the rule, for scripts/test-extensions.sh
// (via test_away.py). Exits non-zero on any failure, naming each.
func selfTest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        if !ok {
            failures += 1
            print("FAIL: \(what)")
        }
    }
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func at(_ s: Double) -> Date { start.addingTimeInterval(s) }
    func rule(idle: Double, silence: Double) -> PresenceTracker.Rule {
        PresenceTracker.Rule(idle: idle, silence: silence)
    }

    // The desk recording: an idle phone lying beside the Mac, with gaps of 66
    // and 75 s between advertisements and weak readings. Nobody touches the
    // Mac. With a 10 s wait and the shortest silence allowed (90 s) it must
    // never count as away.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 10, silence: 90))
        let adverts: [(Double, Int)] = [(0, -60), (6, -71), (12, -95), (15, -99)]
            + stride(from: 81.0, through: 146, by: 5).map { ($0, -88) }
            + [(221, -93), (225, -70)]
        var next = 0
        var everAway = false
        // Up to 300 s: 75 s after the last advert, still short of the 90 s.
        for second in 0...300 {
            let now = at(Double(second))
            while next < adverts.count, adverts[next].0 <= Double(second) {
                tracker.observe(rssi: adverts[next].1, at: now)
                next += 1
            }
            if tracker.evaluate(now: now, idle: Double(second)) == .away { everAway = true }
        }
        check(!everAway, "the desk recording counted as away")
    }

    // The silence while idle is away; a strong advert is back.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 10, silence: 120))
        tracker.observe(rssi: -60, at: at(0))
        check(tracker.evaluate(now: at(119), idle: 119) == .present, "away before 120 s of silence")
        check(tracker.evaluate(now: at(120), idle: 120) == .away, "not away after 120 s of silence")
        tracker.observe(rssi: -85, at: at(125))
        check(tracker.state == .away, "a weak -85 advert brought you back")
        tracker.observe(rssi: -72, at: at(130))
        check(tracker.state == .present, "a -72 advert didn't bring you back")
    }

    // Idle and silence are independent: a short wait doesn't stretch the
    // silence, and a long silence isn't shortened by a short wait.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 10, silence: 90))
        tracker.observe(rssi: -60, at: at(0))
        check(tracker.evaluate(now: at(89), idle: 89) == .present, "away before 90 s of silence")
        check(tracker.evaluate(now: at(90), idle: 90) == .away, "not away after 90 s of silence")

        var long = PresenceTracker(rule: rule(idle: 30, silence: 600))
        long.observe(rssi: -60, at: at(0))
        check(long.evaluate(now: at(599), idle: 599) == .present, "away before 600 s of silence")
        check(long.evaluate(now: at(600), idle: 600) == .away, "not away after 600 s of silence")

        var idle = PresenceTracker(rule: rule(idle: 120, silence: 90))
        idle.observe(rssi: -60, at: at(0))
        check(idle.evaluate(now: at(100), idle: 100) == .present, "away before the idle wait")
        check(idle.evaluate(now: at(120), idle: 120) == .away, "not away once idle long enough")
    }

    // Typing always means present, however long the phone has been silent.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 30, silence: 120))
        tracker.observe(rssi: -60, at: at(0))
        check(tracker.evaluate(now: at(600), idle: 5) == .present, "away while typing")
    }

    // A phone gone for good locks once: after input brings you back, a long
    // idle with no advert stays present until the phone is heard again.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 10, silence: 120))
        tracker.observe(rssi: -60, at: at(0))
        check(tracker.evaluate(now: at(130), idle: 130) == .away, "never went away")
        check(tracker.evaluate(now: at(140), idle: 0) == .present, "input didn't bring you back")
        check(tracker.evaluate(now: at(500), idle: 360) == .present, "locked twice for one departure")
    }

    // Sleep. The phone was heard just before the lid closed; the first tick
    // after waking comes 20 minutes later, idle the whole time. The silence
    // was the Mac's, not the phone's, so it must not lock, and it stays
    // present until the phone has been heard afresh and gone quiet again.
    do {
        var tracker = PresenceTracker(rule: rule(idle: 10, silence: 120))
        var gap = SleepGap()
        tracker.observe(rssi: -60, at: at(0))
        for second in 0...30 {
            if gap.slept(tickAt: at(Double(second))) { tracker.forgetHeard() }
            tracker.evaluate(now: at(Double(second)), idle: Double(second))
        }
        check(!gap.slept(tickAt: at(31)), "a one-second tick read as a sleep")
        let woke = at(1231)
        if gap.slept(tickAt: woke) { tracker.forgetHeard() } else { check(false, "missed the sleep") }
        check(tracker.evaluate(now: woke, idle: 1231) == .present, "locked on waking from sleep")
        check(tracker.evaluate(now: at(1500), idle: 1500) == .present, "locked later without a new advert")
        tracker.observe(rssi: -60, at: at(1510))
        check(tracker.evaluate(now: at(1630), idle: 1630) == .away, "a fresh silence after waking didn't count")
    }

    // Which device is the phone.
    do {
        let mine = UUID(), other = UUID(), rotated = UUID()
        var binding = PhoneBinding()
        check(binding.resolve(now: at(0), window: 120) == .notFound, "bound to nothing heard")
        binding.observe(mine, at: at(0))
        check(binding.resolve(now: at(1), window: 120) == .bound(mine), "didn't bind the only one")

        // A second device with the name: neither, until one has been silent
        // for the window.
        binding.observe(other, at: at(10))
        check(binding.resolve(now: at(11), window: 120) == .ambiguous(count: 2), "bound with two")
        binding.observe(mine, at: at(50))
        binding.observe(other, at: at(100))
        check(binding.resolve(now: at(101), window: 120) == .ambiguous(count: 2), "still two")
        binding.observe(other, at: at(200))
        check(binding.resolve(now: at(200), window: 120) == .bound(other),
              "didn't move to the one still heard once the bound one went silent")

        // Two seen at once from the start binds to neither.
        var fresh = PhoneBinding()
        fresh.observe(mine, at: at(0))
        fresh.observe(rotated, at: at(0))
        check(fresh.resolve(now: at(1), window: 120) == .ambiguous(count: 2), "bound when ambiguous")
        check(fresh.bound == nil, "kept a binding while ambiguous")

        // The bound one simply going quiet stays bound: that's how away happens.
        var quiet = PhoneBinding()
        quiet.observe(mine, at: at(0))
        _ = quiet.resolve(now: at(0), window: 120)
        check(quiet.resolve(now: at(300), window: 120) == .bound(mine), "dropped a silent phone")
    }

    // Names compare loosely.
    check(PhoneName.normalised("Alex\u{2019}s Pixel 9 ") == PhoneName.normalised("alex's pixel 9"),
          "curly apostrophe, case or space made a different name")
    check(PhoneName.normalised("Alex\u{2018}s") == "alex's", "left single quote")

    // Config: unset is the default, out of range is clamped, junk is ignored.
    check(AwayConfig(values: [:]).idleSeconds == 30, "idle default")
    check(AwayConfig(values: [AwayConfig.idleKey: "3"]).idleSeconds == 10, "idle floor")
    check(AwayConfig(values: [AwayConfig.idleKey: "900"]).idleSeconds == 120, "idle ceiling")
    check(AwayConfig(values: [AwayConfig.idleKey: "soon"]).idleSeconds == 30, "idle junk")
    check(AwayConfig(values: [:]).silenceSeconds == 120, "silence default")
    check(AwayConfig(values: [AwayConfig.silenceKey: "30"]).silenceSeconds == 90, "silence floor")
    check(AwayConfig(values: [AwayConfig.silenceKey: "9000"]).silenceSeconds == 600, "silence ceiling")
    check(AwayConfig(values: [AwayConfig.silenceKey: "300"]).rule.missingAfter == 300, "silence rule")
    check(AwayConfig(values: [AwayConfig.idleKey: "45"]).rule.idleAtLeast == 45, "idle rule")
    check(AwayConfig(values: [AwayConfig.phoneKey: "  "]).phone == nil, "blank phone")

    // The phone row and badge say what's going on.
    do {
        let config = AwayConfig(values: [AwayConfig.phoneKey: "Pixel"])
        func phoneRow(_ phone: Snapshot.Phone, state: PresenceState = .present, rssi: Int? = -75,
                      heard: Date? = at(0), now: Date = at(3)) -> (badge: String, value: String) {
            let document = Tab.document(Snapshot(config: config, issue: nil, scanning: true,
                                                 phone: phone, state: state, rssi: rssi,
                                                 heard: heard, others: [], now: now))
            let header = document["header"] as? [String: Any]
            let badge = (header?["badge"] as? [String: Any])?["text"] as? String ?? ""
            let row = (document["rows"] as? [[String: Any]])?.first
            return (badge, row?["value"] as? String ?? "")
        }
        check(phoneRow(.bound) == ("Present", "\u{2212}75 dBm · 3 s ago"), "heard row")
        check(phoneRow(.bound, now: at(240)) == ("Phone silent", "not heard for 4 min"), "silent row")
        check(phoneRow(.bound, state: .away, now: at(240)) == ("Away", "not heard for 4 min"), "away row")
        check(phoneRow(.notPaired) == ("Phone not paired", "not paired"), "unpaired row")
        check(phoneRow(.ambiguous(count: 2)) == ("Rename your phone", "2 devices"), "ambiguous row")
        check(phoneRow(.notFound, rssi: nil, heard: nil) == ("Looking for phone", "not heard yet"),
              "not found row")
    }

    // The phone choices: one per name, the configured spelling kept, and the
    // configured phone listed even when it isn't heard.
    do {
        let a = UUID(), b = UUID(), c = UUID()
        let heard = [Nearby(id: a, name: "Alex's Pixel 9", rssi: -74, lastSeen: at(0)),
                     Nearby(id: b, name: "Alex's Pixel 9", rssi: -90, lastSeen: at(0)),
                     Nearby(id: c, name: "Headphones", rssi: -40, lastSeen: at(0))]
        let options = PhoneChoices.options(nearby: heard, configured: "Alex\u{2019}s Pixel 9")
        check(options.map { $0["value"] ?? "" } == ["Alex\u{2019}s Pixel 9", "Headphones"],
              "choices aren't one per name in the configured spelling: \(options)")
        check(options.first?["label"] == "Alex\u{2019}s Pixel 9 · \u{2212}74 dBm",
              "the choice label isn't name · strongest signal")
        let gone = PhoneChoices.options(nearby: [heard[2]], configured: "Pixel")
        check(gone.map { $0["value"] ?? "" } == ["Pixel", "Headphones"], "lost the configured phone")
        check(gone.first?["label"] == "Pixel · not heard", "the unheard phone isn't labelled so")
        check(PhoneChoices.options(nearby: [], configured: nil).isEmpty, "offered nothing heard")
        let line = Out.line(PhoneChoices.message(options)) ?? Data()
        let decoded = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        check(decoded?["type"] as? String == "choices" && decoded?["key"] as? String == AwayConfig.phoneKey,
              "the choices message isn't for the phone key")
        let crowd = (0..<200).map { Nearby(id: UUID(), name: String(repeating: "y", count: 200) + "\($0)",
                                           rssi: -60, lastSeen: at(0)) }
        let many = PhoneChoices.options(nearby: crowd, configured: nil)
        check(many.count == PhoneChoices.maxOptions, "choices over the host's cap")

        // Odd names are tidied or left out, never sent to be refused.
        let odd = [Nearby(id: UUID(), name: "  Pixel \n", rssi: -60, lastSeen: at(0)),
                   Nearby(id: UUID(), name: "   ", rssi: -60, lastSeen: at(0)),
                   Nearby(id: UUID(), name: "bad\u{0}name", rssi: -60, lastSeen: at(0)),
                   Nearby(id: UUID(), name: "a\u{2028}b", rssi: -60, lastSeen: at(0)),
                   Nearby(id: UUID(), name: String(repeating: "z", count: 300), rssi: -60, lastSeen: at(0))]
        let tidy = PhoneChoices.options(nearby: odd, configured: nil)
        check(tidy.map { $0["value"] ?? "" } == ["Pixel"], "odd device names weren't tidied: \(tidy)")
        check(tidy.allSatisfy { ($0["label"] ?? "").count <= PhoneChoices.maxLength
                                && ($0["value"] ?? "").count <= PhoneChoices.maxLength },
              "a choice over the host's length limit")
        check((Out.line(PhoneChoices.message(many)) ?? Data()).count < Out.maxLineBytes, "choices line over 64 KB")
    }

    // The document stays far under the host's 64 KB line limit even with a
    // crowded room of long names.
    do {
        let crowd = (0..<200).map {
            Nearby(id: UUID(), name: String(repeating: "x", count: 200) + "\($0)",
                   rssi: -50 - $0 % 40, lastSeen: at(0))
        }
        let document = Tab.document(Snapshot(
            config: AwayConfig(values: [AwayConfig.phoneKey: "Phone"]), issue: nil, scanning: true,
            phone: .bound, state: .present, rssi: -60, heard: at(0), others: crowd, now: at(1)))
        let line = Out.line(["type": "document", "document": document]) ?? Data()
        check(!line.isEmpty && line.count < Out.maxLineBytes, "document line over 64 KB")
    }

    print(failures == 0 ? "away self-test: ok" : "away self-test: \(failures) failed")
    return failures == 0 ? 0 : 1
}

// MARK: - Main

if CommandLine.arguments.dropFirst().first == "--self-test" {
    exit(selfTest())
}

let away = Away()
readHost(away)
RunLoop.main.run()
