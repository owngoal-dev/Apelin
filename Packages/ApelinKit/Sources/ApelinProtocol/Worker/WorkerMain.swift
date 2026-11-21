import ApelinCore
import Darwin
import Foundation

/// What a worker's request handler is given.
public struct WorkerContext: Sendable {
    public let assignment: WorkerAssignment
    public let channel: WorkerChannel

    /// A worker's context over `channel`; `WorkerMain` makes the real one,
    /// and a test serves a worker's requests over a channel pair.
    public init(assignment: WorkerAssignment, channel: WorkerChannel) {
        self.assignment = assignment
        self.channel = channel
    }

    /// The session host, through the same typed facade the app uses. What a
    /// worker may call is decided by the host from the role it registered.
    public var host: ApelinService {
        ApelinService(transport: ChannelTransport(channel: channel))
    }

    public var dataFolder: DataFolder {
        DataFolder(home: assignment.home)
    }

    /// Appends an event to a task; the host numbers it.
    public func emit(_ taskID: TaskID, _ kind: String, _ payload: JSONValue? = nil) {
        try? channel.sendEvent(taskID: taskID, kind: kind, payload: payload)
    }

    /// Ends a task: the last event of every task is `state`.
    public func finish(_ taskID: TaskID, _ state: TaskState, message: String? = nil) {
        var payload: [String: JSONValue] = ["state": .string(state.rawValue)]
        if let message {
            payload["message"] = .string(message)
        }
        emit(taskID, TaskEvent.stateKind, .object(payload))
    }
}

/// How each worker executable starts. Its `main.swift` is one call:
///
///     WorkerMain.run(role: .build) { request, context in
///         switch request.request.operation { … }
///     }
///
/// The session host spawns the worker with its end of a socketpair as
/// descriptor 3 and everything else closed, already dropped to mobile for a
/// mobile role. The worker reads its assignment as the first frame, refuses
/// one for another role, drops privileges itself if it still has them
/// (defence in depth; the host should have), answers `ready`, then serves
/// requests until the host closes the channel.
public enum WorkerMain {
    public static let channelDescriptor: Int32 = 3

    public typealias Handler = @Sendable (ChannelRequest, WorkerContext) async -> (WireReply, [OwnedDescriptor])

    /// `onClose` runs when the host closes the channel (it stopped, or was
    /// killed), right before the worker exits.
    public static func run(
        role: WorkerRole,
        onCancel: (@Sendable (TaskID, WorkerContext) -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil,
        handler: @escaping Handler,
    ) -> Never {
        signal(SIGPIPE, SIG_IGN)
        var metadata = stat()
        guard fstat(channelDescriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK else {
            fputs("\(role.executableName): start this through apelind's session host\n", stderr)
            exit(EX_USAGE)
        }

        let channel = WorkerChannel(adopting: channelDescriptor)
        let assigned = DispatchSemaphore(value: 0)
        let box = AssignmentBox()
        channel.onClose {
            onClose?()
            exit(0)
        }
        channel.onControl { frame in
            switch frame.header.name {
            case WorkerControl.assign?:
                box.value = try? JSONCoding.decode(WorkerAssignment.self, from: frame.body)
                assigned.signal()
            case WorkerControl.cancel?:
                if let taskID = frame.header.taskID, let assignment = box.value {
                    onCancel?(taskID, WorkerContext(assignment: assignment, channel: channel))
                }
            default:
                break
            }
        }
        channel.start()

        guard assigned.wait(timeout: .now() + 10) == .success, let assignment = box.value else {
            fputs("\(role.executableName): no assignment from the host\n", stderr)
            exit(EX_PROTOCOL)
        }
        guard assignment.role == role, assignment.protocolVersion == Wire.protocolVersion else {
            fputs(
                "\(role.executableName): assigned \(assignment.role.rawValue) v\(assignment.protocolVersion)\n",
                stderr,
            )
            exit(EX_PROTOCOL)
        }
        guard role.runsAsRoot || dropToMobile() else {
            fputs("\(role.executableName): could not drop to mobile\n", stderr)
            exit(EX_NOPERM)
        }
        setenv("HOME", assignment.home, 1)

        let context = WorkerContext(assignment: assignment, channel: channel)
        channel.onRequest { request in await handler(request, context) }
        try? channel.sendControl(WorkerControl.ready)
        dispatchMain()
    }

    /// The handler's answer for an operation it has not written yet.
    public static func unimplemented(_ request: ChannelRequest) -> (WireReply, [OwnedDescriptor]) {
        (.failure(request.request.requestID, .unimplemented(request.request.operation)), [])
    }

    /// Decodes the request as `R`, runs `body`, encodes its answer.
    public static func serve<R: OperationRequest>(
        _: R.Type,
        _ request: ChannelRequest,
        _ body: (R) async throws -> R.Response,
    ) async -> (WireReply, [OwnedDescriptor]) {
        do {
            let typed = try request.request.decode(R.self)
            return try await (.success(request.request.requestID, body(typed)), [])
        } catch let error as ApelinError {
            return (.failure(request.request.requestID, error), [])
        } catch {
            return (.failure(request.request.requestID, ApelinError(.internal, String(describing: error))), [])
        }
    }

    /// Already mobile, or now mobile: groups, gid, then uid, and checked.
    static func dropToMobile() -> Bool {
        let uid = uid_t(WorkerRole.mobileUID)
        let gid = gid_t(WorkerRole.mobileGID)
        if getuid() == uid, geteuid() == uid, getgid() == gid, getegid() == gid {
            return true
        }
        var groups = [gid]
        guard setgroups(1, &groups) == 0, setgid(gid) == 0, setuid(uid) == 0 else { return false }
        return getuid() == uid && geteuid() == uid && getgid() == gid && setuid(0) != 0
    }
}

private final class AssignmentBox: @unchecked Sendable {
    private let lock = PthreadLock()
    private var stored: WorkerAssignment?
    var value: WorkerAssignment? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
