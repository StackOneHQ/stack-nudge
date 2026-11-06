import Foundation

// MARK: - Seams

// Everything with a clock or a process behind it comes in through these, so the
// supervisor's state machine runs in a test with a fake clock and a fake child
// and no waiting. The live versions are at the end of the file.

protocol ServiceTimer: AnyObject {
    func cancel()
}

protocol ServiceScheduler: AnyObject {
    // Wall-clock seconds. Wall clock rather than uptime on purpose: uptime
    // stops while the Mac sleeps, and noticing that a sleep happened is how a
    // missed pong after wake gets forgiven.
    func now() -> TimeInterval
    // Runs `work` on the supervisor's own queue after `delay`.
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ServiceTimer
}

// A running child, as the supervisor sees it: something to write lines to and
// something to signal. Both are safe to call after the child has gone.
protocol ServiceProcess: AnyObject {
    func write(_ data: Data)
    // Signals the child's whole process group, so anything it started goes too.
    func signal(_ signal: Int32)
}

protocol ServiceSpawner {
    // `onOutput` and `onExit` may arrive on any thread, but never at the same
    // time, and every byte the child wrote is delivered before its exit.
    func spawn(executable: String,
               directory: String,
               environment: [String: String],
               onOutput: @escaping (Data) -> Void,
               onExit: @escaping (ServiceSupervisor.Termination) -> Void) throws -> ServiceProcess
}

// MARK: - Supervisor

// Owns one long-running process for one service extension: starts it, checks
// it is alive, restarts it when it dies, gives up when it keeps dying, and stops
// it politely and then not. See docs/design/service-extensions.md, "Lifecycle".
//
// Confined to its own serial queue. Every entry point hops onto it through
// `perform`, and every timer fires on it, so none of the state below needs a
// lock. What the host needs to know goes out through `onEvent`, still on that
// queue; ExtensionHost hops it to main, the same way a view fetch comes back.
//
// Each spawn gets a generation number, and every callback from a child or a
// timer carries the generation it was made for. A late exit or a stray line from
// a process that has already been replaced is therefore ignored rather than
// mistaken for the new one, which is what makes a double restart impossible.
final class ServiceSupervisor {

    // How a child's life ended, or why there was no child to begin with.
    enum Termination: Equatable {
        case exited(Int32)
        case signalled(Int32)
        case failedToStart(String)
        // Answered `hello` with a protocol this host doesn't speak. Restarting
        // can't fix that, so it is broken straight away rather than after five.
        case incompatible(protocol: Int)

        var message: String {
            switch self {
            case .exited(let status):    return "exited \(status)"
            case .signalled(let signal): return "killed by signal \(signal)"
            case .failedToStart(let why): return why
            case .incompatible(let version):
                return "speaks service protocol \(version); this version speaks \(ServiceProtocol.version)"
            }
        }
    }

    enum State: Equatable {
        case stopped
        // Spawned, `hello` sent, waiting for `ready`.
        case starting
        case running
        // Died; a new process starts after this many seconds.
        case restarting(after: TimeInterval)
        // `stop` sent; waiting for the process to go.
        case stopping
        // Gave up. Stays here until the host replaces the supervisor.
        case broken(Termination)
    }

    enum Event: Equatable {
        case state(State)
        case document(ExtensionDocument)
        // A `document` line that didn't parse. Reported like a view extension's
        // malformed stdout, so the tab says whose bug it is.
        case malformedDocument(String)
        case signal(name: String, value: String)
        case feed(event: Data)
        // Something was dropped: too many messages, a line over its limit.
        // Sent once per process, since the point is to say it is happening,
        // not to forward the flood.
        case degraded(String)
        // A line that broke the rules without costing anything, for the log.
        case problem(String)
    }

    // Every duration and limit in one place, so a test can read the number it
    // is asserting against instead of repeating it.
    struct Timing {
        var handshake: TimeInterval = 10
        var pingInterval: TimeInterval = 30
        var pongTimeout: TimeInterval = 10
        // How much later than expected a pong timeout may fire before it is put
        // down to the Mac having slept rather than the extension having hung.
        var sleepSlack: TimeInterval = 5
        var stopGrace: TimeInterval = 3
        var termGrace: TimeInterval = 2
        var backoffBase: TimeInterval = 1
        var backoffCap: TimeInterval = 300
        var crashWindow: TimeInterval = 600
        var crashLimit = 5
        var messagesPerSecond: Double = 20
        // One second's worth: a burst of 20 lines at once is fine, a steady 21
        // a second is not.
        var messageBurst: Double = 20
    }

