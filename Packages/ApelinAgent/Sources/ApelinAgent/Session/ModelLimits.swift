import enum ApelinProtocol.AgentContextBudget
import struct ApelinProtocol.AgentModelLimits
import enum ApelinProtocol.AgentToolName
import KWWKAgent
import KWWKAI

public extension AgentModelLimits {
    /// `model` with the window and the largest reply the user set (#68).
    ///
    /// Everything kwwk does with them reads the model: the request budget
    /// and its output headroom (`AgentRequestBudget`), automatic compaction
    /// and its recovery target, and every wire's encoder, which sends
    /// `maxTokens` as its own field (`OutputTokenPolicy`: Chat Completions'
    /// `max_tokens` or `max_completion_tokens`, Responses'
    /// `max_output_tokens`, Anthropic's and Gemini's), never above the
    /// window, and on the OpenAI wires never above kwwk's 64,000. kwwk leaves
    /// an automatic limit off OpenRouter's wire; one the user set is sent,
    /// so it is also what the budget reserves. A window set with the output
    /// left automatic caps the automatic reply at a quarter of it
    /// (`automaticOutput`).
    func applied(to model: Model) -> Model {
        var model = model
        if let window = contextWindow {
            model.contextWindow = window
            if maxOutputTokens == nil, model.maxTokens > 0,
               let capped = Self.automaticOutput(model.maxTokens, window: window)
            {
                model.maxTokens = capped
            }
        }
        if let output = maxOutputTokens {
            model.maxTokens = output
            var compat = model.compat ?? ModelCompat()
            compat.omitsAutomaticOutputLimit = false
            model.compat = compat
        }
        return model
    }

    /// The limits `model` has when the user sets none: its window, and the
    /// largest reply kwwk sends on its own, none where it sends none.
    static func automatic(of model: Model) -> AgentModelLimits {
        AgentModelLimits(
            contextWindow: model.contextWindow > 0 ? model.contextWindow : nil,
            maxOutputTokens: OutputTokenPolicy.automaticLimit(for: model),
        )
    }
}

/// The note that ends a tool's result once the context passes a share of
/// the window (`AgentContextBudget.suggestions`): the model reads it with
/// the result and may call `apelin_conversation_compact` at a good stopping
/// point, before automatic compaction does it at 75 %.
///
/// Each share is told once, and forgotten when the context falls below it
/// again, as it does after a compaction or when the window grows: past
/// it once more, it is told again. A context past the automatic share is
/// told nothing, since the next request compacts it anyway.
struct ContextNote {
    /// The highest share told and not fallen below since.
    private(set) var told = 0

    static let tag = "context-usage"

    /// The note for a context `percent` full, when one is due.
    mutating func note(percent: Int) -> String? {
        told = AgentContextBudget.suggestions.last { $0 <= percent && $0 <= told } ?? 0
        guard percent < Self.automaticPercent,
              let due = AgentContextBudget.suggestions.last(where: { $0 <= percent }), due > told
        else { return nil }
        told = due
        return Self.text(percent: percent)
    }

    static let automaticPercent = Int((AgentContextBudget.automaticCompaction * 100).rounded())

    /// The note as it ends a result: a text block of its own, set apart
    /// from the output before it by a blank line, since some wires join a
    /// result's blocks.
    static func text(percent: Int) -> String {
        let tool = AgentToolName.conversationCompact.rawValue
        let body = """
        The context is \(percent)% full. At a good stopping point, consider calling \(tool) to save space; \
        at \(automaticPercent)% Apelin compacts it automatically.
        """
        return "\n\n<\(tag)>\(body)</\(tag)>"
    }

    /// `content` without the `note` that ends it.
    static func removing(_ note: String, from content: [ToolResultBlock]) -> [ToolResultBlock] {
        guard case let .text(last)? = content.last, last.text == note else { return content }
        return Array(content.dropLast())
    }

    /// A share of the window, rounded down, as the notes and refusals say it.
    static func percent(_ usage: AgentContextUsage) -> Int {
        guard usage.window > 0 else { return 0 }
        return Int((Double(usage.tokens) * 100 / Double(usage.window)).rounded(.down))
    }
}
