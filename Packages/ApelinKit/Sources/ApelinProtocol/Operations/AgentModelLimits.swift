import Foundation

/// A model's context window and largest reply, as the user set them for one
/// model of an API-key account (Settings ▸ Model Providers ▸ Models; #68).
/// Providers, relays and gateways differ, and what kwwk's catalog says, or
/// what it assumes for a model it does not know, is not always what the
/// endpoint serves.
///
/// A field left out is automatic: the value the session's model resolves
/// with, as before. The window is what the context is measured against —
/// automatic compaction at `AgentContextBudget.automaticCompaction` of it,
/// the reply's headroom, the note that suggests compacting — and the
/// output caps one reply, sent as each wire's own field (`max_tokens`,
/// `max_completion_tokens`, `max_output_tokens`). Neither can raise what the
/// server itself allows.
///
/// It travels with the model on `agentOpen` and `agentPrompt`; absent is
/// automatic, so an older caller and the console change nothing.
public struct AgentModelLimits: Codable, Sendable, Hashable {
    public var contextWindow: Int?
    public var maxOutputTokens: Int?

    /// The windows Apelin takes: kwwk reads a smaller one as a test double.
    public static let contextWindowRange = 1024 ... 10_000_000
    public static let maxOutputRange = 1 ... 1_000_000
    /// Apelin's instructions and tool definitions go with every request,
    /// about 26,000 tokens of it (measured 2026-11-21), so a window below
    /// this starts a chat at 40 % or more.
    public static let smallContextWindow = 64000
    /// Below this, a reply, and a reasoning model's thinking with it, is
    /// cut short.
    public static let smallMaxOutput = 1024

    public init(contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }

    public var isAutomatic: Bool {
        contextWindow == nil && maxOutputTokens == nil
    }

    /// With the window set and the output left automatic, the automatic
    /// reply is at most this share of the window: a quarter, the headroom
    /// kwwk keeps for a model whose output it has no limit for
    /// (`AgentRequestBudget.outputReserveTokens`), so three quarters stay
    /// for the conversation. Left alone, a model's own automatic output
    /// stays what it was for its own window: 64,000 for an
    /// OpenAI-compatible model, which a 65,000 window cannot hold beside the
    /// conversation, and which an endpoint that holds to its window refuses.
    public static let automaticOutputShare = 4

    /// The reply a model is asked for when the output is automatic at
    /// `automatic` (nil where nothing goes on the wire) and the window is
    /// the one the user set, `window` (nil when automatic too): `automatic`,
    /// at most a quarter of a window the user set.
    public static func automaticOutput(_ automatic: Int?, window: Int?) -> Int? {
        guard let automatic, let window else { return automatic }
        return min(automatic, max(1, window / automaticOutputShare))
    }

    /// What can never be saved.
    public enum Problem: Sendable, Hashable {
        case contextWindowOutOfRange
        case maxOutputOutOfRange
        /// The reply must leave room for what it answers.
        case outputNotBelowWindow
    }

    /// What can be saved, after the user is told.
    public enum Warning: Sendable, Hashable {
        case smallContextWindow
        /// More than half the window goes to the reply.
        case outputTakesMostOfWindow
        case smallMaxOutput
    }

    /// `automaticWindow`: the window a model has when `contextWindow` is
    /// automatic, where it is known.
    public func problems(automaticWindow: Int? = nil) -> [Problem] {
        var problems: [Problem] = []
        if let contextWindow, !Self.contextWindowRange.contains(contextWindow) {
            problems.append(.contextWindowOutOfRange)
        }
        if let maxOutputTokens, !Self.maxOutputRange.contains(maxOutputTokens) {
            problems.append(.maxOutputOutOfRange)
        }
        if let maxOutputTokens, let window = contextWindow ?? automaticWindow, maxOutputTokens >= window {
            problems.append(.outputNotBelowWindow)
        }
        return problems
    }

    public func warnings(automaticWindow: Int? = nil) -> [Warning] {
        var warnings: [Warning] = []
        if let contextWindow, contextWindow < Self.smallContextWindow {
            warnings.append(.smallContextWindow)
        }
        if let maxOutputTokens, let window = contextWindow ?? automaticWindow,
           maxOutputTokens < window, maxOutputTokens > window / 2
        {
            warnings.append(.outputTakesMostOfWindow)
        }
        if let maxOutputTokens, maxOutputTokens < Self.smallMaxOutput {
            warnings.append(.smallMaxOutput)
        }
        return warnings
    }

    /// What a session takes from the wire: each field inside its range, and
    /// an output below the window when both are set; anything else is left
    /// automatic, as if it had not been sent. Nil when nothing is left.
    public var sanitized: AgentModelLimits? {
        var limits = self
        if let window = contextWindow, !Self.contextWindowRange.contains(window) {
            limits.contextWindow = nil
        }
        if let output = maxOutputTokens, !Self.maxOutputRange.contains(output) {
            limits.maxOutputTokens = nil
        }
        if let output = limits.maxOutputTokens, let window = limits.contextWindow, output >= window {
            limits.maxOutputTokens = nil
        }
        return limits.isAutomatic ? nil : limits
    }
}

/// How full a conversation's context may get, measured against the model's
/// window as kwwk estimates it before every request.
public enum AgentContextBudget {
    /// Past this share of the window the session compacts the conversation
    /// on its own, before the next request (owner, 2026-11-21).
    public static let automaticCompaction = 0.75
    /// The shares at which a tool's result ends with a note suggesting
    /// `apelin_conversation_compact`, each once until the context falls
    /// below it again, as it does after a compaction.
    public static let suggestions = [50, 60, 70]
    /// Below this share the agent's own compaction is refused: it would
    /// lose detail and save little.
    public static let compactionFloor = 25
}