    let id: String
    let granted: [ExtensionCapability]
    let timing: Timing

    // Read on the supervisor's queue. The host keeps its own copy from
    // `onEvent` rather than reaching in here from main.
    private(set) var state: State = .stopped
    private(set) var degraded = false

    private let directory: String
    private let environment: [String: String]
    private let config: [String: String]
    private let executable: () -> String?
    private let spawner: ServiceSpawner
    private let scheduler: ServiceScheduler
    private let perform: (@escaping () -> Void) -> Void
    private let onEvent: (Event) -> Void

    private var process: ServiceProcess?
    private var generation = 0
    private var splitter = ServiceProtocol.LineSplitter()
    // Set when the host killed the child on purpose and already knows how this
    // ends, so the exit that follows isn't counted as an ordinary crash.
    private var fatal: Termination?

    // Restart accounting. `crashes` is the window that decides "broken";
    // `consecutive` drives the backoff and only resets once a process has
    // stayed up for a whole window, so a service that dies every few minutes
    // backs off toward the cap instead of restarting at 1 s forever.
    private var crashes: [TimeInterval] = []
    private var consecutive = 0
    private var runningSince: TimeInterval?

    private var handshakeTimer: ServiceTimer?
    private var pingTimer: ServiceTimer?
    private var pongTimer: ServiceTimer?
    private var restartTimer: ServiceTimer?
    private var stopTimers: [ServiceTimer] = []
    private var stopCompletions: [() -> Void] = []

    private var lastPingID = 0
    private var outstandingPing: (id: Int, sentAt: TimeInterval)?
    private var forgaveSleep = false

    private var tokens: Double = 0
    private var tokensAt: TimeInterval = 0

    init(id: String,
         directory: String,
         granted: [ExtensionCapability],
         environment: [String: String],
         config: [String: String] = [:],
         timing: Timing = Timing(),
         executable: @escaping () -> String?,
         spawner: ServiceSpawner,
         scheduler: ServiceScheduler,
         perform: @escaping (@escaping () -> Void) -> Void,
         onEvent: @escaping (Event) -> Void) {
        self.id = id
        self.directory = directory
        self.granted = granted
        self.environment = environment
        self.config = config
        self.timing = timing
        self.executable = executable
        self.spawner = spawner
        self.scheduler = scheduler
        self.perform = perform
        self.onEvent = onEvent
    }

    // A supervisor going away with its child still running would orphan the
    // child, and a service is written to run until told otherwise. The host
    // keeps one until its stop has finished; this is the backstop if that was
    // missed, or if a quit stopped waiting.
    //
    // Nothing races this. Every block on the queue and every callback holds
    // the supervisor weakly and re-checks, and one that got a strong reference
    // would be the last release itself, so deinit runs only once nobody else
    // can touch these properties. A stop still waiting is completed rather than
    // dropped, so whoever is waiting on it hears back.
    deinit {
        process?.signal(SIGKILL)
        let completions = stopCompletions
        stopCompletions = []
        completions.forEach { $0() }
    }

    // MARK: - Entry points

    func start() {
        perform { [weak self] in
            guard let self, self.state == .stopped else { return }
            self.spawn()
        }
    }

    // `stop` on stdin, then SIGTERM after the grace period, then SIGKILL. The
    // completion runs on the supervisor's queue once there is no process left,
    // so a caller blocking main to wait for it (quitting) can't deadlock.
    func stop(then completion: (() -> Void)? = nil) {
        perform { [weak self] in
            guard let self else { completion?(); return }
            if let completion { self.stopCompletions.append(completion) }
            switch self.state {
            case .stopped, .broken:
                self.finishStop(keepState: true)
            case .restarting:
                self.restartTimer?.cancel()
                self.restartTimer = nil
                self.finishStop(keepState: false)
            case .stopping:
                break
            case .starting, .running:
                self.cancelRunTimers()
                self.setState(.stopping)
                self.send(.stop)
                let generation = self.generation
                self.stopTimers.append(self.scheduler.after(self.timing.stopGrace) { [weak self] in
                    guard let self, self.generation == generation, self.state == .stopping else { return }
                    self.process?.signal(SIGTERM)
                    self.stopTimers.append(self.scheduler.after(self.timing.termGrace) { [weak self] in
                        guard let self, self.generation == generation, self.state == .stopping else { return }
                        self.process?.signal(SIGKILL)
                    })
                })
            }
        }
    }

