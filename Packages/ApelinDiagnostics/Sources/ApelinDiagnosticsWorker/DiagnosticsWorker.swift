import ApelinCore
import ApelinCrashBlame
import ApelinCrashReport
import ApelinCrashSymbols
import ApelinDiagnostics
import ApelinLogReaderWorker
import ApelinProtocol
import ConfirmLoaded
import Foundation

/// `apelin-diagnostics`: logs, crash reports, load confirmation, the screen
/// and the UI, every one through icli where icli can (the owner's rule), as
/// mobile. The session host forwards `logStream` and `confirmLoaded` (both
/// tasks, which its cancel stops), `crashList`, `crashSymbolicate`,
/// `captureScreen`, `readUITree`,
/// `uiAction` and the app's device passcode (`devicePasscodeState`,
/// `devicePasscodeSave`, `devicePasscodeRemove`, kept in this worker's own
/// keychain group: `DeviceUnlock`); the worker asks the host for two things
/// only — a protected crash report by id (`crashOpen`) and the respring
/// `confirmLoaded` triggers.
public enum DiagnosticsWorker {
    public static func main() -> Never {
        #if os(iOS) && canImport(IcliKit)
            let diagnostics = Diagnostics()
        #else
            let diagnostics = Diagnostics(icli: UnavailableIcli())
        #endif
        let pump = LogStreamPump(source: diagnostics)
        let loadChecks = LoadCheckRegistry()
        // One for the worker's life: the passcode's uses take turns.
        let passcodeTurns = PthreadLock()
        WorkerMain.run(role: .diagnostics, onCancel: { taskID, _ in
            pump.cancel(taskID)
            loadChecks.cancel(taskID)
        }) { request, context in
            var service = DiagnosticsService(
                diagnostics: diagnostics,
                host: context.host,
                home: context.assignment.home,
                installRoot: context.assignment.installRoot,
                emit: { taskID, kind, payload in context.emit(taskID, kind, payload) },
            )
            service.loadChecks = loadChecks
            service.deviceUnlock = DeviceUnlock(
                diagnostics: diagnostics,
                keybag: IcliPasscodeCommand(installRoot: context.assignment.installRoot, home: context.assignment.home),
                store: KeychainDevicePasscodeStore(),
                serial: passcodeTurns,
            )
            if request.request.operation == .logStream {
                return LogReaderWorker.serve(request, context: context, pump: pump)
            }
            return await service.handle(request)
        }
    }
}

/// Every operation but the log stream, testable with a fake icli and a fake
/// host.
public struct DiagnosticsService: Sendable {
    public let diagnostics: Diagnostics
    public let host: ApelinService
    public let home: String
    public let installRoot: String
    /// Appends an event to one of this worker's tasks; the host numbers it.
    public var emit: @Sendable (TaskID, String, JSONValue?) -> Void
    /// The device passcode and the unlock that uses it; nil where nothing
    /// set it up, which answers `unavailable`.
    var deviceUnlock: DeviceUnlock?
    /// The load checks running, for the host's cancel. The worker keeps
    /// one for its life; a service made alone has its own.
    public var loadChecks = LoadCheckRegistry()
    /// How often a load check looks at the process list.
    var processLookInterval = ConfirmLoaded.defaultLookInterval

    public init(
        diagnostics: Diagnostics,
        host: ApelinService,
        home: String,
        installRoot: String,
        emit: @escaping @Sendable (TaskID, String, JSONValue?) -> Void = { _, _, _ in },
    ) {
        self.diagnostics = diagnostics
        self.host = host
        self.home = home
        self.installRoot = installRoot
        self.emit = emit
    }

