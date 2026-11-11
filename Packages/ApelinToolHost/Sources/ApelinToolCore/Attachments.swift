import Darwin
import Foundation

/// A file one side is about to send. It owns a duplicate of the descriptor it
/// was made from and closes it once released, sent or not.
public final class ToolOutgoingAttachment: @unchecked Sendable {
    public let descriptor: Int32
    public let mimeType: String?
    public let name: String?
    /// On a call: the argument this file stands in for.
    public let argument: String?

    /// Duplicates `descriptor`; the caller keeps its own.
    public init(
        duplicating descriptor: Int32,
        argument: String? = nil,
        mimeType: String? = nil,
        name: String? = nil,
    ) throws {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw ToolAttachmentError.system("dup", errno) }
        self.descriptor = copy
        self.argument = argument
        self.mimeType = mimeType
        self.name = name
    }

    /// Opens `path` read-only.
    public init(path: String, argument: String? = nil, mimeType: String? = nil, name: String? = nil) throws {
        guard !path.utf8.contains(0) else { throw ToolAttachmentError.rejected("path contains NUL") }
        let opened = open(path, O_RDONLY | O_CLOEXEC)
        guard opened >= 0 else { throw ToolAttachmentError.system("open", errno) }
        descriptor = opened
        self.argument = argument
        self.mimeType = mimeType
        self.name = name ?? (path as NSString).lastPathComponent
    }

    deinit { close(descriptor) }
}

/// A file the other side sent. Owns the descriptor it was mapped to and
/// closes it when released.
public final class ToolReceivedAttachment: @unchecked Sendable {
    public let id: String
    public let descriptor: Int32
    public let byteCount: Int
    public let mimeType: String?
    public let name: String?

    init(id: String, descriptor: Int32, byteCount: Int, mimeType: String?, name: String?) {
        self.id = id
        self.descriptor = descriptor
        self.byteCount = byteCount
        self.mimeType = mimeType
        self.name = name
    }

    /// The whole file, read from offset zero; refuses a file larger than
    /// `limit`.
    public func readAll(limit: Int = .max) throws -> Data {
        guard byteCount <= limit else {
            throw ToolAttachmentError.rejected("attachment is \(byteCount) bytes, over \(limit)")
        }
        var data = Data(count: byteCount)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            while offset < byteCount {
                let count = pread(descriptor, raw.baseAddress! + offset, byteCount - offset, off_t(offset))
                if count < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ToolAttachmentError.system("pread", errno)
                }
                if count == 0 {
                    break
                }
                offset += count
            }
        }
        return data.prefix(offset)
    }

    deinit { close(descriptor) }
}

public enum ToolAttachmentError: Error, Equatable, CustomStringConvertible {
    case system(String, Int32)
    case rejected(String)
    case missing(String)

    public var description: String {
        switch self {
        case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
        case let .rejected(reason): reason
        case let .missing(id): "attachment \(id) never arrived"
        }
    }
}

/// One end of the attachment socket: an `AF_UNIX` datagram pair, each message
/// one attachment ID as its payload and exactly one descriptor as
/// `SCM_RIGHTS`. What a frame names is the ID; the receiver looks it up here
/// and gets the descriptor the kernel installed in *its* table.
///
/// Received descriptors are checked on arrival — a regular file, no larger
/// than the limit — and held until a frame claims them, at most
/// `maxPending` at a time and for at most `maxAge` seconds.
public final class ToolAttachmentChannel: @unchecked Sendable {
    private let socket: Int32
    private let maxBytes: Int
    private let maxPending: Int
    private let maxAge: TimeInterval = 60
    private let condition = NSCondition()
    private var pending: [String: (descriptor: Int32, size: Int, received: Date)] = [:]
    @objc private dynamic var rejected: [String: String] = [:]
    @objc private dynamic var stopped = false
    /// Whether the receive loop is running. One woken by `stop()` closes the
    /// socket and the wake pipe; one that ended on its own leaves them to
    /// `stop()`, so no number still in use here is reused before then.
    @objc private dynamic var receiving = false
    @objc private dynamic var wakeRead: Int32 = -1
    @objc private dynamic var wakeWrite: Int32 = -1

    /// Takes ownership of `socket`.
    public init(socket: Int32, maxAttachmentBytes: Int, maxPending: Int) {
        self.socket = socket
        maxBytes = maxAttachmentBytes
        self.maxPending = maxPending
        var one: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
    }

