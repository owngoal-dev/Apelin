import ApelinCore
import Darwin
import Foundation

/// One frame on a channel: a JSON header, a raw body, and descriptors
/// passed with SCM_RIGHTS.
///
///     u32 big-endian  length of everything after it
///     u32 big-endian  header length
///     header          JSON `FrameHeader`
///     body            the rest: a JSON request, reply, event payload or control body
///
/// The descriptors ride on the frame's first byte; the header says how many.
public struct ChannelFrame: Sendable {
    public var header: FrameHeader
    public var body: Data
    public var descriptors: [OwnedDescriptor]

    public init(header: FrameHeader, body: Data = Data(), descriptors: [OwnedDescriptor] = []) {
        self.header = header
        self.body = body
        self.descriptors = descriptors
    }
}

public struct FrameHeader: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case request
        case reply
        case event
        case control
    }

    public var kind: Kind
    /// Pairs a reply with its request; 0 for events and control frames.
    public var id: UInt64
    /// request: the operation. event: the event kind. control: its name.
    public var name: String?
    public var protocolVersion: Int64?
    public var requestID: String?
    /// reply: nil on success.
    public var error: ApelinError?
    /// The task a request starts or serves, an event belongs to, or a cancel stops.
    public var taskID: TaskID?
    public var descriptorCount: Int
    /// request: true when the session host starts a task again after it
    /// restarted, under the task's own ID; absent on a first start.
    public var resumed: Bool?

    public init(
        kind: Kind,
        id: UInt64 = 0,
        name: String? = nil,
        protocolVersion: Int64? = nil,
        requestID: String? = nil,
        error: ApelinError? = nil,
        taskID: TaskID? = nil,
        descriptorCount: Int = 0,
        resumed: Bool? = nil,
    ) {
        self.kind = kind
        self.id = id
        self.name = name
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.error = error
        self.taskID = taskID
        self.descriptorCount = descriptorCount
        self.resumed = resumed
    }
}

/// A request that arrived on a channel, with what the frame said beside it.
public struct ChannelRequest: Sendable {
    public var request: WireRequest
    public var descriptors: [OwnedDescriptor]
    public var taskID: TaskID?
    /// The host is starting this task again after a restart: the work it
    /// left behind is the worker's to clean up before starting over.
    public var resumed: Bool = false
}

/// The length-prefixed JSON frame protocol over a Unix stream socket the
/// session host made with `socketpair(2)`: proxy ↔ session host, and session
/// host ↔ each worker. Symmetric: either side may call the other.
///
/// Reading is a dedicated thread doing blocking `recvmsg`; writing is
/// serialised by a lock. Requests are answered on a Swift task each, so a
/// slow request does not hold up the channel.
public final class WorkerChannel: @unchecked Sendable {
    public static let maximumFrameLength = 64 << 20
    public static let maximumDescriptors = 64

    public typealias RequestHandler = @Sendable (ChannelRequest) async -> (WireReply, [OwnedDescriptor])
    public typealias FrameHandler = @Sendable (ChannelFrame) -> Void

