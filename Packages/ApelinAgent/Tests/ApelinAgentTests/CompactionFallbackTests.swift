@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("A native compaction that brings no summary back")
struct CompactionFallbackTests {
    /// What kwwk's Anthropic provider throws for a 200 whose `compaction`
    /// block has no content (`AnthropicProvider.compact`).
    private static let noSummary = ProviderFailure(message: "Anthropic compaction returned no summary")

    @Test
    func `a reply without a summary is told apart from a request that failed`() {
        #expect(NativeCompactionFallback.returnedNoSummary(Self.noSummary))
        #expect(NativeCompactionFallback.returnedNoSummary(ProviderFailure(
            message: "Invalid Anthropic compaction completion: expected compaction stop reason",
            rawStopReason: "end_turn",
        )))
        #expect(!NativeCompactionFallback.returnedNoSummary(ProviderFailure(message: "invalid x-api-key", httpStatus: 401)))
        #expect(!NativeCompactionFallback.returnedNoSummary(ProviderFailure(message: "Overloaded", httpStatus: 529)))
        #expect(!NativeCompactionFallback.returnedNoSummary(ProviderFailure(
            message: "The Internet connection appears to be offline.",
            transportDomain: NSURLErrorDomain,
            transportCode: NSURLErrorNotConnectedToInternet,
        )))
        #expect(!NativeCompactionFallback.returnedNoSummary(ProviderFailure(
            message: "Invalid Anthropic compaction completion: expected compaction stop reason",
            rawStopReason: "refusal",
        )))
        #expect(!NativeCompactionFallback.returnedNoSummary(CancellationError()))
    }

    /// kwwk's own summary takes over a native compaction that brought none
    /// back. Before 0.1.127 kwwk alone failed the compaction there, and this
    /// wrapper was what went on; from 0.1.127 kwwk falls back by itself on
    /// any native failure but a refused sign-in or a cancellation, and the
    /// wrapper's answer of none leads to the same summary.
    @Test(.timeLimit(.minutes(1)))
    func `kwwk's own summary takes over, with the wrapper or without it`() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let model = faux.getModel()
        let empty: NativeCompactionFn = { _, _, _, _ in throw Self.noSummary }

        let routes: [(String, NativeCompactionFn)] = [("kwwk alone", empty), ("the wrapper", NativeCompactionFallback.compact(empty))]
        for (label, native) in routes {
            faux.setResponses([.message(fauxAssistantMessage("The user built a tweak; the hook loads."))])
            let compacted = await Self.compact(model: model, native: native)
            guard case let .success(replacement) = compacted else {
                Issue.record("\(label): the compaction failed: \(compacted)")
                continue
            }
            #expect(replacement.messagesCompacted > 0, "\(label)")
            #expect(CompactionRecap.summary(of: replacement.messages) == "The user built a tweak; the hook loads.", "\(label)")
        }

        let refused: NativeCompactionFn = { _, _, _, _ in
            throw ProviderFailure(message: "invalid x-api-key", httpStatus: 401)
        }
        let stillRefused = await Self.compact(model: model, native: NativeCompactionFallback.compact(refused))
        guard case let .failure(.failed(refusal)) = stillRefused else {
            Issue.record("a refused request was summarised anyway: \(stillRefused)")
            return
        }
        #expect(refusal.contains("invalid x-api-key"))
    }

    @Test
    func `the reader gets the recap's summaries without its markup or its file ledger`() {
        let recap = """
        <previous-session-summary>
        <kwwk-compaction version="2">
        <history>
        Hooked &lt;SpringBoard&gt; &amp; logged &quot;loaded&quot;; it&apos;s &amp;lt;fine&amp;gt;.
        </history>
        <current-turn-prefix>
        Building the release.
        </current-turn-prefix>
        <file-operations>
        <read path="Sources/Tweak.m" />
        </file-operations>
        </kwwk-compaction>
        </previous-session-summary>
        """
        let messages: [Message] = [
            .user(UserMessage(text: recap, source: .compaction)),
            .user(UserMessage(text: "Carry on")),
        ]
        #expect(CompactionRecap.summary(of: messages) == """
        Hooked <SpringBoard> & logged "loaded"; it's &lt;fine&gt;.

        Building the release.
        """)
        // a recap in a shape this does not know is given whole
        #expect(CompactionRecap.summary(of: [.user(UserMessage(text: " Plain recap ", source: .compaction))]) == "Plain recap")
        // and a conversation that does not start with one has none
        #expect(CompactionRecap.summary(of: [.user(UserMessage(text: recap))]) == nil)
        #expect(CompactionRecap.summary(of: []) == nil)
    }

    /// Three exchanges of about 10k tokens each, more than the 20k kwwk
    /// keeps as they are, compacted with `native` in front.
    private static func compact(
        model: Model,
        native: @escaping NativeCompactionFn,
    ) async -> Result<AgentContextCompactionResult, AgentContextCompactionFailure> {
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        let messages: [Message] = ["one", "two", "three"].flatMap { prompt -> [Message] in
            [.user(UserMessage(text: prompt)), .assistant(fauxAssistantMessage(prompt + ": " + long))]
        }
        return await AgentContextCompactor.compactMessages(
            messages: messages,
            model: model,
            sessionId: "fallback",
            config: AgentContextCompactionConfig(nativeCompaction: native),
        )
    }
}
