import AppKit
import Foundation

enum JoinState: Equatable {
    case joined, notJoined, unknown
}

// Answers "is the user in this meeting right now?" from its join link. `check` blocks, so call it off the main thread.
protocol JoinDetector: Sendable {
    func check(url: String) -> JoinState
}

// What a join link points at, reduced to what can be recognised on this Mac.
enum JoinTarget: Equatable {
    case meet(code: String)
    case zoom(id: String?)
    case teams
    case unsupported

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).lowercased()
    }

    // The code after meet.google.com/, past an optional `/u/N` account prefix and the `/meet/` segment newer Meet tabs
    // carry (`meet.google.com/meet/abc-defg-hij`); query and fragment are ignored.
    static func meetCode(in url: String) -> String? {
        guard let code = first(#"https?://meet\.google\.com/(?:u/\d+/)?(?:meet/)?([a-z0-9][a-z0-9-]*)"#, in: url),
              !["landing", "new", "home", "meet"].contains(code) else { return nil }
        return code
    }

    // The numeric meeting id of `/j/<id>`, `/wc/<id>/...` and `/wc/join/<id>` links.
    static func zoomId(in url: String) -> String? {
        first(#"zoom\.(?:us|com)/(?:j/|wc/(?:join/)?)(\d{8,12})"#, in: url)
    }

    static func of(_ url: String) -> JoinTarget {
        if let code = meetCode(in: url) { return .meet(code: code) }
        if url.range(of: #"https?://[\w.-]*zoom\.(?:us|com)/"#, options: [.regularExpression, .caseInsensitive]) != nil { return .zoom(id: zoomId(in: url)) }
        if url.range(of: #"https?://teams\.(?:microsoft|live)\.com/"#, options: [.regularExpression, .caseInsensitive]) != nil { return .teams }
        return .unsupported
    }

    // A tab that shows this meeting, which for Meet includes the lobby.
    func matches(tab: String) -> Bool {
        switch self {
        case .meet(let code): return Self.meetCode(in: tab) == code
        case .zoom(let id): return id != nil && Self.zoomId(in: tab) == id
        case .teams:
            return tab.range(of: #"https?://teams\.(?:microsoft|live)\.com/.*(?:meetingjoin|pre-join|calling)"#, options: [.regularExpression, .caseInsensitive]) != nil
        case .unsupported: return false
        }
    }
}

enum TabRead: Equatable {
    case urls([String])
    case denied
    case failed
}

enum JoinDecision {
    // A meeting that was not found is `notJoined` only when everything that could show it was readable.
    static func decide(_ target: JoinTarget, reads: [TabRead], zoomInMeeting: Bool, teamsWindow: Bool) -> JoinState {
        let tabs = reads.flatMap { read -> [String] in if case .urls(let u) = read { return u } else { return [] } }
        let unreadable = reads.contains { !$0.isUrls }
        switch target {
        case .unsupported: return .unknown
        case .meet:
            if tabs.contains(where: target.matches) { return .joined }
            return reads.contains { $0.isUrls } ? .notJoined : .unknown
        case .zoom:
            if zoomInMeeting || tabs.contains(where: target.matches) { return .joined }
            return unreadable ? .unknown : .notJoined
        case .teams:
            if teamsWindow || tabs.contains(where: target.matches) { return .joined }
            return reads.contains { $0.isUrls } ? .notJoined : .unknown
        }
    }
}

private extension TabRead {
    var isUrls: Bool { if case .urls = self { return true } else { return false } }
}

// Reads the Mac: browser tabs through AppleScript, Zoom and Teams through their processes and windows.
struct SystemJoinDetector: JoinDetector {
    static let browsers: [(name: String, bundleId: String)] = [
        ("Google Chrome", "com.google.Chrome"), ("Arc", "company.thebrowser.Browser"), ("Safari", "com.apple.Safari"),
        ("Brave", "com.brave.Browser"), ("Microsoft Edge", "com.microsoft.edgemac"), ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Opera", "com.operasoftware.Opera"), ("Chromium", "org.chromium.Chromium"),
    ]

    private static let scriptTimeout: TimeInterval = 8
    private static let denialLogged = Locked(false)

    func check(url: String) -> JoinState {
        let target = JoinTarget.of(url)
        guard target != .unsupported else { return .unknown }
        var reads: [TabRead] = []
        if target != .zoom(id: nil) {
            let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            reads = Self.browsers.filter { running.contains($0.bundleId) }.map { Self.tabs(of: $0.bundleId, name: $0.name) }
        }
        let zoom = target.isZoom && Self.processExists("CptHost")
        let teams = target == .teams && Self.teamsMeetingWindow()
        return JoinDecision.decide(target, reads: reads, zoomInMeeting: zoom, teamsWindow: teams)
    }

    private static func tabs(of bundleId: String, name: String) -> TabRead {
        let script = "tell application id \"\(bundleId)\" to get URL of tabs of windows"
        guard let (status, out, err) = run("/usr/bin/osascript", ["-ss", "-e", script], timeout: scriptTimeout) else {
            JoinLog.write("\(name): tab read timed out")
            return .failed
        }
        guard status == 0 else {
            if err.contains("-1743") {
                if denialLogged.setOnce() { JoinLog.write("\(name): browser access denied, join detection falls back to the clock only") }
                return .denied
            }
            JoinLog.write("\(name): tab read failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            return .failed
        }
        let re = try? NSRegularExpression(pattern: #""([^"]*)""#)
        let urls = re?.matches(in: out, range: NSRange(out.startIndex..., in: out)).compactMap { m in
            Range(m.range(at: 1), in: out).map { String(out[$0]) }
        } ?? []
        return .urls(urls)
    }

    private static func processExists(_ name: String) -> Bool {
        run("/usr/bin/pgrep", ["-x", name], timeout: 2)?.status == 0
    }

    // Window titles are only readable with Screen Recording; without it this answers false.
    private static func teamsMeetingWindow() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            (w[kCGWindowOwnerName as String] as? String)?.contains("Teams") == true
                && (w[kCGWindowName as String] as? String)?.range(of: "meeting", options: .caseInsensitive) != nil
        }
    }

    private static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, out: String, err: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Reading to EOF first keeps a large tab list from filling the pipe and stalling the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        group.wait()
        return (p.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }
}

private extension JoinTarget {
    var isZoom: Bool { if case .zoom = self { return true } else { return false } }
}

// One flag behind a lock, for "log this once".
final class Locked: @unchecked Sendable {
    private var value: Bool
    private let lock = NSLock()
    init(_ value: Bool) { self.value = value }

    // True the first time only.
    func setOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let first = !value
        value = true
        return first
    }
}

enum JoinLog {
    static func write(_ line: String) {
        let dir = NSHomeDirectory() + "/.stack-nudge"
        let path = dir + "/join.log"
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
