import struct ApelinProtocol.ApelinError
import Foundation

/// How a tool call ended, as its journal line says.
enum ToolCallStatus: String, Sendable {
    case succeeded
    case failed
    /// The approval policy, the user, the host or the tool's own rules
    /// refused it.
    case denied
    case cancelled
    case timedOut = "timed-out"
    /// It never ended: the conversation closed, or the process that ran it
    /// went, while it was running.
    case interrupted

    var level: DiagnosticLevel {
        switch self {
        case .succeeded, .cancelled: .info
        case .failed, .denied, .timedOut: .warning
        case .interrupted: .error
        }
    }
}

/// What the runner decided about a call before kwwk ends it, where that
/// was decided: a refusal, a stop or a timeout, and by what. A call that
/// returns or throws anything else ends as kwwk says it did.
struct ToolCallOutcome: Sendable, Equatable {
    var status: ToolCallStatus
    var detail: String?

    init(_ status: ToolCallStatus, _ detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    /// What a call that threw `error` came to; `stopped` when the run was
    /// stopped while it went.
    static func of(_ error: any Error, stopped: Bool) -> ToolCallOutcome {
        if stopped || error is CancellationError {
            return ToolCallOutcome(.cancelled, "the run was stopped")
        }
        switch error {
        case let refusal as ApelinError:
            // a sign-in that is missing is a failure to fix, no refusal
            if refusal.reason == .authenticationRequired {
                return ToolCallOutcome(.failed, "a sign-in is needed")
            }
            return switch refusal.code {
            case .denied: ToolCallOutcome(.denied, "the session host refused it")
            case .timeout: ToolCallOutcome(.timedOut, "the session host's time ran out")
            case .cancelled: ToolCallOutcome(.cancelled, "the session host cancelled it")
            default: ToolCallOutcome(.failed, "the session host answered \(refusal.code.rawValue)")
            }
        case is ConversationClosingError:
            return ToolCallOutcome(.cancelled, "the conversation was closing")
        case is ToolDeniedError:
            return ToolCallOutcome(.denied, "the tool refused it")
        case is HostRefusedPresetError:
            return ToolCallOutcome(.denied, "the session host does not count it as a preset")
        case let failure as ToolExtensionError where failure.code == "timeout":
            return ToolCallOutcome(.timedOut, "the extension did not answer in time")
        case is ToolTimeoutError:
            return ToolCallOutcome(.timedOut)
        case let failure as URLError where failure.code == .timedOut:
            return ToolCallOutcome(.timedOut, "the request timed out")
        default:
            return ToolCallOutcome(.failed)
        }
    }
}

/// A call that ran out of time before it answered: thrown where the time
/// is kept, so the journal says timed out rather than failed. The model
/// reads its message as it would any refusal's.
struct ToolTimeoutError: Error, LocalizedError {
    var message: String
    var errorDescription: String? {
        message
    }
}

/// A call that could not start because its conversation was closing: a
/// stop, not a refusal. The model reads it as it read the refusal before.
struct ConversationClosingError: Error, LocalizedError {
    var errorDescription: String? {
        "the conversation is closing"
    }
}
