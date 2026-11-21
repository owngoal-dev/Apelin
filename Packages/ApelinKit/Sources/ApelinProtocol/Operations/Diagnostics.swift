import ApelinCore

// Diagnostics and UI: confirm a build's tweak loaded (marker log, loaded
// images, filter check), screenshots, the UI tree, one structured UI action.
// Served by apelin-diagnostics (Workers/Diagnostics; Packages/ApelinDiagnostics)
// through the session host. `targetID` names a process or app the host has
// bound to this verification; never a command.

public struct LoadEvidence: Codable, Sendable, Equatable {
    /// `log`, `image`, `filter`, and `trigger` when the trigger failed.
    public var kind: String
    public var passed: Bool
    /// Starts with the evidence's status — `confirmed`, `absent`,
    /// `unavailable` or `notRead` — then a colon and the reason.
    public var detail: String

    public init(kind: String, passed: Bool, detail: String) {
        self.kind = kind
        self.passed = passed
        self.detail = detail
    }
}

/// What `confirmLoaded` does before it looks, if anything.
public enum LoadTrigger: String, Codable, Sendable {
    /// Start listening for the marker, then respring, so the line the tweak
    /// logs from its constructor is seen. The respring takes the app down;
    /// the task, and its answer, stay with the session host.
    case respring
}

/// A request to read the target's image list. Still decoded, so an older
/// caller's request reads, and always refused (`badRequest`): on the
/// iOS 27.0.1 vphone (2026-10-17), reading SpringBoard's image list from
/// apelin-diagnostics panicked the kernel ("VM entry … lock is invalid",
/// vm_entry_lock.c:168) — twice while the task-port read of dyld's image
/// infos was in place, then once more through the kernel's region paths
/// alone. Neither reader exists any more.
public enum LoadImageCheck: String, Codable, Sendable {
    /// `proc_pidinfo(PROC_PIDREGIONPATHINFO)` over the target's map. Refused.
    case regionPaths
}

/// `buildID` is the build's `APELIN_BUILD_ID` (the marker is `ApelinLoaded
/// <buildID>`); `targetID` an executable name (`SpringBoard`) or a bundle
/// id (`com.apple.springboard`). With `projectID`, the marker's subsystem,
/// the installed dylib and the filter come from the project's
/// `apelin-project.json`; without it only the marker is checked.
///
/// A task (`confirmLoaded` kind) the session host owns: the reply is its
/// handle, the request checked first — a bad one is the reply, not a failed
/// task. Its events are `stage` {stage: `listening` | `trigger`}
/// and a final `state` whose `result` is the `ConfirmLoadedResponse`; the
/// task succeeds when the check ran, whatever it found. Read it with
/// `confirmLoadedAttach`; nobody need be attached for the answer to be kept.
public struct ConfirmLoadedRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.confirmLoaded
    public var buildID: String
    public var targetID: String
    public var projectID: String?
    public var trigger: LoadTrigger?
    /// How long to listen for the marker, 1–60 seconds (default 30 with a
    /// respring, which has to bring SpringBoard back inside it; 15 without).
    public var logWindowSeconds: Double?
    /// Must be nil: any value is refused (`badRequest`), see
    /// `LoadImageCheck`. The image evidence is always `notRead`.
    public var imageCheck: LoadImageCheck?

    public init(
        buildID: String,
        targetID: String,
        projectID: String? = nil,
        trigger: LoadTrigger? = nil,
        logWindowSeconds: Double? = nil,
        imageCheck: LoadImageCheck? = nil,
    ) {
        self.buildID = buildID
        self.targetID = targetID
        self.projectID = projectID
        self.trigger = trigger
        self.logWindowSeconds = logWindowSeconds
        self.imageCheck = imageCheck
    }
}

/// The answer, carried as `result` in the task's final `state` event.
public struct ConfirmLoadedResponse: Codable, Sendable, Equatable {
    /// The member of the final `state` payload that holds this.
    public static let stateMember = "result"

    public var loaded: Bool
    public var evidence: [LoadEvidence]

    public init(loaded: Bool, evidence: [LoadEvidence] = []) {
        self.loaded = loaded
        self.evidence = evidence
    }

    /// The answer a finished load-check task carries, or why it has none.
    public static func from(finalState event: TaskEvent) throws -> ConfirmLoadedResponse {
        let payload = event.payload
        let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))
        if state == .succeeded, let result = payload?[stateMember],
           let response = try? result.decode(ConfirmLoadedResponse.self)
        {
            return response
        }
        let message = payload?["message"]?.stringValue ?? "the load check ended \(state?.rawValue ?? "without a state")"
        switch state {
        case .cancelled?: throw ApelinError(.cancelled, message)
        case .interrupted?: throw ApelinError(.unavailable, message)
        default: throw ApelinError(.internal, message)
        }
    }
}

/// Reads `confirmLoaded` tasks.
public struct ConfirmLoadedAttachRequest: TaskAttachRequest {
    public static let operation = AppOperation.confirmLoadedAttach
    public var taskID: TaskID
    public var afterSeq: EventSeq
    public var waitMilliseconds: Int

