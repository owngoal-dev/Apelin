@_exported import ApelinToolCore
import Darwin
import Foundation

/// The host's end of one extension process: spawns it, says `hello`, sends
/// calls and cancels, and turns every way the process can fail into a failed
/// call rather than a thrown error or a hang.
///
/// - A call waits in a queue while `maxConcurrentCalls` are in flight; its
///   timeout runs from the moment it is made, queued or not.
/// - A timed-out or cancelled call answers its caller at once and sends
///   `cancel`. Its slot stays taken until the extension ends the call; if it
///   has not within `cancelGrace`, the process is stopped.
/// - A frame that does not parse, is too long, carries the wrong protocol
///   version or is of a type an extension may not send stops the process,
///   and every call in flight fails with that reason.
/// - A process that exits fails every call in flight with
///   `extensionCrashed`, its exit status and the last lines of its stderr.
///
/// stderr is never parsed: each line goes to `logHandler`, and the last few
/// are kept for crash reports. Call `terminate()` when done; the client
/// keeps itself alive while its process runs.
public final class ToolHostClient: @unchecked Sendable {
    public let configuration: Configuration
    private let recheck: (validated: ValidatedToolManifest, policy: ToolManifestPolicy)?

    private enum State { case idle, starting, running, stopped }

    private final class Call {
        let frame: ToolFrame
        let attachments: [(id: String, file: ToolOutgoingAttachment)]
        let continuation: CheckedContinuation<ToolCallOutcome, Never>
        var timer: DispatchWorkItem?
        @objc dynamic var sent = false

