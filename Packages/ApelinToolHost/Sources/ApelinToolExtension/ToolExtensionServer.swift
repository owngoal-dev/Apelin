@_exported import ApelinToolCore
import Darwin
import Foundation

/// One tool an extension implements: what the manifest says about it, and
/// the code that runs it.
public struct ToolHandler: Sendable {
    public var descriptor: ToolDescriptor
    public var run: @Sendable (ToolCallContext) async throws -> ToolOutput

    public init(_ descriptor: ToolDescriptor, run: @escaping @Sendable (ToolCallContext) async throws -> ToolOutput) {
        self.descriptor = descriptor
        self.run = run
    }
}

/// What a handler returns.
public struct ToolOutput: Sendable {
    public enum Item: Sendable {
        case text(String)
        /// A file, sent as an attachment: its descriptor over the socket,
        /// its ID in the frame.
        case file(ToolOutgoingAttachment)
    }

    public var content: [Item]

    public init(_ content: [Item]) {
        self.content = content
    }

    public static func text(_ text: String) -> ToolOutput {
        ToolOutput([.text(text)])
    }
}

/// Throw this from a handler to choose the error code; anything else thrown
/// becomes `toolFailed` with its description.
public struct ToolFailure: Error, Sendable, CustomStringConvertible {
    public var code: ToolErrorCode
    public var message: String

    public init(_ message: String, code: ToolErrorCode = .toolFailed) {
        self.code = code
        self.message = message
    }

    public static func invalidArguments(_ message: String) -> ToolFailure {
        ToolFailure(message, code: .invalidArguments)
    }

    public var description: String {
        message
    }
}

/// One call, as a handler sees it.
public final class ToolCallContext: @unchecked Sendable {
    public let requestID: String
    public let tool: String
    public let arguments: JSONValue
    public let attachmentReferences: [ToolAttachmentReference]
    private let channel: ToolAttachmentChannel?
    private let attachmentWait: TimeInterval
    private let lock = NSLock()
    @objc private dynamic var cancelled = false
    @objc private dynamic var claimed = Set<String>()

    init(
        requestID: String,
        tool: String,
        arguments: JSONValue,
        attachments: [ToolAttachmentReference],
        channel: ToolAttachmentChannel?,
        attachmentWait: TimeInterval,
    ) {
        self.requestID = requestID
        self.tool = tool
        self.arguments = arguments
        attachmentReferences = attachments
        self.channel = channel
        self.attachmentWait = attachmentWait
    }

    /// Whether the host cancelled this call. Long handlers check it between
    /// steps; a cancelled Swift task reads true here too.
    @objc public dynamic var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    @objc public dynamic func checkCancellation() throws {
        if isCancelled {
            throw CancellationError()
        }
    }

    @objc dynamic func markCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// The file the host passed for `argument`, if it passed one: the host
    /// may hand over a descriptor in place of a path it could open and this
    /// process could not.
    public func attachment(forArgument argument: String) throws -> ToolReceivedAttachment? {
        guard let reference = attachmentReferences.first(where: { $0.argument == argument }) else { return nil }
        return try attachment(reference)
    }

    /// Every attachment the call carried that names no argument.
    public func unboundAttachments() throws -> [ToolReceivedAttachment] {
        try attachmentReferences.filter { $0.argument == nil }.map(attachment)
    }

    private func attachment(_ reference: ToolAttachmentReference) throws -> ToolReceivedAttachment {
        guard let channel else { throw ToolFailure("this process has no attachment socket", code: .attachmentRejected) }
        lock.lock()
        let first = claimed.insert(reference.id).inserted
        lock.unlock()
        guard first else {
            throw ToolFailure("attachment \(reference.id) was already taken", code: .attachmentRejected)
        }
        switch channel.claim(reference, timeout: attachmentWait) {
        case let .success(file): return file
        case let .failure(error): throw ToolFailure(error.description, code: .attachmentRejected)
        }
    }

    @objc dynamic func discardUnclaimed() {
        lock.lock()
        let unclaimed = attachmentReferences.map(\.id).filter { !claimed.contains($0) }
        lock.unlock()
        channel?.discard(ids: unclaimed)
    }
}

/// The extension's end of the protocol. An extension's `main` builds one with
/// its tools and calls `run()`, which never returns: it reads frames from
/// stdin until the host closes it, then exits.
///
/// `run()` keeps stdout for frames alone: it moves the real stdout to a
/// private descriptor and points descriptor 1 at stderr, so a stray `print`
/// or a C library's chatter lands in the log instead of corrupting the wire.
///
/// Run with `--describe`, it prints its descriptors as JSON and exits, so a
/// test can hold the manifest to the code.
public final class ToolExtensionServer: @unchecked Sendable {
    public let peer: ToolPeer
    public let handlers: [String: ToolHandler]
    public let descriptors: [ToolDescriptor]
    private let limits: ToolProtocolLimits
    private let supportedVersions: [Int]

