import Foundation
import CoreBluetooth
import IOBluetooth

// Whether you're at the Mac, judged from your phone's Bluetooth LE
// advertisements and how long the Mac has gone without input.
//
// Why advertisements, not a connection: a paired phone advertises over LE
// under a stable identifier (macOS resolves its rotating address through the
// pairing), whether or not its screen is on, so a passive scan sees it without
// connecting to anything or installing anything on the phone. Measured on a
// Galaxy S25+ at a desk: an advertisement every 2–14 s at about -62 to -80
// dBm, the same with the screen locked, and none at all a few rooms away. The
// classic-Bluetooth route (IOBluetooth's connection state and rawRSSI) reported
// the phone connected at a fixed -46 the whole time it was gone.

enum PresenceState: Equatable {
    case present
    case away
}

// The decision, as a value with no Bluetooth in it, so a test can drive it
// with timestamps. Away takes the phone being gone *and* the Mac being idle:
// single readings swing by 15 dB with the phone lying still, and nobody wants
// the screen locking under them while they type.
struct PresenceTracker {
    struct Rule: Equatable {
        // No advertisement for this long means the phone is out of range. The
        // longest gap measured at the desk was 14 s.
        var missingAfter: TimeInterval = 30
        // Or the recent average is this weak, for this long.
        var weakRSSI: Int = -85
        var weakFor: TimeInterval = 10
        // How many recent readings the average is over.
        var window: Int = 5
        // And nobody has touched the Mac for this long.
        var idleAtLeast: TimeInterval = 45
        // A reading at least this strong brings you back.
        var backRSSI: Int = -80

        // The rule for a chosen wait (Settings → Away → Lock after): that long
        // idle, and the phone gone for as long. Silence never counts below 15 s
        // whatever the wait, because a phone on the desk was measured going 14 s
        // between advertisements; any shorter and reading something would lock
        // you out.
        static func waiting(_ seconds: TimeInterval) -> Rule {
            var rule = Rule()
            rule.idleAtLeast = seconds
            rule.missingAfter = max(seconds, minimumSilence)
            rule.weakFor = min(rule.weakFor, seconds)
            return rule
        }
        static let minimumSilence: TimeInterval = 15
    }

    var rule = Rule()
    private(set) var state: PresenceState = .present
    private(set) var lastSeen: Date?
    private(set) var recent: [Int] = []
    private var weakSince: Date?

    init(rule: Rule = Rule()) { self.rule = rule }

    var averageRSSI: Int? {
        recent.isEmpty ? nil : recent.reduce(0, +) / recent.count
    }

    // One advertisement from the phone.
    mutating func observe(rssi: Int, at now: Date) {
        // CoreBluetooth reports 127 when it has no reading.
        guard rssi < 0 else { return }
        lastSeen = now
        recent.append(rssi)
        if recent.count > rule.window { recent.removeFirst(recent.count - rule.window) }
        if state == .away && rssi >= rule.backRSSI { state = .present }
        if let avg = averageRSSI, avg <= rule.weakRSSI {
            if weakSince == nil { weakSince = now }
        } else {
            weakSince = nil
        }
    }

    // Called on a timer. Input on the Mac always means you're there.
    @discardableResult
    mutating func evaluate(now: Date, idle: TimeInterval) -> PresenceState {
        if idle < rule.idleAtLeast {
            state = .present
            return state
        }
        guard state == .present else { return state }
        let missing = lastSeen.map { now.timeIntervalSince($0) >= rule.missingAfter } ?? false
        let weak = weakSince.map { now.timeIntervalSince($0) >= rule.weakFor } ?? false
        if missing || weak {
            state = .away
            // The readings that sent you away shouldn't hold you there.
            recent.removeAll()
            weakSince = nil
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
        guard central.state == .poweredOn else { return }
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
