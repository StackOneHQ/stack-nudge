import Foundation
import CoreBluetooth
import IOBluetooth

// Whether you're at the Mac, judged from your phone's Bluetooth LE
// advertisements and how long the Mac has gone without input.
//
// Why advertisements, not a connection: a paired phone advertises over LE
// under a stable identifier (macOS resolves its rotating address through the
// pairing), whether or not its screen is on, so a passive scan sees it without
// connecting to anything or installing anything on the phone. The
// classic-Bluetooth route (IOBluetooth's connection state and rawRSSI) reported
// the phone connected at a fixed -46 the whole time it was gone, and an LE
// connection to the paired phone by identifier timed out every time.
//
// Measured on a Galaxy S25+: in use at the desk, an advertisement every 2–14 s.
// Lying idle on the desk, gaps of 66 and 75 s within ten minutes, and readings
// anywhere from -41 to -99 dBm. Walking out, the last readings before silence
// were -86 to -93, no weaker than the idle desk. So signal strength can't tell
// leaving from lying still, and only a long silence means gone.

enum PresenceState: Equatable {
    case present
    case away
}

// The decision, as a value with no Bluetooth in it, so a test can drive it
// with timestamps. Away takes the phone being silent *and* the Mac being idle,
// so the screen never locks under someone who's typing.
struct PresenceTracker {
    struct Rule: Equatable {
        // No advertisement for this long means the phone is out of range.
        var missingAfter: TimeInterval = minimumSilence
        // And nobody has touched the Mac for this long.
        var idleAtLeast: TimeInterval = 45
        // A reading at least this strong brings you back.
        var backRSSI: Int = -80

        // The rule for a chosen wait (Settings → Away → Idle for): that long
        // idle, and the phone silent for as long, but never less than
        // minimumSilence.
        static func waiting(_ seconds: TimeInterval) -> Rule {
            var rule = Rule()
            rule.idleAtLeast = seconds
            rule.missingAfter = max(seconds, minimumSilence)
            return rule
        }
        // An idle phone on the desk went 75 s without advertising; 20 s, the
        // old floor, locked the screen under the user dozens of times a day.
        // That 75 s comes from one ten-minute recording of one phone, so raise
        // this if a longer gap turns up.
        static let minimumSilence: TimeInterval = 120
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

// A device the scan has heard from, for picking the phone in Settings.
struct NearbyDevice: Equatable, Identifiable {
    let id: UUID
    let name: String
    var rssi: Int
    var lastSeen: Date

    // Only devices paired with this Mac are offered. CoreBluetooth gives no
    // public way from a scan result to a pairing, so it goes by the name the
    // pairing recorded, which is also the name a paired phone advertises.
    // Besides keeping the list short, a paired device is the only kind whose
    // identifier macOS keeps stable as its address rotates.
    static func pairedOnly(_ devices: [NearbyDevice], pairedNames: Set<String>) -> [NearbyDevice] {
        devices.filter { pairedNames.contains($0.name) }
    }
}

enum PairedDevices {
    static func names() -> Set<String> {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return Set(paired.compactMap { $0.name }.filter { !$0.isEmpty })
    }
}

// Scans while away detection is on, feeds the chosen device's advertisements to
// a PresenceTracker and reports changes. Creating the central manager is what
// asks for Bluetooth permission, so nothing here runs until start().
final class ProximityMonitor: NSObject, CBCentralManagerDelegate {
    var onStateChange: (PresenceState) -> Void = { _ in }
    var onNearbyChange: ([NearbyDevice]) -> Void = { _ in }
    // Why the scan can't run, for the Phone row, or nil while it can.
    var onBluetoothIssue: (String?) -> Void = { _ in }

    var target: UUID? {
        didSet { if target != oldValue { tracker = PresenceTracker(rule: tracker.rule) } }
    }

    // Changing the wait keeps what's been heard, so it applies at once.
    var rule: PresenceTracker.Rule {
        get { tracker.rule }
        set { tracker.rule = newValue }
    }

    private var central: CBCentralManager?
    private var tracker = PresenceTracker()
    private var nearby: [UUID: NearbyDevice] = [:]
    private var timer: Timer?
    private var lastReported: PresenceState = .present
    private var lastNearbyPublish = Date.distantPast
    private var pairedNames: Set<String> = []
    private var pairedNamesAt = Date.distantPast

    var isRunning: Bool { central != nil }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        central?.stopScan()
        central = nil
        timer?.invalidate()
        timer = nil
        nearby = [:]
        tracker = PresenceTracker(rule: tracker.rule)
        if lastReported != .present {
            lastReported = .present
            onStateChange(.present)
        }
    }

    static func issue(for state: CBManagerState) -> String? {
        switch state {
        case .poweredOn:              return nil
        case .poweredOff:             return "Bluetooth is off"
        case .unauthorized:           return "Bluetooth not allowed"
        case .unsupported:            return "No Bluetooth LE"
        case .resetting, .unknown:    return nil
        @unknown default:             return nil
        }
    }

    private func tick() {
        // No phone chosen yet: nothing to judge, and never away.
        guard target != nil else { return }
        let state = tracker.evaluate(now: Date(), idle: IdleTime.seconds())
        if state != lastReported {
            lastReported = state
            onStateChange(state)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onBluetoothIssue(Self.issue(for: central.state))
        guard central.state == .poweredOn else {
            // Nothing heard while Bluetooth is off says nothing about where the
            // phone is, so forget it rather than count the silence.
            tracker = PresenceTracker(rule: tracker.rule)
            nearby = [:]
            onNearbyChange([])
            if lastReported != .present {
                lastReported = .present
                onStateChange(.present)
            }
            return
        }
        // Duplicates on: each advertisement is a reading, not just the first.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let now = Date()
        let rssi = RSSI.intValue
        if peripheral.identifier == target {
            tracker.observe(rssi: rssi, at: now)
            if tracker.state != lastReported {
                lastReported = tracker.state
                onStateChange(tracker.state)
            }
        }
        // Only named devices are worth offering as "your phone".
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name, !name.isEmpty, rssi < 0 else { return }
        nearby[peripheral.identifier] = NearbyDevice(id: peripheral.identifier, name: name,
                                                     rssi: rssi, lastSeen: now)
        // A busy room advertises many times a second; Settings needn't redraw that often.
        if now.timeIntervalSince(lastNearbyPublish) >= 2 {
            lastNearbyPublish = now
            nearby = nearby.filter { now.timeIntervalSince($0.value.lastSeen) < 60 }
            // Re-read now and then, so a phone paired after turning this on shows up.
            if now.timeIntervalSince(pairedNamesAt) >= 30 {
                pairedNames = PairedDevices.names()
                pairedNamesAt = now
            }
            let offered = NearbyDevice.pairedOnly(Array(nearby.values), pairedNames: pairedNames)
            onNearbyChange(offered.sorted { $0.rssi > $1.rssi })
        }
    }
}

// Locks the screen. SACLockScreenImmediate is private (login.framework), the
// call BLEUnlock and others use; when it can't be found, sleeping the display
// locks too, provided "Require password" is set to immediately.
enum ScreenLock {
    static func lock() {
        typealias LockFn = @convention(c) () -> Int32
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") {
            _ = unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }
}
