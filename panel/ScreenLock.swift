import Foundation

// What the app does when the presence signal changes. Away itself is a service
// extension (extensions/away); the app's half is only this reaction, so whether
// the screen locks stays an app setting and a dead extension can't leave
// anything locked. See docs/design/service-extensions.md, "The pilot: Away".
//
// A value with no side effects, so a test can check every path into it,
// including the registry resetting a crashed holder to `present`.
enum PresenceReaction: Equatable {
    case none
    case present
    case away(lock: Bool)

    static func on(_ signal: AppSignal, value: String, lockWhenAway: Bool) -> PresenceReaction {
        guard signal == .presence else { return .none }
        // Anything but "away" is present. The registry has already refused any
        // other value, and neutral is the safe reading of one that slipped by.
        return value == "away" ? .away(lock: lockWhenAway) : .present
    }

    var isAway: Bool? {
        switch self {
        case .none:          return nil
        case .present:       return false
        case .away:          return true
        }
    }

    var locks: Bool {
        if case .away(lock: true) = self { return true }
        return false
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