    public func handle(_ request: ChannelRequest) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .crashList:
            await WorkerMain.serve(CrashListRequest.self, request) { list in
                try await blocking { try crashList(list) }
            }
        case .crashSymbolicate:
            await WorkerMain.serve(CrashSymbolicateRequest.self, request) { try await crashSymbolicate($0) }
        case .confirmLoaded:
            await WorkerMain.serve(ApelinProtocol.ConfirmLoadedRequest.self, request) { confirm in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "A confirmLoaded request needs a task ID.")
                }
                try await startConfirmLoaded(confirm, taskID: taskID)
                return TaskHandle(taskID: taskID, kind: .confirmLoaded)
            }
        case .captureScreen:
            await reply(request) {
                let shot = try await blocking { try mapped { try diagnostics.screenshot() } }
                let descriptor = try DescriptorFile.holding(shot.jpeg)
                return (
                    ApelinProtocol.CaptureScreenResponse(
                        image: DescriptorSlot(index: 0),
                        width: shot.width,
                        height: shot.height,
                    ),
                    [descriptor],
                )
            }
        case .readUITree:
            await WorkerMain.serve(ApelinProtocol.ReadUITreeRequest.self, request) { try await readUITree($0) }
        case .uiAction:
            await WorkerMain.serve(ApelinProtocol.UIActionRequest.self, request) { try await uiAction($0) }
        case .devicePasscodeState:
            await WorkerMain.serve(DevicePasscodeStateRequest.self, request) { _ in
                let passcodes = try requireDeviceUnlock()
                return try await blocking { try passcodes.state() }
            }
        case .devicePasscodeSave:
            await WorkerMain.serve(DevicePasscodeSaveRequest.self, request) { save in
                let passcodes = try requireDeviceUnlock()
                return try await blocking { try mapped { try passcodes.saveAndTest(save.passcode) } }
            }
        case .devicePasscodeRemove:
            await WorkerMain.serve(DevicePasscodeRemoveRequest.self, request) { _ in
                let passcodes = try requireDeviceUnlock()
                try await blocking { try passcodes.remove() }
                return Acknowledged()
            }
        default:
            WorkerMain.unimplemented(request)
        }
    }

    // MARK: Helpers

    func requireDeviceUnlock() throws -> DeviceUnlock {
        guard let deviceUnlock else {
            throw ApelinError(.unavailable, "The device passcode is not available here.")
        }
        return deviceUnlock
    }

    private func reply(
        _ request: ChannelRequest,
        _ body: () async throws -> (Encodable & Sendable, [OwnedDescriptor]),
    ) async -> (WireReply, [OwnedDescriptor]) {
        do {
            let (value, descriptors) = try await body()
            return (.success(request.request.requestID, EncodableBox(value)), descriptors)
        } catch let error as ApelinError {
            return (.failure(request.request.requestID, error), [])
        } catch {
            return (.failure(request.request.requestID, ApelinError(.internal, String(describing: error))), [])
        }
    }
}

/// icli's calls block for their window: run them off the cooperative pool.
func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try body() })
        }
    }
}

func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: body())
        }
    }
}

/// A diagnostics error as the wire says it.
func mapped<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as DiagnosticsError {
        switch error {
        case let .invalidParameter(message): throw ApelinError(.badRequest, message)
        case let .unavailable(message): throw ApelinError(.unavailable, message)
        case .locked: throw ApelinError(.conflict, error.localizedDescription)
        case let .failed(message): throw ApelinError(.internal, message)
        }
    }
}

private struct EncodableBox: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// An unlinked temporary file holding `data`, rewound, as a descriptor to
/// pass: a pipe would block the writer before the reader has the other end.
enum DescriptorFile {
    static func holding(_ data: Data) throws -> OwnedDescriptor {
        var template = Array((NSTemporaryDirectory() + "apelin-diagnostics.XXXXXX").utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard descriptor >= 0 else {
            throw ApelinError(.internal, "Could not create a temporary file: \(String(cString: strerror(errno)))")
        }
        let owned = OwnedDescriptor(adopting: descriptor)
        unlink(String(cString: template))
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count, lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw ApelinError(.internal, "Could not prepare the attachment.")
        }
        return owned
    }
}
