import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A worker process the session host started, known by the role it was
/// spawned for and an instance key (a build ID, an agent session ID; nil for
/// the shared environment, diagnostics and log-reader workers).
final class WorkerProcess: @unchecked Sendable {
    let role: WorkerRole
    let key: String?
    let channel: WorkerChannel
    private let lock = PthreadLock()
    @objc dynamic private var inFlight = 0
    @objc dynamic private var idleSince = Date()

    init(role: WorkerRole, key: String?, channel: WorkerChannel) {
        self.role = role
        self.key = key
        self.channel = channel
    }

    /// Forwards a request; `taskID` tells the worker which task it serves,
    /// `resumed` that the host is starting it again after a restart.
    func call(
        _ request: WireRequest,
        descriptors: [OwnedDescriptor],
        taskID: TaskID? = nil,
        resumed: Bool = false,
    ) async throws -> (WireReply, [OwnedDescriptor]) {
        lock.withLock { inFlight += 1 }
        defer { lock.withLock { inFlight -= 1; idleSince = Date() } }
        return try await channel.call(request, descriptors: descriptors, taskID: taskID, resumed: resumed)
    }

    @objc dynamic func idleFor() -> TimeInterval {
        lock.withLock { inFlight > 0 ? 0 : Date().timeIntervalSince(idleSince) }
    }
}

/// Starts workers on demand from `<install root>/usr/libexec/apelin/`,
/// mobile roles as uid/gid 501 set before exec, each with its own
/// socketpair; records the role at spawn and never asks the worker; stops a
/// worker idle with no task for `idleTimeout`.
actor WorkerSupervisor {
    static let idleTimeout: TimeInterval = 60
    static let readyTimeout: UInt64 = 10

    struct Key: Hashable {
        var role: WorkerRole
        var instance: String?
    }

    private let installRoot: String
    private let home: String
    private let queue = DispatchQueue(label: "wiki.qaq.apelind.workers")
    private var workers: [Key: WorkerProcess] = [:]
    private var starting: [Key: Task<WorkerProcess, Error>] = [:]

    /// Set by the host: requests a worker sends, events it emits, and its exit.
    private var requestHandler: (@Sendable (WorkerProcess, ChannelRequest) async -> (WireReply, [OwnedDescriptor]))?
    private var eventHandler: (@Sendable (WorkerProcess, ChannelFrame) -> Void)?
    private var exitHandler: (@Sendable (WorkerProcess) -> Void)?
    private var busy: (@Sendable (WorkerRole, String?) async -> Bool)?

    init(installRoot: String, home: String) {
        self.installRoot = installRoot
        self.home = home
    }

    func configure(
        onRequest: @escaping @Sendable (WorkerProcess, ChannelRequest) async -> (WireReply, [OwnedDescriptor]),
        onEvent: @escaping @Sendable (WorkerProcess, ChannelFrame) -> Void,
        onExit: @escaping @Sendable (WorkerProcess) -> Void,
        isBusy: @escaping @Sendable (WorkerRole, String?) async -> Bool,
    ) {
        requestHandler = onRequest
        eventHandler = onEvent
        exitHandler = onExit
        busy = isBusy
    }

    var count: Int {
        workers.count
    }

    func existing(_ role: WorkerRole, instance: String? = nil) -> WorkerProcess? {
        workers[Key(role: role, instance: instance)]
    }

    /// The running worker for the role and instance, started if needed.
    func worker(_ role: WorkerRole, instance: String? = nil) async throws -> WorkerProcess {
        let key = Key(role: role, instance: instance)
        if let worker = workers[key], !worker.channel.isClosed {
            return worker
        }
        if let pending = starting[key] {
            return try await pending.value
        }
        let task = Task { try await self.start(key) }
        starting[key] = task
        defer { starting[key] = nil }
        let worker = try await task.value
        workers[key] = worker
        return worker
    }

    /// Closes workers idle past the timeout with no task left.
    func sweep() async {
        for (key, worker) in workers where worker.idleFor() > Self.idleTimeout {
            if await busy?(key.role, key.instance) == true {
                continue
            }
            // While the check was awaited the worker may have taken a request,
            // or exited and been replaced by a new one under the same key.
            guard workers[key] === worker, worker.idleFor() > Self.idleTimeout else { continue }
            worker.channel.close()
            workers[key] = nil
        }
    }

    func stopAll() {
        workers.values.forEach { $0.channel.close() }
        workers.removeAll()
    }

    private func start(_ key: Key) async throws -> WorkerProcess {
        let (local, remote) = try WorkerChannel.makePair()
        defer { close(remote) }
        let channel = WorkerChannel(adopting: local)
        let ready = ReadySignal()
        channel.onControl { frame in
            if frame.header.name == WorkerControl.ready {
                ready.fire()
            }
        }

        let path = installRoot == "/" ? key.role.relativePath : installRoot + key.role.relativePath
        let environment = [
            "HOME=\(home)",
            "PATH=\(installRoot == "/" ? "" : installRoot)/usr/bin:/usr/bin:/bin",
            "DISABLE_TWEAKS=1",
            "APELIN_ROLE=\(key.role.rawValue)",
        ]
        let pid: pid_t
        do {
            pid = try spawnProcess(
                path: path,
                arguments: [key.role.executableName],
                environment: environment,
                channel: remote,
                identity: key.role.runsAsRoot ? nil : .mobile,
            )
        } catch {
            channel.close()
            throw ApelinError(.unavailable, "\(error)")
        }

        let worker = WorkerProcess(role: key.role, key: key.instance, channel: channel)
        let onRequest = requestHandler
        let onEvent = eventHandler
        let onExit = exitHandler
        channel.onRequest { request in
            guard let onRequest else {
                return (.failure(request.request.requestID, .unimplemented(request.request.operation)), [])
            }
            return await onRequest(worker, request)
        }
        channel.onEvent { frame in onEvent?(worker, frame) }
        channel.onClose { [weak self] in
            onExit?(worker)
            Task { await self?.forget(worker) }
        }
        reapWhenExited(pid, queue: queue) { status in
            if status != 0 {
                NSLog("apelind-session: %@ exited (status %d)", key.role.executableName, status)
            }
        }
        channel.start()

        do {
            try channel.sendControl(
                WorkerControl.assign,
                body: WorkerAssignment(role: key.role, installRoot: installRoot, home: home, sessionID: key.instance),
            )
        } catch {
            channel.close()
            kill(pid, SIGKILL)
            throw error
        }
        guard await ready.wait(seconds: Self.readyTimeout) else {
            channel.close()
            kill(pid, SIGKILL)
            throw ApelinError(.unavailable, "A background process did not start in time. Try again.")
        }
        return worker
    }

    private func forget(_ worker: WorkerProcess) {
        let key = Key(role: worker.role, instance: worker.key)
        if workers[key] === worker {
            workers[key] = nil
        }
    }
}

/// Fires once; `wait` answers whether it fired in time.
private final class ReadySignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    @objc dynamic func fire() {
        semaphore.signal()
    }

    func wait(seconds: UInt64) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: self.semaphore.wait(timeout: .now() + .seconds(Int(seconds))) == .success,
                )
            }
        }
    }
}