    // Delivers an app event, if the extension was granted it and is up to
    // hear it. Dropped otherwise: an event is a notification, and one the
    // extension missed while starting is not worth queueing.
    func send(event name: String, fields: [String: ServiceProtocol.Value] = [:]) {
        perform { [weak self] in
            guard let self, self.state == .running,
                  let capability = ExtensionCapability.event(name),
                  self.granted.contains(capability) else { return }
            self.send(.event(name: name, fields: fields))
        }
    }

    // MARK: - Spawning

    private func spawn() {
        generation += 1
        let generation = self.generation
        splitter = ServiceProtocol.LineSplitter()
        fatal = nil
        degraded = false
        outstandingPing = nil
        forgaveSleep = false
        tokens = timing.messageBurst
        tokensAt = scheduler.now()

        // Resolved on every spawn, not once: the package can change under a
        // running service, and the containment check has to see what will run.
        guard let path = executable() else {
            return becomeBroken(.failedToStart("run is missing or not executable"))
        }
        do {
            process = try spawner.spawn(
                executable: path, directory: directory, environment: environment,
                onOutput: { [weak self] data in
                    self?.perform { [weak self] in self?.received(data, generation: generation) }
                },
                onExit: { [weak self] termination in
                    self?.perform { [weak self] in self?.exited(termination, generation: generation) }
                })
        } catch {
            // Not retried. Process.run fails on a missing or unexecutable file,
            // which another attempt a second later won't fix.
            return becomeBroken(.failedToStart("couldn't start: \(error.localizedDescription)"))
        }
        setState(.starting)
        send(.hello(protocol: ServiceProtocol.version, capabilities: granted.map(\.rawValue)))
        handshakeTimer = scheduler.after(timing.handshake) { [weak self] in
            guard let self, self.generation == generation, self.state == .starting else { return }
            self.process?.signal(SIGKILL)
        }
    }

    private func exited(_ termination: Termination, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        process = nil
        cancelRunTimers()
        if state == .stopping { return finishStop(keepState: false) }
        if let fatal { return becomeBroken(fatal) }
        crashed(termination)
    }

    private func crashed(_ termination: Termination) {
        let now = scheduler.now()
        if let since = runningSince, now - since >= timing.crashWindow { consecutive = 0 }
        runningSince = nil
        crashes = crashes.filter { now - $0 < timing.crashWindow } + [now]
        consecutive += 1
        guard crashes.count < timing.crashLimit else { return becomeBroken(termination) }
        let delay = Self.backoff(after: consecutive, timing: timing)
        setState(.restarting(after: delay))
        restartTimer = scheduler.after(delay) { [weak self] in
            guard let self, case .restarting = self.state else { return }
            self.restartTimer = nil
            self.spawn()
        }
    }

    // 1, 2, 4 … seconds for the first, second, third crash in a row, capped.
    static func backoff(after consecutive: Int, timing: Timing = Timing()) -> TimeInterval {
        let exponent = Double(max(consecutive - 1, 0))
        // Capped before exponentiating too, so a long-lived flaky service can't
        // overflow its way to infinity.
        return min(timing.backoffBase * pow(2, min(exponent, 30)), timing.backoffCap)
    }

    private func becomeBroken(_ termination: Termination) {
        cancelRunTimers()
        restartTimer?.cancel()
        restartTimer = nil
        setState(.broken(termination))
    }

    private func finishStop(keepState: Bool) {
        stopTimers.forEach { $0.cancel() }
        stopTimers = []
        if !keepState { setState(.stopped) }
        let completions = stopCompletions
        stopCompletions = []
        completions.forEach { $0() }
    }

    private func cancelRunTimers() {
        handshakeTimer?.cancel()
        pingTimer?.cancel()
        pongTimer?.cancel()
        handshakeTimer = nil
        pingTimer = nil
        pongTimer = nil
        outstandingPing = nil
    }

    // MARK: - Reading

