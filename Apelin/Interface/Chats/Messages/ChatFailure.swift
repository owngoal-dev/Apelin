import ApelinProtocol
import Foundation

/// What an error in a conversation says: one short line naming what went
/// wrong, and under it what to do about it or what the provider said.
///
/// The agent names the failures it can tell apart (the reasons of
/// ApelinProtocol's `AgentFailure.swift`), and each of those is said here,
/// in the reader's language. Any other comes in the words it was recorded
/// with.
struct ChatFailure: Hashable {
    var title: String
    var detail: String

    /// An `error` event's failure: `message` as it was recorded, `reason`
    /// when the agent gave one.
    init(message: String, reason: ApelinError.Reason?) {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        title = reason.flatMap(Self.title(for:)) ?? String(localized: "Something Went Wrong")
        if let advice = reason.flatMap(Self.advice(for:)) {
            detail = advice
        } else if message.isEmpty {
            detail = reason.flatMap(Self.fallback(for:)) ?? ""
        } else {
            detail = message
        }
    }

    /// The line a failure the agent named goes by, nil for one this
    /// version does not know.
    static func title(for reason: ApelinError.Reason) -> String? {
        switch reason {
        case .offline: String(localized: "No Internet Connection")
        case .network: String(localized: "Unable to Reach Model Provider")
        case .timeout: String(localized: "Request Timed Out")
        case .authentication: String(localized: "Sign-In Not Accepted")
        case .quota: String(localized: "Usage Limit Reached")
        case .rateLimit: String(localized: "Too Many Requests")
        case .server: String(localized: "Model Provider Error")
        case .contextOverflow: String(localized: "Chat Too Long")
        default: nil
        }
    }

    /// What to do about a failure whose cause says it: these replace the
    /// provider's words, which only repeat the title.
    private static func advice(for reason: ApelinError.Reason) -> String? {
        switch reason {
        case .offline: String(localized: "Connect to the internet, then send your message again.")
        case .network: String(localized: "Check your network or proxy, then send your message again.")
        case .timeout: String(localized: "The model provider did not answer in time. Send your message again.")
        case .authentication: String(localized: "Check this provider’s sign-in in Settings ▸ Model Providers.")
        case .contextOverflow: String(localized: "Compact the context or start a new chat, then send your message again.")
        default: nil
        }
    }

    /// What stands under a failure whose provider said nothing of its own.
    private static func fallback(for reason: ApelinError.Reason) -> String? {
        switch reason {
        case .rateLimit, .server: String(localized: "Wait a moment, then send your message again.")
        default: nil
        }
    }

    /// Both lines as one, for VoiceOver and the pasteboard.
    var spoken: String {
        [title, detail].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
