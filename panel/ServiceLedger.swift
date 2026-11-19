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
// that pid *and* that start time is taken to be the one recorded. It carries
// its owner the same way: the app that started it. Two copies of the app can
// run at once (a dev build beside the installed one) and share this
// directory, and a record whose owner is still running belongs to that copy,
// whose services are live, not left over.
struct ServiceLedger {

    struct Record: Codable, Equatable {
        let id: String
        let process: Identity
        let group: pid_t
        let owner: Identity
    }

    // One process, told apart from any later one that gets the same pid.
    struct Identity: Codable, Equatable {
        let pid: pid_t
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
    // Returns the record, which is what `forget` takes.
    @discardableResult
    func record(id: String, pid: pid_t, group: pid_t,
                owner: pid_t = getpid(),
                startTime: (pid_t) -> ProcessStart? = ServiceLedger.startTime(of:)) -> Record? {
        guard pid > 0, let started = startTime(pid), let ownerStarted = startTime(owner) else { return nil }
        let record = Record(id: id, process: Identity(pid: pid, started: started), group: group,
                            owner: Identity(pid: owner, started: ownerStarted))
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path(for: record.process)), options: .atomic)
        return record
    }

    // Called once the child and its group are gone, by whichever path saw it
    // go. Keyed by pid and start time, so a pid already reused can't take a
    // newer process's record with it.
    func forget(_ record: Record) {
        try? FileManager.default.removeItem(atPath: path(for: record.process))
    }

    func records() -> [Record] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            guard let data = FileManager.default.contents(atPath: "\(directory)/\(name)") else { return nil }
            return try? JSONDecoder().decode(Record.self, from: data)
        }
    }

    // MARK: - Reaping

    static func isRunning(_ identity: Identity, startTime: (pid_t) -> ProcessStart?) -> Bool {
        identity.pid > 0 && startTime(identity.pid) == identity.started
    }

    // The records whose process is still the one recorded and whose owner is
    // gone. A record with a live owner is another copy's live service; one
    // whose process isn't running went quietly, or its pid now belongs to
    // something else.
    static func leftovers(_ records: [Record], startTime: (pid_t) -> ProcessStart?) -> [Record] {
        records.filter {
            !isRunning($0.owner, startTime: startTime) && isRunning($0.process, startTime: startTime)
        }
    }

    // At launch, before any service starts. SIGTERM first, as a quit would
    // after `stop`, then SIGKILL to the group once `grace` is up. Blocks for
    // at most `grace`, and only when there is something left over. Afterwards
    // every record whose owner is gone is cleared, except one whose process is
    // still there straight after the SIGKILL. That is usually only until it is
    // reaped, but one stuck where a signal can't reach it would otherwise be
    // forgotten, so the next launch checks it again. Returns what it stopped,
    // for the log.
    @discardableResult
    func reapLeftovers(startTime: (pid_t) -> ProcessStart? = ServiceLedger.startTime(of:),
                       signal: (Record, Int32) -> Void = ServiceLedger.signal,
                       grace: TimeInterval = 1,
                       pause: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) })
        -> [Record] {
        let orphaned = records().filter { !Self.isRunning($0.owner, startTime: startTime) }
        let found = Self.leftovers(orphaned, startTime: startTime)
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
        let survivors = Self.leftovers(waiting, startTime: startTime)
        for record in orphaned where !survivors.contains(record) { forget(record) }
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
            kill(record.process.pid, signal)
        }
    }

    private func path(for process: Identity) -> String {
        "\(directory)/\(process.pid)-\(process.started.seconds).\(process.started.microseconds).json"
    }
}
