import XCTest

@testable import StackNudgePanelCore

// A clock and a child process the tests drive by hand, so the supervisor's
// state machine runs through hours of restarts and timeouts without waiting.
// Nothing here fires on its own: time moves on `advance`, and a process says
// something or exits only when a test makes it.

final class FakeScheduler: ServiceScheduler {

    private final class Timer: ServiceTimer {
        let at: TimeInterval
        let work: () -> Void
        var done = false
        init(at: TimeInterval, work: @escaping () -> Void) {
            self.at = at
            self.work = work
        }
        func cancel() { done = true }
    }

    private(set) var clock: TimeInterval = 1_000_000
    private var timers: [Timer] = []

    func now() -> TimeInterval { clock }

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ServiceTimer {
        let timer = Timer(at: clock + delay, work: work)
        timers.append(timer)
        return timer
    }

    // Moves time forward, firing whatever falls due on the way, in order, with
    // the clock set to each timer's own moment as it fires. A timer set by one
    // that fires is itself fired if it falls inside the same span.
    func advance(_ seconds: TimeInterval) {
        let end = clock + seconds
        while let next = timers.filter({ !$0.done && $0.at <= end }).min(by: { $0.at < $1.at }) {
            clock = max(clock, next.at)
            next.done = true
            next.work()
        }
        timers.removeAll { $0.done }
        clock = end
    }

    // Moves the clock without firing anything, as a Mac asleep does: the
    // timers come due all at once on wake, late.
    func sleep(_ seconds: TimeInterval) {
        clock += seconds
    }

    // Seconds from now until each live timer, soonest first.
    var pending: [TimeInterval] {
        timers.filter { !$0.done }.map { $0.at - clock }.sorted()
    }
}

final class FakeProcess: ServiceProcess {
    let executable: String
    let environment: [String: String]
    private let onOutput: (Data) -> Void
    private let onExit: (ServiceSupervisor.Termination) -> Void
    private(set) var written: [Data] = []
    private(set) var signals: [Int32] = []
    // Behaves like a well-written service: reading `stop` and leaving.
    var exitsOnStop = false

    init(executable: String, environment: [String: String],
         onOutput: @escaping (Data) -> Void,
         onExit: @escaping (ServiceSupervisor.Termination) -> Void) {
        self.executable = executable
        self.environment = environment
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func write(_ data: Data) {
        written.append(data)
        if exitsOnStop, types.last == "stop" { exit(.exited(0)) }
    }
    func signal(_ signal: Int32) { signals.append(signal) }

    // What the host sent, one decoded object per line.
    var messages: [[String: Any]] {
        written.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    var types: [String] { messages.compactMap { $0["type"] as? String } }

    // Prints one line, as the extension would.
    func say(_ json: String) { onOutput(Data((json + "\n").utf8)) }

    func output(_ data: Data) { onOutput(data) }

    func ready() { say(#"{"type":"ready","protocol":1}"#) }

    func document(_ title: String) {
        say(#"{"type":"document","document":{"schema":1,"header":{"title":"\#(title)"}}}"#)
    }

    func pongLastPing() {
        guard let id = messages.last(where: { $0["type"] as? String == "ping" })?["id"] as? Int
        else { return XCTFail("no ping to answer") }
        say(#"{"type":"pong","id":\#(id)}"#)
    }

    func exit(_ termination: ServiceSupervisor.Termination = .exited(1)) { onExit(termination) }
}

final class FakeSpawner: ServiceSpawner {
    struct Refused: Error {}

    private(set) var spawned: [FakeProcess] = []
    var refuse = false
    var exitOnStop = false

    var last: FakeProcess { spawned[spawned.count - 1] }

    func spawned(_ id: String) -> [FakeProcess] {
        spawned.filter { $0.executable.contains("/\(id)/") }
    }

    func spawn(executable: String,
               directory: String,
               environment: [String: String],
               onOutput: @escaping (Data) -> Void,
               onExit: @escaping (ServiceSupervisor.Termination) -> Void) throws -> ServiceProcess {
        if refuse { throw Refused() }
        let process = FakeProcess(executable: executable, environment: environment,
                                  onOutput: onOutput, onExit: onExit)
        process.exitsOnStop = exitOnStop
        spawned.append(process)
        return process
    }
}

extension ServiceSupervisor {
    // A supervisor on the fakes, running everything inline on the caller.
    static func fake(id: String = "away",
                     granted: [ExtensionCapability] = [],
                     config: [String: String] = [:],
                     spawner: FakeSpawner,
                     scheduler: FakeScheduler,
                     executable: String? = nil,
                     onEvent: @escaping (Event) -> Void = { _ in }) -> ServiceSupervisor {
        let path = executable ?? "/extensions/\(id)/run"
        return ServiceSupervisor(id: id, directory: "/extensions/\(id)", granted: granted,
                                 environment: ["STACKNUDGE_EXT_ID": id], config: config,
                                 executable: { executable == "" ? nil : path },
                                 spawner: spawner, scheduler: scheduler,
                                 perform: { $0() }, onEvent: onEvent)
    }
}