        init(
            frame: ToolFrame,
            attachments: [(id: String, file: ToolOutgoingAttachment)],
            continuation: CheckedContinuation<ToolCallOutcome, Never>,
        ) {
            self.frame = frame
            self.attachments = attachments
            self.continuation = continuation
        }
    }

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "ApelinToolHost.write")
    private let timerQueue = DispatchQueue(label: "ApelinToolHost.timers")
    private var state = State.idle
    private var process: ExtensionProcess?
    private var writer: LineWriter?
    private var channel: ToolAttachmentChannel?
    @objc private dynamic var negotiatedVersion = ToolProtocol.version
    @objc private dynamic var concurrency = 1
    @objc private dynamic var outboundFrameLimit: Int
    @objc private dynamic var helloTools: [String] = []
    private var helloWaiter: CheckedContinuation<ToolFrame, Error>?
    private var calls: [String: Call] = [:]
    @objc private dynamic var queue: [String] = []
    @objc private dynamic var inFlight = 0
    /// Calls answered to their caller (timeout, cancel) that the extension
    /// has not ended yet, each with its grace timer.
    private var abandoned: [String: DispatchWorkItem] = [:]
    @objc private dynamic var cancelledEarly = Set<String>()
    private var stopReason: ToolCallFailure?
    private var exit: ExtensionExit?
    private var exitWaiters: [CheckedContinuation<ExtensionExit, Never>] = []
    @objc private dynamic var logTail: [String] = []
    @objc private dynamic var counter = 0
    private let stderrFinished = DispatchSemaphore(value: 0)

    public init(configuration: Configuration) {
        self.configuration = configuration
        recheck = nil
        outboundFrameLimit = configuration.limits.maxFrameBytes
    }

    /// A client for an installed extension. The executable is checked again
    /// against `policy` right before it is spawned.
    public init(
        validated: ValidatedToolManifest,
        policy: ToolManifestPolicy = .init(),
        environment: [String: String] = Configuration.defaultEnvironment(),
        limits: ToolProtocolLimits = .init(),
        host: ToolPeer = ToolPeer(name: "apelin", version: "0"),
        runAs: ToolProcessIdentity? = nil,
        logHandler: (@Sendable (String) -> Void)? = nil,
    ) {
        configuration = Configuration(
            executable: validated.executablePath,
            environment: environment,
            limits: limits,
            host: host,
            manifest: validated.manifest,
            runAs: runAs,
            logHandler: logHandler,
        )
        recheck = (validated, policy)
        outboundFrameLimit = limits.maxFrameBytes
    }

    deinit {
        if let process, exit == nil {
            kill(-process.pid, SIGKILL)
        }
    }

    private var limits: ToolProtocolLimits {
        configuration.limits
    }

    @objc public dynamic var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .running
    }

    /// How the process ended, once it has.
    public var exitStatus: ExtensionExit? {
        lock.lock()
        defer { lock.unlock() }
        return exit
    }

    // MARK: - Start

    /// Spawns the extension and exchanges `hello`.
    @discardableResult
    public func start() async throws -> ToolExtensionHello {
        let fresh = lock.withLock {
            guard state == .idle else { return false }
            state = .starting
            return true
        }
        guard fresh else {
            throw ToolCallFailure(
                .extensionNotRunning,
                "this client has already been started; create a new client to start the extension again",
            )
        }

        let spawned: ExtensionProcess
        do {
            if let recheck {
                try ToolManifestValidator.recheckExecutable(recheck.validated, policy: recheck.policy)
            }
            spawned = try ExtensionProcess.spawn(
                executable: configuration.executable,
                arguments: configuration.arguments,
                environment: configuration.environment,
                allowRoot: configuration.allowRoot,
                runAs: configuration.runAs,
            )
        } catch {
            lock.withLock { state = .stopped }
            throw ToolCallFailure(.extensionNotRunning, "\(error)")
        }

        let channel = ToolAttachmentChannel(
            socket: spawned.attachmentSocket,
            maxAttachmentBytes: limits.maxAttachmentBytes,
            maxPending: limits.maxPendingAttachments,
        )
        lock.withLock {
            process = spawned
            writer = LineWriter(descriptor: spawned.stdinWrite)
            self.channel = channel
        }
        channel.start()
        startThread(named: "ApelinToolHost.stdout") { [self] in readFrames(spawned.stdoutRead) }
        startThread(named: "ApelinToolHost.stderr") { [self] in readLog(spawned.stderrRead) }

        var hello = ToolFrame(protocolVersion: ToolProtocol.version, type: .hello, requestID: "hello")
        hello.supportedVersions = ToolProtocol.supportedVersions
        hello.peer = configuration.host
        hello.maxConcurrentCalls = limits.maxConcurrentCalls
        hello.maxFrameBytes = limits.maxFrameBytes

        let reply: ToolFrame
        do {
            reply = try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if state != .starting {
                    let reason = stopReason ?? ToolCallFailure(.extensionCrashed, "the extension ended before hello")
                    lock.unlock()
                    continuation.resume(throwing: reason)
                    return
                }
                helloWaiter = continuation
                lock.unlock()
                timerQueue.asyncAfter(deadline: .now() + limits.helloTimeout) { [self] in
                    failHello(ToolCallFailure(
                        .timeout,
                        "The tool extension did not respond within \(limits.helloTimeout) seconds. Try again.",
                    ))
                }
                write(hello)
            }
        } catch {
            stop(error as? ToolCallFailure ?? ToolCallFailure(.badFrame, "\(error)"))
            throw error
        }

        func reject(_ code: ToolErrorCode, _ message: String) -> ToolCallFailure {
            let failure = ToolCallFailure(code, message)
            stop(failure)
            return failure
        }
        if reply.type == .error {
            let payload = reply.error
                ?? ToolErrorPayload(code: .badFrame, message: "the extension sent an error with no message")
            throw reject(payload.code, payload.message)
        }
        guard reply.type == .hello, ToolProtocol.supportedVersions.contains(reply.protocolVersion) else {
            throw reject(.protocolVersionMismatch, "the extension answered hello with version \(reply.protocolVersion)")
        }
        let peer = reply.peer ?? ToolPeer(name: "", version: "")
        let tools = reply.tools ?? []
        if let manifest = configuration.manifest {
            guard peer.name == manifest.id else {
                throw reject(
                    .badFrame,
                    "the extension identifies itself as \(peer.name), but the manifest names \(manifest.id)",
                )
            }
            if let missing = manifest.tools.map(\.name).first(where: { !tools.contains($0) }) {
                throw reject(.badFrame, "the manifest declares \(missing), the extension does not implement it")
            }
        }

        let (alive, agreed, reason) = lock.withLock { () -> (Bool, Int, ToolCallFailure?) in
            negotiatedVersion = reply.protocolVersion
            concurrency = max(1, min(limits.maxConcurrentCalls, reply.maxConcurrentCalls ?? limits.maxConcurrentCalls))
            if let theirs = reply.maxFrameBytes, theirs > 0 {
                outboundFrameLimit = min(limits.maxFrameBytes, theirs)
            }
            helloTools = tools
            let alive = state == .starting
            if alive {
                state = .running
            }
            return (alive, concurrency, stopReason)
        }
        guard alive else { throw reason ?? ToolCallFailure(.extensionCrashed, "the extension ended after hello") }
        return ToolExtensionHello(
            protocolVersion: reply.protocolVersion,
            peer: peer,
            tools: tools,
            maxConcurrentCalls: agreed,
        )
    }

    private func failHello(_ failure: ToolCallFailure) {
        lock.lock()
        let waiter = helloWaiter
        helloWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: failure)
    }

    // MARK: - Calls

    /// Calls `tool`. Never throws: every failure, including the extension
    /// crashing, comes back as `.failure`. Cancelling the Swift task sends
    /// `cancel` and returns `.failure(.cancelled)` at once.
    ///
    /// `timeout` defaults to the manifest's `timeoutSeconds` for the tool,
    /// else `defaultCallTimeout`, and is capped at `maxCallTimeout`.
    public func call(
        tool: String,
        arguments: JSONValue = .object([:]),
        attachments: [ToolOutgoingAttachment] = [],
        timeout: TimeInterval? = nil,
        requestID: String? = nil,
    ) async -> ToolCallOutcome {
        let id = requestID ?? nextID(prefix: "c")
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                enqueue(
                    id: id,
                    tool: tool,
                    arguments: arguments,
                    attachments: attachments,
                    timeout: timeout,
                    continuation: continuation,
                )
            }
        } onCancel: {
            cancel(requestID: id)
        }
    }

    /// Cancels a call by its request ID. Its caller gets
    /// `.failure(.cancelled)`; the extension gets `cancel`.
    @objc public dynamic func cancel(requestID: String) {
        abandon(requestID, ToolCallFailure(.cancelled, "cancelled"), early: true)
    }

    private func enqueue(
        id: String,
        tool: String,
        arguments: JSONValue,
        attachments: [ToolOutgoingAttachment],
        timeout: TimeInterval?,
        continuation: CheckedContinuation<ToolCallOutcome, Never>,
    ) {
        func refuse(_ code: ToolErrorCode, _ message: String) {
            continuation.resume(returning: .failure(ToolCallFailure(code, message)))
        }
        guard ToolFrame.isValidRequestID(id) else { return refuse(.badFrame, "invalid request ID") }
        let descriptor = configuration.manifest?.tool(named: tool)

        lock.lock()
        if cancelledEarly.remove(id) != nil {
            lock.unlock()
            return refuse(.cancelled, "cancelled")
        }
        guard state == .running else {
            let reason = stopReason
            lock.unlock()
            return refuse(
                .extensionNotRunning,
                reason.map { "the extension is not running (\($0))" } ?? "the extension is not running",
            )
        }
        let known = configuration.manifest != nil ? descriptor != nil : helloTools.contains(tool)
        let duplicate = calls[id] != nil || abandoned[id] != nil
        let version = negotiatedVersion
        let frameLimit = outboundFrameLimit
        lock.unlock()

        guard known else { return refuse(.unknownTool, "no tool named \(tool)") }
        guard !duplicate else { return refuse(.duplicateRequest, "\(id) is already in flight") }
        if let schema = descriptor?.parameters, let problem = ToolSchemaValidator.problem(with: arguments, against: schema) {
            return refuse(.invalidArguments, problem)
        }
        guard attachments.count <= limits.maxAttachmentsPerFrame else {
            return refuse(.attachmentRejected, "more than \(limits.maxAttachmentsPerFrame) attachments")
        }

        var outgoing: [(id: String, file: ToolOutgoingAttachment)] = []
        var references: [ToolAttachmentReference] = []
        for file in attachments {
            var info = stat()
            guard fstat(file.descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_size <= off_t(limits.maxAttachmentBytes)
            else {
                return refuse(
                    .attachmentRejected,
                    "an attachment is not a regular file under \(limits.maxAttachmentBytes) bytes",
                )
            }
            let attachmentID = nextID(prefix: "a")
            outgoing.append((attachmentID, file))
            references.append(ToolAttachmentReference(
                id: attachmentID,
                argument: file.argument,
                mimeType: file.mimeType,
                name: file.name,
                byteCount: Int(info.st_size),
            ))
        }

        var frame = ToolFrame(protocolVersion: version, type: .call, requestID: id)
        frame.tool = tool
        frame.args = arguments
        frame.attachments = references.isEmpty ? nil : references
        guard let encoded = try? ToolFrameCodec.encode(frame), encoded.count - 1 <= frameLimit else {
            return refuse(.frameTooLarge, "the call is larger than a frame may be")
        }

        let call = Call(frame: frame, attachments: outgoing, continuation: continuation)
        let seconds = min(timeout ?? descriptor?.timeoutSeconds ?? limits.defaultCallTimeout, limits.maxCallTimeout)
        let timer = DispatchWorkItem { [weak self] in
            self?.abandon(id, ToolCallFailure(.timeout, "no result within \(seconds) seconds"), early: false)
        }
        call.timer = timer

        lock.lock()
        guard state == .running else {
            lock.unlock()
            return refuse(.extensionNotRunning, "the extension is not running")
        }
        calls[id] = call
        queue.append(id)
        lock.unlock()
        timerQueue.asyncAfter(deadline: .now() + seconds, execute: timer)
        pump()
    }

    /// Sends queued calls while there are free slots.
    @objc private dynamic func pump() {
        while true {
            lock.lock()
            guard state == .running, inFlight < concurrency, !queue.isEmpty else {
                lock.unlock()
                return
            }
            let id = queue.removeFirst()
            guard let call = calls[id] else {
                lock.unlock()
                continue
            }
            call.sent = true
            inFlight += 1
            let channel = channel
            lock.unlock()

            writeQueue.async { [self] in
                for attachment in call.attachments {
                    do {
                        guard let channel else { throw ToolAttachmentError.rejected("no attachment socket") }
                        try channel.send(id: attachment.id, descriptor: attachment.file.descriptor)
                    } catch {
                        // The extension never saw the call: free the slot and
                        // fail it here.
                        finish(id, .failure(ToolCallFailure(.attachmentRejected, "\(error)")))
                        return
                    }
                }
                lock.lock()
                let writer = writer
                lock.unlock()
                if let data = try? ToolFrameCodec.encode(call.frame) {
                    writer?.write(data)
                }
                // A failed write means the process is gone; the stdout
                // reader sees the end and fails the call with the reason.
            }
        }
    }

    /// Answers a call's caller early (timeout or cancel). A sent call keeps
    /// its slot until the extension ends it, or the grace runs out.
    private func abandon(_ id: String, _ failure: ToolCallFailure, early: Bool) {
        lock.lock()
        guard let call = calls.removeValue(forKey: id) else {
            if early, state == .running || state == .starting, abandoned[id] == nil {
                if cancelledEarly.count > 1024 {
                    cancelledEarly.removeAll()
                }
                cancelledEarly.insert(id)
            }
            lock.unlock()
            return
        }
        call.timer?.cancel()
        queue.removeAll { $0 == id }
        var sendCancel = false
        if call.sent, state == .running {
            let grace = DispatchWorkItem { [weak self] in self?.graceExpired(id) }
            abandoned[id] = grace
            timerQueue.asyncAfter(deadline: .now() + limits.cancelGrace, execute: grace)
            sendCancel = true
        }
        let version = negotiatedVersion
        lock.unlock()
        if sendCancel {
            write(ToolFrame(protocolVersion: version, type: .cancel, requestID: id))
        }
        call.continuation.resume(returning: .failure(failure))
    }

    @objc private dynamic func graceExpired(_ id: String) {
        lock.lock()
        let stuck = abandoned[id] != nil
        lock.unlock()
        if stuck {
            stop(ToolCallFailure(
                .extensionTerminated,
                "call \(id) did not end within \(limits.cancelGrace) seconds of its cancel; the extension was stopped",
            ))
        }
    }

    /// Ends a call that is still waiting for its caller.
    private func finish(_ id: String, _ outcome: ToolCallOutcome) {
        lock.lock()
        let call = calls.removeValue(forKey: id)
        call?.timer?.cancel()
        if call?.sent == true {
            inFlight -= 1
        }
        // Abandoned while its result or attachments were being handled: the
        // extension has ended the call, or never saw it, so no cancel answer
        // will come to clear it.
        if call == nil, let grace = abandoned.removeValue(forKey: id) {
            grace.cancel()
            inFlight -= 1
        }
        lock.unlock()
        call?.continuation.resume(returning: outcome)
        pump()
    }

    // MARK: - Frames from the extension

    @objc private dynamic func readFrames(_ descriptor: Int32) {
        let reader = LineReader(descriptor: descriptor, maxLineBytes: limits.maxFrameBytes)
        loop: while true {
            switch reader.next() {
            case let .line(line):
                receive(line)
            case .oversized:
                stop(ToolCallFailure(
                    .frameTooLarge,
                    "the extension sent a frame longer than \(limits.maxFrameBytes) bytes",
                ))
            case .endOfFile:
                break loop
            }
        }
        close(descriptor)
        processEnded()
    }

    private func receive(_ line: Data) {
        let frame: ToolFrame
        do {
            frame = try ToolFrameCodec.decode(line)
        } catch {
            stop(ToolCallFailure(.badFrame, "the extension sent a frame that does not parse"))
            return
        }

        lock.lock()
        let currentState = state
        let waiter = helloWaiter
        let version = negotiatedVersion
        let answersHello = currentState == .starting && (frame.requestID == "hello" || frame.requestID == nil)
            && (frame.type == .hello || frame.type == .error)
        if answersHello {
            helloWaiter = nil
        }
        lock.unlock()

        if currentState == .starting {
            guard answersHello else {
                stop(ToolCallFailure(.badFrame, "the extension sent \(frame.type.rawValue) before answering hello"))
                return
            }
            waiter?.resume(returning: frame)
            return
        }
        guard currentState == .running else { return }
        guard frame.protocolVersion == version else {
            stop(ToolCallFailure(
                .protocolVersionMismatch,
                "the extension sent protocol version \(frame.protocolVersion), but version \(version) was negotiated",
            ))
            return
        }
        switch frame.type {
        case .result, .error:
            guard let id = frame.requestID else {
                log("extension reported an error for no request: \(frame.error?.message ?? "")")
                return
            }
            end(id, frame)
        case .hello, .call, .cancel:
            stop(ToolCallFailure(.badFrame, "an extension does not send \(frame.type.rawValue)"))
        }
    }

    /// A `result` or `error` for `id`.
    private func end(_ id: String, _ frame: ToolFrame) {
        let attachmentIDs = (frame.content ?? []).compactMap { content -> String? in
            if case let .attachment(reference) = content {
                return reference.id
            }
            return nil
        }
        lock.lock()
        if let timer = abandoned.removeValue(forKey: id) {
            timer.cancel()
            inFlight -= 1
            let channel = self.channel
            lock.unlock()
            channel?.discard(ids: attachmentIDs)
            pump()
            return
        }
        guard let call = calls[id], call.sent else {
            lock.unlock()
            log("ignored \(frame.type.rawValue) for unknown request \(id)")
            return
        }
        let channel = channel
        lock.unlock()

        let outcome: ToolCallOutcome
        if frame.type == .error {
            let payload = frame.error
                ?? ToolErrorPayload(code: .unknown, message: "the extension sent an error with no message")
            outcome = .failure(ToolCallFailure(payload.code, payload.message))
        } else if attachmentIDs.count > limits.maxAttachmentsPerFrame {
            channel?.discard(ids: attachmentIDs)
            outcome = .failure(ToolCallFailure(
                .attachmentRejected,
                "the result names more than \(limits.maxAttachmentsPerFrame) attachments",
            ))
        } else {
            var items: [ToolResultItem] = []
            var failure: ToolCallFailure?
            for content in frame.content ?? [] {
                switch content {
                case let .text(text):
                    items.append(.text(text))
                case let .attachment(reference):
                    guard failure == nil, let channel else {
                        failure = failure ?? ToolCallFailure(.attachmentRejected, "no attachment socket")
                        continue
                    }
                    switch channel.claim(reference, timeout: limits.attachmentWait) {
                    case let .success(file): items.append(.file(file))
                    case let .failure(error): failure = ToolCallFailure(.attachmentRejected, error.description)
                    }
                }
            }
            if let failure {
                channel?.discard(ids: attachmentIDs)
                outcome = .failure(failure)
            } else {
                outcome = .success(ToolCallResult(content: items))
            }
        }
        finish(id, outcome)
    }

    // MARK: - stderr

    @objc private dynamic func readLog(_ descriptor: Int32) {
        let reader = LineReader(descriptor: descriptor, maxLineBytes: limits.maxLogLineBytes)
        loop: while true {
            switch reader.next() {
            case let .line(line):
                log(String(decoding: line, as: UTF8.self), fromExtension: true)
            case .oversized:
                log("(a log line longer than \(limits.maxLogLineBytes) bytes was dropped)", fromExtension: true)
            case .endOfFile:
                break loop
            }
        }
        close(descriptor)
        stderrFinished.signal()
    }

    @objc private dynamic func log(_ line: String, fromExtension: Bool = false) {
        if fromExtension {
            lock.lock()
            logTail.append(line)
            if logTail.count > limits.logTailLines {
                logTail.removeFirst(logTail.count - limits.logTailLines)
            }
            lock.unlock()
        }
        configuration.logHandler?(fromExtension ? line : "[host] \(line)")
    }

    // MARK: - Stopping

    /// Stops the extension: closes its stdin, which a well-behaved one
    /// answers by exiting, and kills it if it is still there a second after
    /// `cancelGrace` (what a server gives calls in flight to end). Calls in
    /// flight fail with `extensionTerminated` at once.
    /// Returns once the process has been reaped.
    @discardableResult
    public func terminate() async -> ExtensionExit? {
        let started = lock.withLock { process != nil }
        guard started else { return nil }
        stop(ToolCallFailure(.extensionTerminated, "the host stopped the extension"), gently: true)
        return await waitForExit()
    }

    /// Waits for the process to end on its own.
    public func waitForExit() async -> ExtensionExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exit {
                lock.unlock()
                continuation.resume(returning: exit)
            } else {
                exitWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Records why the process is going, fails every call with it, and stops
    /// the process. The first reason wins.
    private func stop(_ reason: ToolCallFailure, gently: Bool = false) {
        lock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        let winner = stopReason ?? reason
        let wasRunning = state == .running || state == .starting
        state = .stopped
        let pid = process?.pid
        let alreadyExited = exit != nil
        lock.unlock()
        failEverything(with: winner)
        closeStdin()
        guard wasRunning, let pid, !alreadyExited else { return }
        if gently {
            timerQueue.asyncAfter(deadline: .now() + limits.cancelGrace + 1) { [self] in
                lock.lock()
                let exited = exit != nil
                lock.unlock()
                if !exited {
                    kill(-pid, SIGKILL)
                }
            }
        } else {
            kill(-pid, SIGKILL)
        }
    }

    private func failEverything(with reason: ToolCallFailure) {
        lock.lock()
        let pending = Array(calls.values)
        calls.removeAll()
        queue.removeAll()
        for timer in abandoned.values {
            timer.cancel()
        }
        abandoned.removeAll()
        inFlight = 0
        let waiter = helloWaiter
        helloWaiter = nil
        lock.unlock()
        waiter?.resume(throwing: reason)
        for call in pending {
            call.timer?.cancel()
            call.continuation.resume(returning: .failure(reason))
        }
    }

    /// stdout has ended: reap the process and fail whatever was waiting.
    @objc private dynamic func processEnded() {
        lock.lock()
        let process = process
        lock.unlock()
        guard let process else { return }

        var status: Int32 = 0
        var reaped = false
        // A process that closed stdout may still be running; give it a
        // moment before killing it.
        for _ in 0 ..< 200 {
            let result = waitpid(process.pid, &status, WNOHANG)
            if result == process.pid {
                reaped = true; break
            }
            if result < 0, errno != EINTR {
                break
            }
            usleep(10000)
        }
        if !reaped {
            kill(-process.pid, SIGKILL)
            while waitpid(process.pid, &status, 0) < 0, errno == EINTR {}
        }
        let ended = ExtensionExit(waitStatus: status)
        _ = stderrFinished.wait(timeout: .now() + 1)

        lock.lock()
        exit = ended
        let tail = logTail.suffix(10).joined(separator: "\n")
        let crash = ToolCallFailure(
            .extensionCrashed,
            "the extension \(ended)" + (tail.isEmpty ? "" : "; last log:\n\(tail)"),
        )
        let waiters = exitWaiters
        exitWaiters.removeAll()
        let channel = channel
        lock.unlock()
        stop(crash)
        channel?.stop()
        for waiter in waiters {
            waiter.resume(returning: ended)
        }
    }

    // MARK: - Helpers

    /// Closes the extension's stdin once, on the write queue behind any frame
    /// being written, so the descriptor is never closed under a write.
    @objc private dynamic func closeStdin() {
        lock.lock()
        let stdin = writer != nil ? process?.stdinWrite : nil
        writer = nil
        lock.unlock()
        if let stdin {
            writeQueue.async { close(stdin) }
        }
    }

    private func write(_ frame: ToolFrame) {
        guard let data = try? ToolFrameCodec.encode(frame) else { return }
        writeQueue.async { [self] in
            lock.lock()
            let writer = writer
            lock.unlock()
            writer?.write(data)
        }
    }

    @objc private dynamic func nextID(prefix: String) -> String {
        lock.lock()
        counter += 1
        let value = counter
        lock.unlock()
        return "\(prefix)\(value)"
    }

    @objc private dynamic func startThread(named name: String, _ body: @escaping () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }
}