    private func received(_ data: Data, generation: Int) {
        guard generation == self.generation, process != nil else { return }
        for piece in splitter.feed(data) {
            switch piece {
            case .oversized(let bytes):
                degrade("dropped a \(bytes)-byte line")
            case .line(let line):
                // A large line with no allowance left is dropped unparsed, so a
                // flood of big documents costs a counter rather than a parse
                // each. Small lines are parsed first, because a pong is exempt:
                // charging it would let a service that floods the host be
                // killed as a hang, when what it has done is lose messages.
                if line.count > ServiceProtocol.maxLineBytes, !hasToken() {
                    degrade("more than \(Int(timing.messagesPerSecond)) messages a second")
                    continue
                }
                let inbound = ServiceProtocol.decode(line)
                if case .message(.pong) = inbound { handle(inbound); continue }
                guard takeToken() else {
                    degrade("more than \(Int(timing.messagesPerSecond)) messages a second")
                    continue
                }
                handle(inbound)
            }
        }
    }

    private func handle(_ inbound: ServiceProtocol.Inbound) {
        switch inbound {
        case .ignored:
            break
        case .oversized(let bytes):
            degrade("dropped a \(bytes)-byte line")
        case .invalid(let why):
            onEvent(.problem(why))
        case .invalidDocument(let why):
            if state == .running { onEvent(.malformedDocument(why)) }
        case .message(let message):
            handle(message)
        }
    }

    private func handle(_ message: ServiceProtocol.ExtensionMessage) {
        // Nothing counts before `ready`: the extension hasn't yet agreed on
        // what the lines mean.
        guard state == .running else {
            guard state == .starting, case .ready(let version) = message else { return }
            guard version == ServiceProtocol.version else {
                fatal = .incompatible(protocol: version)
                process?.signal(SIGKILL)
                return
            }
            return becomeRunning()
        }
        switch message {
        case .ready:
            break
        case .document(let document):
            onEvent(.document(document))
        case .signal(let name, let value):
            guard let capability = ExtensionCapability.signal(name), granted.contains(capability) else {
                return onEvent(.problem("signal \"\(name)\" wasn't granted"))
            }
            onEvent(.signal(name: name, value: value))
        case .feed(let event):
            guard granted.contains(.feed) else { return onEvent(.problem("feed wasn't granted")) }
            onEvent(.feed(event: event))
        case .pong(let id):
            guard outstandingPing?.id == id else { return }
            pongTimer?.cancel()
            pongTimer = nil
            outstandingPing = nil
            forgaveSleep = false
            schedulePing()
        }
    }

    private func becomeRunning() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
        runningSince = scheduler.now()
        setState(.running)
        // The same values the environment already carries. Sent anyway so a
        // service has one place to read them from now and later, when a change
        // in Settings can reach it without a restart.
        send(.config(values: config))
        schedulePing()
    }

    // MARK: - Liveness

    private func schedulePing() {
        let generation = self.generation
        pingTimer = scheduler.after(timing.pingInterval) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pingTimer = nil
            self.ping()
        }
    }

    private func ping() {
        guard state == .running else { return }
        lastPingID += 1
        let id = lastPingID
        outstandingPing = (id, scheduler.now())
        send(.ping(id: id))
        let generation = self.generation
        pongTimer = scheduler.after(timing.pongTimeout) { [weak self] in
            guard let self, self.generation == generation, self.state == .running,
                  let outstanding = self.outstandingPing, outstanding.id == id else { return }
            self.pongTimer = nil
            // The timer fired far later than it was set for, so the whole
            // machine was suspended, extension included. Its pong is a wake
            // away rather than never coming, so it gets one more ping.
            let late = self.scheduler.now() - outstanding.sentAt
                > self.timing.pongTimeout + self.timing.sleepSlack
            if late && !self.forgaveSleep {
                self.forgaveSleep = true
                self.ping()
                return
            }
            // A hang. Killed outright rather than asked to stop: it has just
            // shown it isn't reading. The exit is then a crash like any other.
            self.process?.signal(SIGKILL)
        }
    }

    // MARK: - Limits

    private func hasToken() -> Bool {
        let now = scheduler.now()
        tokens = min(timing.messageBurst, tokens + max(now - tokensAt, 0) * timing.messagesPerSecond)
        tokensAt = now
        return tokens >= 1
    }

    private func takeToken() -> Bool {
        guard hasToken() else { return false }
        tokens -= 1
        return true
    }

    private func degrade(_ why: String) {
        guard !degraded else { return }
        degraded = true
        onEvent(.degraded(why))
    }

    // MARK: - Plumbing

    private func send(_ message: ServiceProtocol.HostMessage) {
        process?.write(ServiceProtocol.encode(message))
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        onEvent(.state(new))
    }
}