    private let lock = NSLock()
    private var writer: LineWriter?
    private var channel: ToolAttachmentChannel?
    private var negotiatedVersion: Int?
    @objc private dynamic var outboundFrameLimit: Int
    private var inFlight: [String: (context: ToolCallContext, task: Task<Void, Never>)] = [:]
    /// Calls in flight whose last frame is being written. They hold no slot:
    /// the host sends its next queued call the moment it reads that frame.
    @objc private dynamic var answering = Set<String>()
    @objc private dynamic var attachmentCounter = 0

    /// `peer.name` is the extension id from the manifest.
    public init(
        peer: ToolPeer,
        tools: [ToolHandler],
        limits: ToolProtocolLimits = .init(),
        supportedVersions: [Int] = ToolProtocol.supportedVersions,
    ) {
        self.peer = peer
        descriptors = tools.map(\.descriptor)
        handlers = Dictionary(tools.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first })
        self.limits = limits
        self.supportedVersions = supportedVersions
        outboundFrameLimit = limits.maxFrameBytes
    }

    @objc public dynamic func run() -> Never {
        if CommandLine.arguments.dropFirst().contains("--describe") {
            describe()
            exit(0)
        }
        // A host that went away must not kill this process with SIGPIPE
        // before it can notice.
        signal(SIGPIPE, SIG_IGN)
        let protocolOut = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3)
        guard protocolOut >= 0 else {
            FileHandle.standardError.write(Data("cannot reserve the protocol descriptor\n".utf8))
            exit(70)
        }
        dup2(STDERR_FILENO, STDOUT_FILENO)
        writer = LineWriter(descriptor: protocolOut)
        channel = Self.attachmentChannel(limits: limits)
        channel?.start()

        let reader = LineReader(descriptor: STDIN_FILENO, maxLineBytes: limits.maxFrameBytes)
        loop: while true {
            switch reader.next() {
            case let .line(line):
                handle(line: line)
            case .oversized:
                send(.error(
                    .frameTooLarge,
                    "frame longer than \(limits.maxFrameBytes) bytes",
                    requestID: nil,
                    protocolVersion: currentVersion,
                ))
            case .endOfFile:
                break loop
            }
        }
        shutDown()
    }

    /// Writes bytes straight onto the wire, bypassing every check. For the
    /// tests' misbehaving extension only.
    @_spi(Testing) public func writeRawForTesting(_ data: Data) {
        writer?.write(data)
    }

    // MARK: - Frames

    @objc private dynamic var currentVersion: Int {
        lock.lock()
        defer { lock.unlock() }
        return negotiatedVersion ?? supportedVersions.max() ?? ToolProtocol.version
    }

    private func handle(line: Data) {
        let frame: ToolFrame
        do {
            frame = try ToolFrameCodec.decode(line)
        } catch {
            send(.error(
                .badFrame,
                "frame does not parse",
                requestID: Self.salvageRequestID(line),
                protocolVersion: currentVersion,
            ))
            return
        }
        if frame.type == .hello {
            hello(frame)
            return
        }
        lock.lock()
        let version = negotiatedVersion
        lock.unlock()
        guard let version else {
            send(.error(
                .notNegotiated,
                "the host must send hello before any other frame",
                requestID: frame.requestID,
                protocolVersion: currentVersion,
            ))
            return
        }
        guard frame.protocolVersion == version else {
            send(.error(
                .protocolVersionMismatch,
                "the frame uses protocol version \(frame.protocolVersion), but version \(version) was negotiated",
                requestID: frame.requestID,
                protocolVersion: version,
            ))
            return
        }
        guard let requestID = frame.requestID, ToolFrame.isValidRequestID(requestID) else {
            send(.error(.badFrame, "missing or invalid requestID", requestID: nil, protocolVersion: version))
            return
        }
        switch frame.type {
        case .call: call(frame, requestID: requestID, version: version)
        case .cancel: cancel(requestID: requestID)
        case .result, .error, .hello:
            send(.error(
                .badFrame,
                "the host does not send \(frame.type.rawValue)",
                requestID: requestID,
                protocolVersion: version,
            ))
        }
    }

    private func hello(_ frame: ToolFrame) {
        let offered = frame.supportedVersions ?? [frame.protocolVersion]
        lock.lock()
        let already = negotiatedVersion != nil
        lock.unlock()
        guard !already else {
            send(.error(
                .badFrame,
                "hello was already exchanged",
                requestID: frame.requestID,
                protocolVersion: currentVersion,
            ))
            return
        }
        guard let version = offered.filter(supportedVersions.contains).max() else {
            send(.error(
                .protocolVersionMismatch,
                "no shared protocol version: the host supports \(offered), this extension supports \(supportedVersions)",
                requestID: frame.requestID,
                protocolVersion: currentVersion,
            ))
            return
        }
        lock.lock()
        negotiatedVersion = version
        if let hostLimit = frame.maxFrameBytes, hostLimit > 0 {
            outboundFrameLimit = min(limits.maxFrameBytes, hostLimit)
        }
        lock.unlock()
        var reply = ToolFrame(protocolVersion: version, type: .hello, requestID: frame.requestID)
        reply.supportedVersions = supportedVersions
        reply.peer = peer
        reply.tools = descriptors.map(\.name)
        reply.maxConcurrentCalls = limits.maxConcurrentCalls
        reply.maxFrameBytes = limits.maxFrameBytes
        send(reply)
    }

    private func call(_ frame: ToolFrame, requestID: String, version: Int) {
        func refuse(_ code: ToolErrorCode, _ message: String) {
            send(.error(code, message, requestID: requestID, protocolVersion: version))
            channel?.discard(ids: frame.attachments?.map(\.id) ?? [])
        }
        guard let name = frame.tool, let handler = handlers[name] else {
            refuse(.unknownTool, "no tool named \(frame.tool ?? "(none)")")
            return
        }
        let arguments = frame.args ?? .object([:])
        if let problem = ToolSchemaValidator.problem(with: arguments, against: handler.descriptor.parameters) {
            refuse(.invalidArguments, problem)
            return
        }
        let attachments = frame.attachments ?? []
        guard attachments.count <= limits.maxAttachmentsPerFrame else {
            refuse(.attachmentRejected, "more than \(limits.maxAttachmentsPerFrame) attachments")
            return
        }
        let context = ToolCallContext(
            requestID: requestID,
            tool: name,
            arguments: arguments,
            attachments: attachments,
            channel: channel,
            attachmentWait: limits.attachmentWait,
        )
        lock.lock()
        if inFlight[requestID] != nil {
            lock.unlock()
            refuse(.duplicateRequest, "\(requestID) is already in flight")
            return
        }
        if inFlight.count - answering.count >= limits.maxConcurrentCalls {
            lock.unlock()
            refuse(.busy, "\(limits.maxConcurrentCalls) calls already in flight")
            return
        }
        let task = Task { [self] in
            await execute(handler, context: context, version: version)
        }
        inFlight[requestID] = (context, task)
        lock.unlock()
    }

    private func execute(_ handler: ToolHandler, context: ToolCallContext, version: Int) async {
        let requestID = context.requestID
        defer {
            context.discardUnclaimed()
            lock.withLock {
                inFlight.removeValue(forKey: requestID)
                answering.remove(requestID)
            }
        }
        do {
            let output = try await handler.run(context)
            if context.isCancelled {
                send(.error(.cancelled, "cancelled", requestID: requestID, protocolVersion: version), ending: requestID)
            } else {
                sendResult(output, requestID: requestID, version: version)
            }
        } catch is CancellationError {
            send(.error(.cancelled, "cancelled", requestID: requestID, protocolVersion: version), ending: requestID)
        } catch let failure as ToolFailure {
            send(
                .error(
                    context.isCancelled ? .cancelled : failure.code,
                    failure.message,
                    requestID: requestID,
                    protocolVersion: version,
                ),
                ending: requestID,
            )
        } catch {
            send(
                .error(
                    context.isCancelled ? .cancelled : .toolFailed,
                    String(describing: error),
                    requestID: requestID,
                    protocolVersion: version,
                ),
                ending: requestID,
            )
        }
    }

    private func sendResult(_ output: ToolOutput, requestID: String, version: Int) {
        var content: [ToolContent] = []
        var files: [(id: String, attachment: ToolOutgoingAttachment)] = []
        for item in output.content {
            switch item {
            case let .text(text):
                content.append(.text(text))
            case let .file(attachment):
                var info = stat()
                guard fstat(attachment.descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_size <= off_t(limits.maxAttachmentBytes)
                else {
                    send(
                        .error(
                            .attachmentRejected,
                            "a result file is not a regular file under \(limits.maxAttachmentBytes) bytes",
                            requestID: requestID,
                            protocolVersion: version,
                        ),
                        ending: requestID,
                    )
                    return
                }
                lock.lock()
                attachmentCounter += 1
                let id = "x\(attachmentCounter)"
                lock.unlock()
                files.append((id, attachment))
                content.append(.attachment(ToolAttachmentReference(
                    id: id,
                    mimeType: attachment.mimeType,
                    name: attachment.name,
                    byteCount: Int(info.st_size),
                )))
            }
        }
        guard files.count <= limits.maxAttachmentsPerFrame else {
            send(
                .error(
                    .attachmentRejected,
                    "more than \(limits.maxAttachmentsPerFrame) result files",
                    requestID: requestID,
                    protocolVersion: version,
                ),
                ending: requestID,
            )
            return
        }
        var frame = ToolFrame(protocolVersion: version, type: .result, requestID: requestID)
        frame.content = content
        guard let data = try? ToolFrameCodec.encode(frame) else {
            send(
                .error(.toolFailed, "the result does not encode", requestID: requestID, protocolVersion: version),
                ending: requestID,
            )
            return
        }
        lock.lock()
        let frameLimit = outboundFrameLimit
        lock.unlock()
        guard data.count - 1 <= frameLimit else {
            send(
                .error(
                    .resultTooLarge,
                    "the result is \(data.count - 1) bytes, over the \(frameLimit)-byte frame limit",
                    requestID: requestID,
                    protocolVersion: version,
                ),
                ending: requestID,
            )
            return
        }
        if !files.isEmpty {
            guard let channel else {
                send(
                    .error(
                        .attachmentRejected,
                        "this process has no attachment socket",
                        requestID: requestID,
                        protocolVersion: version,
                    ),
                    ending: requestID,
                )
                return
            }
            for file in files {
                do {
                    try channel.send(id: file.id, descriptor: file.attachment.descriptor)
                } catch {
                    send(
                        .error(.attachmentRejected, "\(error)", requestID: requestID, protocolVersion: version),
                        ending: requestID,
                    )
                    return
                }
            }
        }
        lock.withLock { _ = answering.insert(requestID) }
        writer?.write(data)
    }

    @objc private dynamic func cancel(requestID: String) {
        lock.lock()
        let entry = inFlight[requestID]
        lock.unlock()
        // A cancel for a call that already ended crossed its result on the
        // wire; there is nothing to answer.
        guard let entry else { return }
        entry.context.markCancelled()
        entry.task.cancel()
    }

    /// `ending` names the call this frame is the last of.
    private func send(_ frame: ToolFrame, ending requestID: String? = nil) {
        guard let data = try? ToolFrameCodec.encode(frame) else { return }
        if let requestID {
            lock.withLock { _ = answering.insert(requestID) }
        }
        writer?.write(data)
    }

    /// stdin has ended: the host is done. Calls in flight get `cancelGrace`
    /// to finish (their results go nowhere, or to a one-shot pipe), then are
    /// cancelled and given a moment more.
    @objc private dynamic func shutDown() -> Never {
        func waitForCalls(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                lock.lock()
                let remaining = inFlight.count
                lock.unlock()
                if remaining == 0 {
                    return true
                }
                usleep(10000)
            }
            return false
        }
        if !waitForCalls(limits.cancelGrace) {
            lock.lock()
            let running = inFlight.values
            lock.unlock()
            for entry in running {
                entry.context.markCancelled()
                entry.task.cancel()
            }
            _ = waitForCalls(0.5)
        }
        channel?.stop()
        exit(0)
    }

    @objc private dynamic func describe() {
        struct Description: Encodable {
            var id: String
            var version: String
            var protocolVersions: [Int]
            var tools: [ToolDescriptor]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let description = Description(
            id: peer.name,
            version: peer.version,
            protocolVersions: supportedVersions,
            tools: descriptors,
        )
        if var data = try? encoder.encode(description) {
            data.append(0x0A)
            FileHandle.standardOutput.write(data)
        }
    }

    private static func attachmentChannel(limits: ToolProtocolLimits) -> ToolAttachmentChannel? {
        guard let value = ProcessInfo.processInfo.environment[ToolProtocol.attachmentEnvironmentKey],
              let descriptor = Int32(value), descriptor > 2
        else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return ToolAttachmentChannel(
            socket: descriptor,
            maxAttachmentBytes: limits.maxAttachmentBytes,
            maxPending: limits.maxPendingAttachments,
        )
    }

    /// The request ID of a line that is JSON but not a frame, so the error
    /// can name the call it answers.
    private static func salvageRequestID(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let id = object["requestID"] as? String, ToolFrame.isValidRequestID(id)
        else { return nil }
        return id
    }
}