    /// A connected pair, both ends close-on-exec.
    public static func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw ToolAttachmentError.system("socketpair", errno)
        }
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        return (fds[0], fds[1])
    }

    /// Starts the thread that receives descriptors.
    @objc public dynamic func start() {
        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else { return }
        for fd in pipeFDs {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        receiving = true
        let thread = Thread { [self] in receiveLoop() }
        thread.name = "ApelinTool.attachments"
        thread.start()
    }

    /// Stops receiving and closes every descriptor still unclaimed, and the
    /// socket.
    @objc public dynamic func stop() {
        condition.lock()
        if stopped {
            condition.unlock()
            return
        }
        stopped = true
        for entry in pending.values {
            close(entry.descriptor)
        }
        pending.removeAll()
        condition.broadcast()
        // Under the lock, so the loop cannot end and close the pipe between
        // the check and the write.
        if receiving {
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        } else {
            closeDescriptors()
        }
        condition.unlock()
    }

    /// Sends one descriptor under `id`. The descriptor stays the caller's.
    @objc public dynamic func send(id: String, descriptor: Int32) throws {
        guard ToolFrame.isValidRequestID(id) else { throw ToolAttachmentError.rejected("invalid attachment id") }
        var payload = Array(id.utf8)
        let controlLength = Self.controlSpace(descriptors: 1)
        var control = [UInt8](repeating: 0, count: controlLength)
        control.withUnsafeMutableBytes { raw in
            let header = raw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
            header.pointee.cmsg_len = socklen_t(Self.controlLength(descriptors: 1))
            header.pointee.cmsg_level = SOL_SOCKET
            header.pointee.cmsg_type = SCM_RIGHTS
            var value = descriptor
            memcpy(raw.baseAddress! + Self.headerSpace, &value, MemoryLayout<Int32>.size)
        }
        var attempts = 0
        while true {
            let sent = payload.withUnsafeMutableBytes { payloadRaw -> Int in
                control.withUnsafeMutableBytes { controlRaw -> Int in
                    var vector = iovec(iov_base: payloadRaw.baseAddress, iov_len: payloadRaw.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var message = msghdr()
                        message.msg_iov = vectorPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlRaw.baseAddress
                        message.msg_controllen = socklen_t(controlRaw.count)
                        return sendmsg(socket, &message, 0)
                    }
                }
            }
            if sent >= 0 {
                return
            }
            // A datagram socket reports a full queue as ENOBUFS; the
            // receiver drains it on its own thread.
            if errno == EINTR || ((errno == ENOBUFS || errno == EAGAIN) && attempts < 200) {
                attempts += 1
                usleep(5000)
                continue
            }
            throw ToolAttachmentError.system("sendmsg", errno)
        }
    }

    /// The descriptor received under `id`, waiting up to `timeout` for it.
    /// The caller owns what it gets.
    private func take(
        id: String,
        timeout: TimeInterval,
    ) -> Result<(descriptor: Int32, size: Int), ToolAttachmentError> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let entry = pending.removeValue(forKey: id) {
                return .success((entry.descriptor, entry.size))
            }
            if let reason = rejected.removeValue(forKey: id) {
                return .failure(.rejected(reason))
            }
            if stopped || !condition.wait(until: deadline) {
                if let entry = pending.removeValue(forKey: id) {
                    return .success((entry.descriptor, entry.size))
                }
                return .failure(.missing(id))
            }
        }
    }

    /// The attachment a frame references, as an owned file.
    public func claim(
        _ reference: ToolAttachmentReference,
        timeout: TimeInterval,
    ) -> Result<ToolReceivedAttachment, ToolAttachmentError> {
        take(id: reference.id, timeout: timeout).map {
            ToolReceivedAttachment(
                id: reference.id,
                descriptor: $0.descriptor,
                byteCount: $0.size,
                mimeType: reference.mimeType,
                name: reference.name,
            )
        }
    }

    /// Closes whatever arrived under `ids` without anyone claiming it: the
    /// attachments of a call that was abandoned.
    @objc public dynamic func discard(ids: [String]) {
        condition.lock()
        for id in ids {
            if let entry = pending.removeValue(forKey: id) {
                close(entry.descriptor)
            }
            rejected.removeValue(forKey: id)
        }
        condition.unlock()
    }

    @objc private dynamic func receiveLoop() {
        defer {
            condition.lock()
            receiving = false
            if stopped {
                closeDescriptors()
            }
            condition.unlock()
        }
        var payload = [UInt8](repeating: 0, count: ToolProtocol.maxRequestIDBytes + 1)
        // Room for more descriptors than a message should carry, so extras
        // are seen and closed rather than left to the kernel.
        let maxDescriptors = 8
        var control = [UInt8](repeating: 0, count: Self.controlSpace(descriptors: maxDescriptors))
        while true {
            var polls = [pollfd(fd: socket, events: Int16(POLLIN), revents: 0),
                         pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&polls, 2, -1)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            if polls[1].revents != 0 {
                return
            }
            if polls[0].revents & Int16(POLLIN) == 0 {
                if polls[0].revents != 0 {
                    return
                }
                continue
            }
            var flags: Int32 = 0
            let count = payload.withUnsafeMutableBytes { payloadRaw -> Int in
                control.withUnsafeMutableBytes { controlRaw -> Int in
                    var vector = iovec(iov_base: payloadRaw.baseAddress, iov_len: payloadRaw.count)
                    return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                        var message = msghdr()
                        message.msg_iov = vectorPointer
                        message.msg_iovlen = 1
                        message.msg_control = controlRaw.baseAddress
                        message.msg_controllen = socklen_t(controlRaw.count)
                        let received = recvmsg(socket, &message, 0)
                        flags = message.msg_flags
                        return received
                    }
                }
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN {
                    continue
                }
                return
            }
            if count == 0 {
                return
            }
            let descriptors = Self.descriptors(in: control)
            control.withUnsafeMutableBytes { _ = memset($0.baseAddress, 0, $0.count) }
            guard let first = descriptors.first else { continue }
            for extra in descriptors.dropFirst() {
                close(extra)
            }
            _ = fcntl(first, F_SETFD, FD_CLOEXEC)
            let id = String(decoding: payload[0 ..< min(count, ToolProtocol.maxRequestIDBytes)], as: UTF8.self)
            guard count <= ToolProtocol.maxRequestIDBytes, flags & MSG_TRUNC == 0, flags & MSG_CTRUNC == 0,
                  descriptors.count == 1, ToolFrame.isValidRequestID(id)
            else {
                close(first)
                continue
            }
            accept(id: id, descriptor: first)
        }
    }

    @objc private dynamic func closeDescriptors() {
        close(socket)
        if wakeRead >= 0 {
            close(wakeRead)
        }
        if wakeWrite >= 0 {
            close(wakeWrite)
        }
    }

    @objc private dynamic func accept(id: String, descriptor: Int32) {
        var info = stat()
        var reason: String?
        if fstat(descriptor, &info) != 0 {
            reason = "fstat failed"
        } else if info.st_mode & S_IFMT != S_IFREG {
            reason = "attachment \(id) is not a regular file"
        } else if info.st_size > off_t(maxBytes) {
            reason = "attachment \(id) is \(info.st_size) bytes, over the \(maxBytes)-byte limit"
        }
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        let now = Date()
        for (key, entry) in pending where now.timeIntervalSince(entry.received) > maxAge {
            close(entry.descriptor)
            pending.removeValue(forKey: key)
        }
        if rejected.count > maxPending {
            rejected.removeAll()
        }
        if stopped {
            close(descriptor)
        } else if let reason {
            close(descriptor)
            rejected[id] = reason
        } else if pending[id] != nil {
            close(descriptor)
            rejected[id] = "attachment \(id) was sent twice"
        } else if pending.count >= maxPending {
            close(descriptor)
            rejected[id] = "too many unclaimed attachments"
        } else {
            pending[id] = (descriptor, Int(info.st_size), now)
        }
    }

    /// CMSG_* are macros Swift does not import. Darwin aligns control data to
    /// 32 bits (__DARWIN_ALIGN32).
    @objc private static dynamic func align(_ length: Int) -> Int {
        (length + 3) & ~3
    }

    @objc private static dynamic var headerSpace: Int {
        align(MemoryLayout<cmsghdr>.size)
    }

    @objc private static dynamic func controlLength(descriptors: Int) -> Int {
        headerSpace + descriptors * MemoryLayout<Int32>.size
    }

    @objc private static dynamic func controlSpace(descriptors: Int) -> Int {
        headerSpace + align(descriptors * MemoryLayout<Int32>.size)
    }

    @objc private static dynamic func descriptors(in control: [UInt8]) -> [Int32] {
        var result: [Int32] = []
        control.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<cmsghdr>.size <= raw.count {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                let length = Int(header.cmsg_len)
                guard length >= headerSpace, offset + length <= raw.count else { break }
                if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                    let count = (length - headerSpace) / MemoryLayout<Int32>.size
                    for index in 0 ..< count {
                        result.append(
                            raw.loadUnaligned(fromByteOffset: offset + headerSpace + index * 4, as: Int32.self),
                        )
                    }
                }
                offset += align(length)
            }
        }
        return result
    }
}