    public init(taskID: TaskID, afterSeq: EventSeq = .start, waitMilliseconds: Int = Self.defaultWaitMilliseconds) {
        self.taskID = taskID
        self.afterSeq = afterSeq
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct CaptureScreenRequest: OperationRequest {
    public typealias Response = CaptureScreenResponse
    public static let operation = AppOperation.captureScreen
    public var targetID: String?
    public init(targetID: String? = nil) {
        self.targetID = targetID
    }
}

public struct CaptureScreenResponse: Codable, Sendable, Equatable {
    /// The image (JPEG), in the reply's descriptor list.
    public var image: DescriptorSlot
    public var width: Int
    public var height: Int

    public init(image: DescriptorSlot, width: Int, height: Int) {
        self.image = image
        self.width = width
        self.height = height
    }
}

public struct ReadUITreeRequest: OperationRequest {
    public typealias Response = ReadUITreeResponse
    public static let operation = AppOperation.readUITree
    public var targetID: String?
    public init(targetID: String? = nil) {
        self.targetID = targetID
    }
}

public struct ReadUITreeResponse: Codable, Sendable, Equatable {
    public var tree: JSONValue
    public init(tree: JSONValue) {
        self.tree = tree
    }
}

/// One action of a fixed kind with fixed parameters.
public enum UIAction: Codable, Sendable, Equatable {
    case tap(x: Double, y: Double)
    /// The element whose identifier is `identifier`, or else whose text is
    /// `text`, as `readUITree` listed it.
    case tapElement(text: String?, identifier: String?)
    case type(text: String)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Int)
    /// `wake`, `home`, `lock` (the side button) or `unlock`. Only a wake and
    /// an unlock run while the device is locked or its screen is off. An
    /// unlock (`DevicePasscode.unlockButton`) wakes the device, unlocks its
    /// keybag with the passcode saved and tested in Settings when it is
    /// locked, passes the Lock Screen and goes to the Home Screen; on a
    /// device already unlocked and lit it does nothing. It takes no target,
    /// and the app beneath the Lock Screen does not refuse it, since what it
    /// leaves in front is the Home Screen.
    case press(button: String)
}

/// What an action left. A wake and an unlock say whether the device is
/// still locked and its screen still off. A `type` says what it left in the frontmost app,
/// read back from its UI tree: the values its visible elements took on
/// while the text went in, and whether one holds the text, so characters
/// that did not land can be seen. Every other action, and a `type` whose
/// tree could not be read, answers none of them.
public struct UIActionResponse: Codable, Sendable, Equatable {
    public var locked: Bool?
    public var screenOff: Bool?
    public var typedTextMatches: Bool?
    public var fieldValues: [String]?

    public init(
        locked: Bool? = nil,
        screenOff: Bool? = nil,
        typedTextMatches: Bool? = nil,
        fieldValues: [String]? = nil,
    ) {
        self.locked = locked
        self.screenOff = screenOff
        self.typedTextMatches = typedTextMatches
        self.fieldValues = fieldValues
    }
}

public struct UIActionRequest: OperationRequest {
    public typealias Response = UIActionResponse
    public static let operation = AppOperation.uiAction
    public var targetID: String?
    public var action: UIAction
    /// Apps the action may not reach, as a target or in front: the session
    /// host's to set, never a caller's (Apelin itself for an agent).
    /// Absent on the wire when nil.
    public var refusedBundleIDs: [String]?

    public init(targetID: String? = nil, action: UIAction, refusedBundleIDs: [String]? = nil) {
        self.targetID = targetID
        self.action = action
        self.refusedBundleIDs = refusedBundleIDs
    }
}

public extension ApelinService {
    /// Starts a load check; follow it with `events(of:)`.
    func confirmLoadedStart(_ request: ConfirmLoadedRequest) async throws -> TaskHandle {
        try await send(request)
    }

    func confirmLoadedAttach(_ request: ConfirmLoadedAttachRequest) async throws -> TaskEventBatch {
        try await send(request)
    }

    /// Starts a load check and reads it to its end. A caller the trigger's
    /// respring takes down loses only this wait: the task stays with the
    /// session host, and `confirmLoadedAttach` reads its answer later.
    func confirmLoaded(
        buildID: String,
        targetID: String,
        projectID: String? = nil,
        trigger: LoadTrigger? = nil,
        logWindowSeconds: Double? = nil,
        imageCheck: LoadImageCheck? = nil,
    ) async throws -> ConfirmLoadedResponse {
        let handle = try await confirmLoadedStart(ConfirmLoadedRequest(
            buildID: buildID,
            targetID: targetID,
            projectID: projectID,
            trigger: trigger,
            logWindowSeconds: logWindowSeconds,
            imageCheck: imageCheck,
        ))
        var last: TaskEvent?
        for try await event in events(of: handle) where event.kind == TaskEvent.stateKind {
            last = event
        }
        guard let last else { throw ApelinError(.internal, "the load check ended without a state") }
        return try ConfirmLoadedResponse.from(finalState: last)
    }

    func captureScreen(targetID: String? = nil) async throws -> (CaptureScreenResponse, OwnedDescriptor?) {
        let (response, descriptors) = try await sendReturningDescriptors(CaptureScreenRequest(targetID: targetID))
        return (response, descriptors.indices.contains(response.image.index) ? descriptors[response.image.index] : nil)
    }

    func readUITree(targetID: String? = nil) async throws -> ReadUITreeResponse {
        try await send(ReadUITreeRequest(targetID: targetID))
    }

    @discardableResult
    func uiAction(_ action: UIAction, targetID: String? = nil) async throws -> UIActionResponse {
        try await send(UIActionRequest(targetID: targetID, action: action))
    }
}
