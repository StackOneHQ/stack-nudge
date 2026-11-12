import Darwin
import Foundation

// The service processes this app has running, one small file each, so a launch
// after a crash or a force-quit can stop whatever the last one left behind.
//
// A normal quit stops every service itself (ExtensionHost.stopServices). This
// is for when the app never got to: its pipes close, and a service that reads
// stdin sees EOF and should leave, as Away does. Nothing makes one leave,
// though, and one that ignores EOF would otherwise run until logout, still
// holding whatever it was given (a Bluetooth scan, a socket).
//
// A pid comes back into use, so a record alone never kills anything. Each one
// carries the process's start time to the microsecond, and only a process with
// that pid *and* that start time is taken to be the one recorded.
struct ServiceLedger {

    struct Record: Codable, Equatable {
        let id: String
        let pid: pid_t
        let group: pid_t
        let started: ProcessStart
    }

    struct ProcessStart: Codable, Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    let directory: String

    static let live = ServiceLedger(
        directory: ("~/.stack-nudge/services" as NSString).expandingTildeInPath)

    // MARK: - Recording

    // Called once the child is running. One that has already exited has no
    // start time to read, and nothing left to stop, so it isn't recorded.
    func record(id: String, pid: pid_t, group: pid_t,
                startTime: (pid_t) -> ProcessStart? = ServiceLedger.startTime(of:)) {
        guard pid > 0, let started = startTime(pid),
              let data = try? JSONEncoder().encode(Record(id: id, pid: pid, group: group, started: started))
        else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(for: pid)), options: .atomic)
    }

    // Called once the child and its group are gone, by whichever path saw it go.
    func forget(pid: pid_t) {
        try? FileManager.default.removeItem(atPath: path(for: pid))
    }

    func records() -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = FileManager.default.contents(atPath: "\(directory)/\(name)") else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    // MARK: - Reaping

    // The records whose process is still the one recorded. Anything else is a
    // service that went quietly, or a pid that now belongs to something else.
    static func leftovers(_ records: [Record], startTime: (pid_t) -> ProcessStart?) -> [Record] {
        records.filter { $0.pid > 0 && startTime($0.pid) == $0.started }
    }

    // At launch, before any service starts, so every record is from an earlier
    // launch. SIGTERM first, as a quit would after `stop`, then SIGKILL to the
    // group once `grace` is up. Blocks for at most `grace`, and only when there
    // is something left over. Every record is cleared afterwards, matched or
    // not. Returns what it stopped, for the log.
    @discardableResult
    func reapLeftovers(startTime: (pid_t) -> ProcessStart? = ServiceLedger.startTime(of:),
                       signal: (Record, Int32) -> Void = ServiceLedger.signal,
                       grace: TimeInterval = 1,
                       pause: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) })
        -> [Record] {
        let all = records()
        let found = Self.leftovers(all, startTime: startTime)
        for record in found { signal(record, SIGTERM) }
        var waiting = found
        var waited: TimeInterval = 0
        while !waiting.isEmpty, waited < grace {
            pause(0.05)
            waited += 0.05
            waiting = Self.leftovers(waiting, startTime: startTime)
        }
        // The whole group, even where the leader has gone: a helper it
        // started can still be in there. The same reasoning as
        // LiveServiceProcess.finish: a group's id can't be reused while any
        // member remains, and with none left this finds nobody. A bare pid is
        // different, and is only killed while it is still the one recorded.
        for record in found where record.group > 0 || waiting.contains(record) {
            signal(record, SIGKILL)
        }
        for record in all { forget(pid: record.pid) }
        return found
    }

    // MARK: - Live process lookups

    static func startTime(of pid: pid_t) -> ProcessStart? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    // The group when there is one of its own; never ours, which would take out
    // the app.
    static func signal(_ record: Record, _ signal: Int32) {
        if record.group > 0, record.group != getpgrp() {
            killpg(record.group, signal)
        } else {
            kill(record.pid, signal)
        }
    }

    private func path(for pid: pid_t) -> String {
        "\(directory)/\(pid).json"
    }
}