    private let socket: Int32
    private let writeLock = PthreadLock()
    private let stateLock = PthreadLock()
    @objc private dynamic var nextID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<ChannelFrame, Error>] = [:]
    @objc private dynamic var closed = false

    private var requestHandler: RequestHandler?
    private var eventHandler: FrameHandler?
    private var controlHandler: FrameHandler?
    @objc private dynamic var closeHandler: (@Sendable () -> Void)?

    /// Takes ownership of one end of a socketpair.
    public init(adopting socket: Int32) {
        self.socket = socket
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Makes a connected pair: one end for this process, one to hand a child.
    public static func makePair() throws -> (local: Int32, remote: Int32) {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw ApelinError(.internal, "socketpair: \(String(cString: strerror(errno)))")
        }
        for end in pair {
            _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        }
        return (pair[0], pair[1])
    }

    /// Set the handlers, then `start()`.
    public func onRequest(_ handler: @escaping RequestHandler) {
        stateLock.withLock { requestHandler = handler }
    }

    public func onEvent(_ handler: @escaping FrameHandler) {
        stateLock.withLock { eventHandler = handler }
    }

    public func onControl(_ handler: @escaping FrameHandler) {
        stateLock.withLock { controlHandler = handler }
    }

    @objc public dynamic func onClose(_ handler: @escaping @Sendable () -> Void) {
        stateLock.withLock { closeHandler = handler }
    }

    @objc public dynamic func start() {
        let thread = Thread { [self] in readLoop() }
        thread.name = "wiki.qaq.apelin.channel"
        thread.start()
    }

    @objc public dynamic var isClosed: Bool {
        stateLock.withLock { closed }
    }

    /// Sends a request and waits for its reply. `resumed` marks a task the
    /// host starts again after a restart.
    public func call(
        _ request: WireRequest,
        descriptors: [OwnedDescriptor] = [],
        taskID: TaskID? = nil,
        resumed: Bool = false,
    ) async throws -> (WireReply, [OwnedDescriptor]) {
        let id: UInt64 = stateLock.withLock {
            defer { nextID += 1 }
            return nextID
        }
        let header = FrameHeader(
            kind: .request,
            id: id,
            name: request.operation.rawValue,
            protocolVersion: request.protocolVersion,
            requestID: request.requestID,
            taskID: taskID,
            descriptorCount: descriptors.count,
            resumed: resumed ? true : nil,
        )
        let frame: ChannelFrame = try await withCheckedThrowingContinuation { continuation in
            let registered: Bool = stateLock.withLock {
                guard !closed else { return false }
                pending[id] = continuation
                return true
            }
            guard registered else {
                continuation.resume(throwing: ApelinError(.unavailable, "the channel is closed"))
                return
            }
            do {
                try send(ChannelFrame(header: header, body: request.payload, descriptors: descriptors))
            } catch {
                let waiting = stateLock.withLock { pending.removeValue(forKey: id) }
                waiting?.resume(throwing: error)
            }
        }
        if let error = frame.header.error {
            return (.failure(request.requestID, error), frame.descriptors)
        }
        return (WireReply(requestID: request.requestID, result: .success(frame.body)), frame.descriptors)
    }

    /// Sends an event of a task.
    public func sendEvent(taskID: TaskID, kind: String, payload: JSONValue?) throws {
        let body = try payload.map { try JSONCoding.encode($0) } ?? Data()
        try send(ChannelFrame(header: FrameHeader(kind: .event, name: kind, taskID: taskID), body: body))
    }

    /// Sends a control frame with a Codable body.
    public func sendControl(_ name: String, body: some Encodable, taskID: TaskID? = nil) throws {
        try send(ChannelFrame(
            header: FrameHeader(kind: .control, name: name, taskID: taskID),
            body: JSONCoding.encode(body),
        ))
    }

    public func sendControl(_ name: String, taskID: TaskID? = nil) throws {
        try send(ChannelFrame(header: FrameHeader(kind: .control, name: name, taskID: taskID)))
    }

    /// Writes one frame; descriptors are duplicated into the message, the
    /// caller's stay open.
    public func send(_ frame: ChannelFrame) throws {
        var header = frame.header
        header.descriptorCount = frame.descriptors.count
        let headerData = try JSONCoding.encode(header)
        let total = 4 + headerData.count + frame.body.count
        guard total <= Self.maximumFrameLength, frame.descriptors.count <= Self.maximumDescriptors else {
            throw ApelinError(.badRequest, "frame too large")
        }
        var bytes = Data(capacity: 4 + total)
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(total).bigEndian, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: UInt32(headerData.count).bigEndian, Array.init))
        bytes.append(headerData)
        bytes.append(frame.body)

        try writeLock.withLock {
            guard !isClosed else { throw ApelinError(.unavailable, "the channel is closed") }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                var descriptors = frame.descriptors.map(\.rawValue)
                while offset < buffer.count {
                    let written = Self.sendChunk(
                        socket,
                        buffer.baseAddress! + offset,
                        buffer.count - offset,
                        descriptors: descriptors,
                    )
                    if written < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw ApelinError(.unavailable, "send: \(String(cString: strerror(errno)))")
                    }
                    descriptors = []
                    offset += written
                }
            }
        }
    }

    /// Closes the socket; pending calls fail with `.unavailable`.
    @objc public dynamic func close() {
        let waiting: [CheckedContinuation<ChannelFrame, Error>] = stateLock.withLock {
            guard !closed else { return [] }
            closed = true
            Darwin.shutdown(socket, SHUT_RDWR)
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        for continuation in waiting {
            continuation.resume(throwing: ApelinError(.unavailable, "the channel closed"))
        }
    }

    // MARK: Reading

    @objc private dynamic func readLoop() {
        var buffer = Data()
        var receivedDescriptors: [OwnedDescriptor] = []
        var chunk = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let (count, descriptors) = Self.receiveChunk(socket, &chunk)
            receivedDescriptors += descriptors.map(OwnedDescriptor.init(adopting:))
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0 ..< count])
            while let frame = Self.takeFrame(from: &buffer, descriptors: &receivedDescriptors) {
                switch frame {
                case let .success(frame): dispatch(frame)
                case .failure:
                    finish()
                    return
                }
            }
        }
        finish()
    }

    @objc private dynamic func finish() {
        close()
        writeLock.withLock { _ = Darwin.close(socket) }
        let handler = stateLock.withLock { closeHandler }
        handler?()
    }

    private static func takeFrame(
        from buffer: inout Data,
        descriptors: inout [OwnedDescriptor],
    ) -> Result<ChannelFrame, ApelinError>? {
        guard buffer.count >= 8 else { return nil }
        let start = buffer.startIndex
        let total = Int(buffer[start ..< start + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard total >= 4, total <= maximumFrameLength else {
            return .failure(ApelinError(.badRequest, "bad frame length"))
        }
        guard buffer.count >= 4 + total else { return nil }
        let headerLength = Int(buffer[start + 4 ..< start + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        guard headerLength <= total - 4 else { return .failure(ApelinError(.badRequest, "bad header length")) }
        let headerData = buffer[start + 8 ..< start + 8 + headerLength]
        let body = Data(buffer[start + 8 + headerLength ..< start + 4 + total])
        buffer = Data(buffer[(start + 4 + total)...])
        guard let header = try? JSONCoding.decode(FrameHeader.self, from: Data(headerData)),
              header.descriptorCount >= 0, header.descriptorCount <= descriptors.count
        else { return .failure(ApelinError(.badRequest, "bad frame header")) }
        let mine = Array(descriptors.prefix(header.descriptorCount))
        descriptors.removeFirst(header.descriptorCount)
        return .success(ChannelFrame(header: header, body: body, descriptors: mine))
    }

    private func dispatch(_ frame: ChannelFrame) {
        switch frame.header.kind {
        case .reply:
            let waiting = stateLock.withLock { pending.removeValue(forKey: frame.header.id) }
            waiting?.resume(returning: frame)
        case .request:
            let handler = stateLock.withLock { requestHandler }
            let id = frame.header.id
            let requestID = frame.header.requestID ?? ""
            guard let operation = frame.header.name.flatMap(AppOperation.init(rawValue:)) else {
                reply(id: id, .failure(requestID, ApelinError(.unknownOperation, frame.header.name ?? "")), [])
                return
            }
            guard frame.header.protocolVersion == Wire.protocolVersion else {
                reply(
                    id: id,
                    .failure(
                        requestID,
                        ApelinError(.unsupportedVersion, "protocol \(frame.header.protocolVersion ?? 0)"),
                    ),
                    [],
                )
                return
            }
            let request = ChannelRequest(
                request: WireRequest(operation: operation, requestID: requestID, payload: frame.body),
                descriptors: frame.descriptors,
                taskID: frame.header.taskID,
                resumed: frame.header.resumed == true,
            )
            guard let handler else {
                reply(id: id, .failure(requestID, .unimplemented(operation)), [])
                return
            }
            Task {
                let (wireReply, descriptors) = await handler(request)
                self.reply(id: id, wireReply, descriptors)
            }
        case .event:
            let handler = stateLock.withLock { eventHandler }
            handler?(frame)
        case .control:
            let handler = stateLock.withLock { controlHandler }
            handler?(frame)
        }
    }

    private func reply(id: UInt64, _ reply: WireReply, _ descriptors: [OwnedDescriptor]) {
        var header = FrameHeader(kind: .reply, id: id, requestID: reply.requestID)
        let body: Data
        switch reply.result {
        case let .success(payload): body = payload
        case let .failure(error):
            header.error = error
            body = Data()
        }
        try? send(ChannelFrame(header: header, body: body, descriptors: descriptors))
    }

    // MARK: sendmsg / recvmsg

    /// `CMSG_ALIGN` on Darwin: 4-byte alignment.
    @objc private static dynamic func align(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    @objc private static dynamic var headerSpace: Int {
        align(MemoryLayout<cmsghdr>.size)
    }

    @objc private static dynamic func sendChunk(
        _ socket: Int32,
        _ base: UnsafeRawPointer,
        _ length: Int,
        descriptors: [Int32],
    ) -> Int {
        var vector = iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: length)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
            var message = msghdr()
            message.msg_iov = vectorPointer
            message.msg_iovlen = 1
            guard !descriptors.isEmpty else { return Darwin.sendmsg(socket, &message, 0) }
            let dataLength = descriptors.count * MemoryLayout<Int32>.size
            let space = headerSpace + align(dataLength)
            let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: 8)
            defer { control.deallocate() }
            memset(control, 0, space)
            let header = control.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = socklen_t(headerSpace + dataLength)
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = SCM_RIGHTS
            descriptors.withUnsafeBytes { bytes in
                (control + headerSpace).copyMemory(from: bytes.baseAddress!, byteCount: dataLength)
            }
            message.msg_control = control
            message.msg_controllen = socklen_t(space)
            return Darwin.sendmsg(socket, &message, 0)
        }
    }

    private static func receiveChunk(_ socket: Int32, _ chunk: inout [UInt8]) -> (Int, [Int32]) {
        let space = headerSpace + align(maximumDescriptors * MemoryLayout<Int32>.size)
        let control = UnsafeMutableRawPointer.allocate(byteCount: space, alignment: 8)
        defer { control.deallocate() }
        return chunk.withUnsafeMutableBytes { buffer in
            var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                var message = msghdr()
                message.msg_iov = vectorPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(space)
                let count = Darwin.recvmsg(socket, &message, 0)
                guard count >= 0 else { return (count, []) }
                var descriptors: [Int32] = []
                var offset = 0
                let controlLength = Int(message.msg_controllen)
                while offset + headerSpace <= controlLength {
                    let header = (control + offset).assumingMemoryBound(to: cmsghdr.self).pointee
                    let length = Int(header.cmsg_len)
                    guard length >= headerSpace, offset + length <= controlLength else { break }
                    if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                        let count = (length - headerSpace) / MemoryLayout<Int32>.size
                        for index in 0 ..< count {
                            var descriptor: Int32 = -1
                            memcpy(
                                &descriptor,
                                control + offset + headerSpace + index * MemoryLayout<Int32>.size,
                                MemoryLayout<Int32>.size,
                            )
                            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                            descriptors.append(descriptor)
                        }
                    }
                    offset += align(length)
                }
                return (count, descriptors)
            }
        }
    }
}

/// An `ApelinTransport` over a channel: how a worker (the agent) calls the
/// session host with the same `ApelinService` the app uses. The host
/// decides by the worker's registered role what it may call.
public struct ChannelTransport: ApelinTransport {
    public let channel: WorkerChannel

    public init(channel: WorkerChannel) {
        self.channel = channel
    }

    public func call(
        _ request: WireRequest,
        descriptors: [OwnedDescriptor],
    ) async throws -> (WireReply, [OwnedDescriptor]) {
        try await channel.call(request, descriptors: descriptors)
    }
}