// MARK: - Live implementations

extension ServiceSupervisor {

    // A supervisor wired to real processes and real time, on its own queue.
    static func live(manifest: ExtensionManifest,
                     directory: String,
                     granted: [ExtensionCapability],
                     configValues: [String: String] = ConfigFile.read(),
                     onEvent: @escaping (Event) -> Void) -> ServiceSupervisor {
        let queue = DispatchQueue(label: "stack-nudge.service.\(manifest.id)")
        let environment = ExtensionRuntime.serviceEnvironment(for: manifest, config: configValues)
        // The declared keys that are set, exactly as the environment has them.
        let config = environment.filter { key, _ in manifest.config.contains { $0.key == key } }
        return ServiceSupervisor(
            id: manifest.id, directory: directory, granted: granted,
            environment: environment, config: config,
            executable: { ExtensionRuntime.resolveExecutable(manifest, in: directory) },
            spawner: LiveServiceSpawner(),
            scheduler: DispatchServiceScheduler(queue: queue),
            perform: { queue.async(execute: $0) },
            onEvent: onEvent)
    }
}

final class DispatchServiceScheduler: ServiceScheduler {

    private final class Timer: ServiceTimer {
        let item: DispatchWorkItem
        init(_ item: DispatchWorkItem) { self.item = item }
        func cancel() { item.cancel() }
    }

    private let queue: DispatchQueue

    init(queue: DispatchQueue) { self.queue = queue }

    func now() -> TimeInterval { Date().timeIntervalSince1970 }

    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ServiceTimer {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return Timer(item)
    }
}

struct LiveServiceSpawner: ServiceSpawner {

    struct SpawnFailure: Error, LocalizedError {
        let errorDescription: String?
    }

    func spawn(executable: String,
               directory: String,
               environment: [String: String],
               onOutput: @escaping (Data) -> Void,
               onExit: @escaping (ServiceSupervisor.Termination) -> Void) throws -> ServiceProcess {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.currentDirectoryURL = URL(fileURLWithPath: directory)
        // Replaces ours, as for a view extension: see ExtensionRuntime.environment.
        task.environment = environment
        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        // Discarded, as the docs promise view extensions: scripts may print
        // secrets there, and an undrained pipe would block the child.
        task.standardError = FileHandle.nullDevice

        // A writer that outlives the child gets EPIPE back instead of a SIGPIPE
        // that would take the whole app down.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Reading starts, and the exit handler is in place, before the child
        // exists: a child that prints and exits at once must lose neither.
        let process = LiveServiceProcess(task: task, input: input, output: output,
                                          onOutput: onOutput, onExit: onExit)
        guard process.prepare() else {
            throw SpawnFailure(errorDescription: "couldn't open its output")
        }
        do {
            try task.run()
        } catch {
            process.abandon()
            throw error
        }
        process.started()
        return process
    }
}

// One child and its two pipes. stdout is read with a dispatch source on a dup'd
// non-blocking descriptor, as ProcessOutput does and for the same reason: a
// blocking read can never be abandoned, and a grandchild holding the write end
// would keep it open forever.
final class LiveServiceProcess: ServiceProcess {

    private let task: Process
    private let input: Pipe
    private let output: Pipe
    private let onOutput: (Data) -> Void
    private let onExit: (ServiceSupervisor.Termination) -> Void

    // Reads and the exit run on one serial queue, which is what guarantees all
    // output is handed over before the exit is.
    private let io = DispatchQueue(label: "stack-nudge.service.io")
    // Writes block while the child isn't reading stdin. They get their own
    // queue so that never holds up reading, and so the descriptor is closed in
    // order behind any write still pending rather than out from under it.
    private let writer = DispatchQueue(label: "stack-nudge.service.stdin")

    private var source: DispatchSourceRead?
    private var readFD: Int32 = -1
    private var reading = false          // io queue only, once started
    private var writable = true          // writer queue only

    // Guards the pid and group against the exit, which arrives on a thread of
    // Foundation's choosing.
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var group: pid_t = -1
    private var terminated = false
    // Opened once the pid and group are recorded. The exit can arrive before
    // `started` has run, and cleaning up the group needs to know which group.
    private let launched = DispatchSemaphore(value: 0)

    init(task: Process, input: Pipe, output: Pipe,
         onOutput: @escaping (Data) -> Void,
         onExit: @escaping (ServiceSupervisor.Termination) -> Void) {
        self.task = task
        self.input = input
        self.output = output
        self.onOutput = onOutput
        self.onExit = onExit
    }

