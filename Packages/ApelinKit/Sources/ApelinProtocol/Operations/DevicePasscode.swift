import ApelinCore
import Foundation

// The device passcode (owner, 2026-11-21): the user saves this device's
// passcode in Settings so that an agent can unlock the device for automated
// testing, through `uiAction` `press` `unlock` (wake, unlock, Home Screen).
// apelin-diagnostics alone keeps it, in a keychain group only it carries, and
// hands it to icli's `device passcode unlock` on standard input, never in
// argv, a file, an event, a log or a reply. It is usable only once a test
// that calls that command line has unlocked the device with it; one that
// fails saves nothing, and a later rejection removes it. Every attempt runs
// with `--max-failures 1` after icli's own status read zero failed attempts,
// so Apelin never makes a second attempt before a person (or a right
// passcode) has unlocked the device: a device that erases itself after ten
// failures, or delays entry from the fifth, is never brought near either.
// The three operations are the app's alone (CallerPolicy), and the console
// refuses `devicePasscodeSave` before sending it.

/// The passcode rules both sides read.
public enum DevicePasscode {
    /// The `uiAction` `press` that unlocks: wake, the saved passcode when the
    /// device's keybag is locked, then the Home Screen.
    public static let unlockButton = "unlock"
    /// icli's `--max-failures` for every attempt: nothing is tried while any
    /// failed attempt is on record, the user's own mistypes included.
    public static let maximumFailures = 1
    /// What icli reads: the first line of its standard input, 1–128 bytes.
    public static let maximumBytes = 128

    /// Nil when icli would take `passcode` whole, else why not. icli reads
    /// only the first line, so a line break would send a different passcode.
    public static func problem(_ passcode: String) -> String? {
        guard !passcode.isEmpty else { return "the passcode is empty" }
        guard passcode.utf8.count <= maximumBytes else { return "the passcode is longer than \(maximumBytes) bytes" }
        guard !passcode.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else {
            return "the passcode holds a line break or a NUL character"
        }
        return nil
    }
}

/// How `press` `unlock` left the device unlocked (`UIActionResponse`
/// ▸ `unlockedBy`), so the agent says what happened and never that it used
/// a passcode it did not.
public enum DeviceUnlockPath: String, Codable, Sendable {
    /// Already unlocked with its screen on: nothing was pressed.
    case nothing
    /// Already unlocked with its screen off: it was only woken.
    case wake
    /// Locked with its keybag unlocked (no passcode, or one not asked for
    /// yet): woken and taken past the Lock Screen, no passcode used.
    case lockScreen
    /// Locked with its keybag locked: the saved passcode unlocked it.
    case passcode
}

/// The device as `icli device passcode status` reads it.
public enum DevicePasscodeDevice: String, Codable, Sendable {
    /// The device has a passcode, and icli can unlock its keybag with one.
    case passcode
    /// The device has no passcode: an unlock wakes it and goes to the Home
    /// Screen, and nothing needs saving.
    case noPasscode
    /// icli has no `device passcode` (it is older than 0.11.0).
    case icliOutdated
    /// icli is missing, or answered something that does not read.
    case unknown
}

public struct DevicePasscodeState: Codable, Sendable, Equatable {
    /// A passcode is saved and passed its test: an unlock may use it.
    public var saved: Bool
    public var device: DevicePasscodeDevice

    public init(saved: Bool, device: DevicePasscodeDevice) {
        self.saved = saved
        self.device = device
    }
}

/// Whether a passcode is saved, and what the device is.
public struct DevicePasscodeStateRequest: OperationRequest {
    public typealias Response = DevicePasscodeState
    public static let operation = AppOperation.devicePasscodeState

    public init() {}
}

/// How a Test and Save ended. Only `saved` keeps the passcode.
public enum DevicePasscodeTestOutcome: String, Codable, Sendable {
    /// icli unlocked the device with it: it is saved, and usable.
    case saved
    /// The device has no passcode; nothing was saved or tried.
    case noPasscode
    /// The device rejected it, as one failed attempt; nothing was saved.
    case rejected
    /// Nothing was tried: a failed attempt was on record, or the device was
    /// delaying passcode entry.
    case refused
    /// The device did not lock, or did not ask for its passcode, in time;
    /// nothing was tried.
    case didNotLock
    /// icli has no `device passcode`; nothing was tried.
    case icliOutdated
    /// The test did not finish as icli promises (an error, no answer in
    /// time, an answer that does not read); nothing was saved.
    case failed
}

/// Saves `passcode` and tests it: the device locks, and icli's `device
/// passcode unlock` unlocks it with the passcode, once. The reply comes once
/// the test is over; the app, sent to the background by the lock meanwhile,
/// reads `devicePasscodeState` again if the reply is lost.
public struct DevicePasscodeSaveRequest: OperationRequest {
    public typealias Response = DevicePasscodeSaveResponse
    public static let operation = AppOperation.devicePasscodeSave
    public var passcode: String

    public init(passcode: String) {
        self.passcode = passcode
    }
}

public struct DevicePasscodeSaveResponse: Codable, Sendable, Equatable {
    public var outcome: DevicePasscodeTestOutcome
    /// The failed passcode attempts the device counted after the test, when
    /// icli read them.
    public var failedAttempts: Int?
    /// In English, for the journal: what icli or the test said. Never the
    /// passcode.
    public var detail: String?
    public var state: DevicePasscodeState

    public init(
        outcome: DevicePasscodeTestOutcome,
        failedAttempts: Int? = nil,
        detail: String? = nil,
        state: DevicePasscodeState,
    ) {
        self.outcome = outcome
        self.failedAttempts = failedAttempts
        self.detail = detail
        self.state = state
    }
}

/// Removes the saved passcode; none saved is no error.
public struct DevicePasscodeRemoveRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.devicePasscodeRemove

    public init() {}
}

public extension ApelinError.Reason {
    /// `uiAction` `press` `unlock`, `conflict`: the device's keybag is
    /// locked and no passcode that passed its test is saved. Nothing was
    /// done; the user unlocks it, or saves and tests the passcode first.
    static let devicePasscodeNotSaved = ApelinError.Reason(rawValue: "devicePasscodeNotSaved")
    /// `uiAction` `press` `unlock`, `conflict`: nothing was tried, because a
    /// failed passcode attempt is on record or the device is delaying entry.
    /// A person unlocks the device, which clears the count.
    static let devicePasscodeRefused = ApelinError.Reason(rawValue: "devicePasscodeRefused")
    /// `uiAction` `press` `unlock`, `denied`: the saved passcode was rejected,
    /// or the attempt did not end as icli promises; it is removed, and only
    /// a new Test and Save brings one back.
    static let devicePasscodeRejected = ApelinError.Reason(rawValue: "devicePasscodeRejected")
}

public extension ApelinService {
    func devicePasscodeState() async throws -> DevicePasscodeState {
        try await send(DevicePasscodeStateRequest())
    }

    func devicePasscodeSave(_ request: DevicePasscodeSaveRequest) async throws -> DevicePasscodeSaveResponse {
        try await send(request)
    }

    func devicePasscodeRemove() async throws {
        _ = try await send(DevicePasscodeRemoveRequest())
    }
}
