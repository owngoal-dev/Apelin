import ApelinProtocol
import Foundation

/// What `icli device passcode status` reads: the keybag's lock state and
/// its own failed-attempt counter, and icli's ledger of rejected passcodes.
struct KeybagStatus: Equatable, Sendable {
    /// MobileKeyBag's lock state: 0 unlocked, 3 no passcode, anything else
    /// locked (2 once the screen is off).
    var lockState: Int
    /// The keybag's counter, which only an unlock clears; nil when icli
    /// could not read it.
    var failedAttempts: Int?
    var backoffSeconds: Int = 0
    var permanentlyBlocked = false
    var recoveryCountdown: Int = 0
    /// Passcodes icli's ledger holds as rejected since its last unlock.
    var ledgerFailures: Int = 0

    var hasNoPasscode: Bool {
        lockState == 3
    }

    /// Unlocked, or with no passcode to unlock.
    var keybagUnlocked: Bool {
        lockState == 0 || lockState == 3
    }

    /// Why no passcode may be tried now, nil when one may: the device's own
    /// count, read again here before icli reads it, so that nothing is tried
    /// while a single failure, anyone's, is on record.
    var refusal: String? {
        guard let failedAttempts else {
            return "icli could not read how many failed passcode attempts the device has on record"
        }
        if failedAttempts > 0 {
            let count = failedAttempts == 1 ? "one failed passcode attempt" : "\(failedAttempts) failed passcode attempts"
            return "the device has \(count) on record; a person unlocks it with its passcode, which clears the count"
        }
        if backoffSeconds > 0 {
            return "the device is delaying passcode entry for \(backoffSeconds) s"
        }
        if permanentlyBlocked {
            return "the device has blocked passcode entry"
        }
        if recoveryCountdown > 0 {
            return "the device is counting down to recovery"
        }
        return nil
    }

    init(
        lockState: Int,
        failedAttempts: Int?,
        backoffSeconds: Int = 0,
        permanentlyBlocked: Bool = false,
        recoveryCountdown: Int = 0,
        ledgerFailures: Int = 0,
    ) {
        self.lockState = lockState
        self.failedAttempts = failedAttempts
        self.backoffSeconds = backoffSeconds
        self.permanentlyBlocked = permanentlyBlocked
        self.recoveryCountdown = recoveryCountdown
        self.ledgerFailures = ledgerFailures
    }

    /// icli's answer, or nil when it lacks the lock state.
    init?(json: [String: Any]) {
        guard let lockState = Self.integer(json["lock_state"]) else { return nil }
        self.init(
            lockState: lockState,
            failedAttempts: Self.integer(json["failed_attempts"]),
            backoffSeconds: Self.integer(json["backoff_seconds"]) ?? 0,
            permanentlyBlocked: json["permanently_blocked"] as? Bool ?? false,
            recoveryCountdown: Self.integer(json["recovery_countdown"]) ?? 0,
            ledgerFailures: Self.integer(json["ledger_failures"]) ?? 0,
        )
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }
}

/// What one `icli device passcode unlock` came to, read from its exit
/// status and its answer. icli promises that 0 unlocked (or found nothing to
/// unlock), 3 rejected the passcode now, 4 found it rejected before and
/// tried nothing, 5 refused before trying, 6 tried and the keybag did not
/// count it. Anything else — another status, a signal, no answer in time,
/// an answer that does not read — keeps no promise, and is taken as an
/// attempt that may have failed.
struct UnlockAnswer: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The keybag is unlocked; `attempted` says whether by this passcode.
        case unlocked(attempted: Bool)
        case rejected
        case rejectedBefore
        /// A guard of icli's stopped it before any attempt.
        case refused
        /// No promise kept: what happened is unknown.
        case unknown
    }

    var outcome: Outcome
    /// icli's hint, or what went wrong; never the passcode.
    var detail: String

    /// Reads icli's exit status (nil: killed, or never started) and answer.
    static func reading(status: Int32?, answer: [String: Any]?) -> UnlockAnswer {
        let hint = answer?["hint"] as? String ?? answer?["message"] as? String ?? ""
        let attempted = answer?["attempted"] as? Bool
        let result = answer?["result"] as? String
        func unknown(_ why: String) -> UnlockAnswer {
            UnlockAnswer(outcome: .unknown, detail: hint.isEmpty ? why : "\(why): \(hint)")
        }
        guard let status, answer != nil else {
            return unknown("icli did not answer")
        }
        // The exit status and the answer must agree, or neither is believed.
        switch (status, result, attempted) {
        case let (0, "unlocked", attempted?):
            return UnlockAnswer(outcome: .unlocked(attempted: attempted), detail: hint)
        case (3, "rejected", true):
            return UnlockAnswer(outcome: .rejected, detail: hint)
        case (4, "rejected_cached", false):
            return UnlockAnswer(outcome: .rejectedBefore, detail: hint)
        case (5, "refused", false):
            return UnlockAnswer(outcome: .refused, detail: hint)
        default:
            return unknown("icli ended with status \(status) and result \(result ?? "none")")
        }
    }
}

/// Why icli's passcode commands could not be asked.
enum KeybagFailure: Error, Equatable {
    /// icli has no `device passcode` (older than 0.11.0).
    case outdated
    /// icli is missing, unsafe to hand a passcode, or answered nothing that reads.
    case failed(String)

    var detail: String {
        switch self {
        case .outdated: "icli has no device passcode command; it needs icli 0.11.0 or later"
        case let .failed(message): message
        }
    }
}

/// icli's `device passcode` commands: the keybag's state, one attempt, and
/// clearing icli's ledger of rejected passcodes. What `status` and
/// `forgetRejected` throw is a `KeybagFailure`.
protocol PasscodeKeybag: Sendable {
    func status() throws -> KeybagStatus
    /// One attempt with `passcode`, under `DevicePasscode.maximumFailures`.
    /// Never throws: whatever happened is in the answer.
    func unlock(passcode: String) -> UnlockAnswer
    func forgetRejected() throws
}