    fileprivate func prepare() -> Bool {
        let fd = dup(output.fileHandleForReading.fileDescriptor)
        guard fd >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        readFD = fd
        reading = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [weak self] in
            guard let self, self.reading else { return }
            if !self.readOnce() { self.stopReading() }
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()

        // Captures this object strongly, and the task holds the handler, so it
        // clears itself to break the cycle once it has run.
        task.terminationHandler = { [self] task in
            task.terminationHandler = nil
            let termination: ServiceSupervisor.Termination = task.terminationReason == .uncaughtSignal
                ? .signalled(task.terminationStatus) : .exited(task.terminationStatus)
            lock.lock()
            terminated = true
            lock.unlock()
            io.async { self.finish(termination) }
        }
        return true
    }

    // Recorded whether or not the child has already exited. A `run` that
    // starts `helper &` and dies at once has to have its group cleaned up just
    // the same, and skipping this when the exit won the race used to orphan
    // the helper.
    fileprivate func started() {
        lock.lock()
        pid = task.processIdentifier
        // Foundation spawns the child as the leader of a new process group, so
        // the group's id is the child's pid. Read back while the child is
        // there to ask; once it has been reaped getpgid fails, and the pid is
        // the answer. Ours is never used: killpg on our own group would take
        // out the app.
        let readBack = getpgid(pid)
        let childGroup = readBack > 0 ? readBack : pid
        group = childGroup > 0 && childGroup != getpgrp() ? childGroup : -1
        lock.unlock()
        launched.signal()
    }

    fileprivate func abandon() {
        task.terminationHandler = nil
        io.async { self.stopReading() }
        closePipes()
    }

    func write(_ data: Data) {
        writer.async { [self] in
            guard writable, !data.isEmpty else { return }
            let fd = input.fileHandleForWriting.fileDescriptor
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 {
                        offset += n
                    } else if n < 0, errno == EINTR {
                        continue
                    } else {
                        break        // EPIPE: the child has gone, and its exit is on the way
                    }
                }
            }
        }
    }

    func signal(_ signal: Int32) {
        lock.lock()
        defer { lock.unlock() }
        // Never a reaped pid: the number may already belong to something else.
        guard !terminated, pid > 0 else { return }
        if group > 0 { killpg(group, signal) } else { kill(pid, signal) }
    }

    // One read. False at EOF or on an error, when there is nothing more to wait
    // for on this descriptor.
    private func readOnce() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { Foundation.read(readFD, $0.baseAddress, $0.count) }
        if count > 0 {
            onOutput(Data(buffer[0..<count]))
            return true
        }
        return count < 0 && (errno == EAGAIN || errno == EINTR)
    }

    private func stopReading() {
        guard reading else { return }
        reading = false
        source?.cancel()
    }

    // On the io queue, after any read already queued there.
    private func finish(_ termination: ServiceSupervisor.Termination) {
        // `started` runs straight after `run` returns, so this is a wait of
        // moments at most, and only when the child died first.
        launched.wait()
        // Whatever the child wrote is in the pipe by now, so reading until
        // EAGAIN has seen all of it, even with a grandchild holding the write
        // end open. Bounded, because such a grandchild could keep it fed.
        var budget = ServiceProtocol.maxDocumentLineBytes / (64 * 1024) + 2
        while reading, budget > 0 {
            budget -= 1
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Foundation.read(readFD, $0.baseAddress, $0.count) }
            if count > 0 { onOutput(Data(buffer[0..<count])); continue }
            if count < 0, errno == EINTR { continue }
            break
        }
        stopReading()

        // Anything the child left running in its group goes with it, which is
        // what keeps a service from leaving a `sleep` or a scanner behind. The
        // group id can't be reused while members remain, and with none left
        // this finds nobody.
        lock.lock()
        if group > 0 { killpg(group, SIGKILL) }
        group = -1
        lock.unlock()

        closePipes()
        onExit(termination)
    }

    // The Pipe's own FileHandles don't close promptly when they deallocate,
    // which ProcessOutput measured as one leaked descriptor per call. The write
    // end of stdin closes on the writer queue, behind any write still pending.
    private func closePipes() {
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        writer.async { [self] in
            writable = false
            try? input.fileHandleForWriting.close()
        }
    }
}
