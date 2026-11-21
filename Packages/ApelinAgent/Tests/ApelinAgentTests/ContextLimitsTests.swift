@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A model's context window and largest reply as the user sets them (#68),
/// the automatic compaction they are measured against, and the agent's own
/// compaction with the notes that suggest it.
@Suite("Context limits and compaction")
struct ContextLimitsTests {
    // MARK: - The limits on the model

    @Test
    func `the window and the largest reply go on the model, which every wire and the budget read`() {
        let relay = Model(
            id: "relay-model",
            api: "openai-completions",
            provider: "openai-compatible",
            baseURL: "https://relay.example/v1",
            contextWindow: 131_072,
            maxTokens: 32000,
        )
        let limited = AgentModelLimits(contextWindow: 20000, maxOutputTokens: 4096).applied(to: relay)
        #expect(limited.contextWindow == 20000)
        #expect(limited.maxTokens == 4096)
        // what Chat Completions sends when the request names no limit of its own
        #expect(OutputTokenPolicy.automaticLimit(for: limited) == 4096)
        // an output left out is the model's, at most a quarter of a window set
        let windowOnly = AgentModelLimits(contextWindow: 64000).applied(to: relay)
        #expect(windowOnly.contextWindow == 64000 && windowOnly.maxTokens == 16000)
        #expect(windowOnly.compat?.omitsAutomaticOutputLimit == nil)
        let largeWindow = AgentModelLimits(contextWindow: 1_000_000).applied(to: relay)
        #expect(largeWindow.maxTokens == 32000, "a window with room for it keeps the model's reply")
        #expect(AgentModelLimits().applied(to: relay) == relay)
    }

    /// The device's case: deepseek-v4-pro on an OpenAI-compatible key, whose
    /// automatic reply is kwwk's 64,000, under a 65,000 window the user set.
    /// Uncapped, the request asked for 64,000 tokens of reply beside a
    /// conversation of 26,000 or more, which a relay holding to its window
    /// refuses; capped, three quarters of the window stay for the input.
    @Test
    func `a window set with the output automatic asks for at most a quarter of it`() {
        let deepSeek = Model(
            id: "deepseek-v4-pro",
            api: "openai-completions",
            provider: "openai-compatible",
            baseURL: "https://api.deepseek.com",
            contextWindow: 1_000_000,
            maxTokens: 384_000,
        )
        #expect(OutputTokenPolicy.automaticLimit(for: deepSeek) == OutputTokenPolicy.openAIMaximumOutputTokens)
        let small = AgentModelLimits(contextWindow: 65000).applied(to: deepSeek)
        #expect(OutputTokenPolicy.automaticLimit(for: small) == 16250)
        // an output the user set stays theirs
        let both = AgentModelLimits(contextWindow: 65000, maxOutputTokens: 30000).applied(to: deepSeek)
        #expect(OutputTokenPolicy.automaticLimit(for: both) == 30000)
    }

    @Test
    func `a largest reply the user set reaches OpenRouter's wire, which leaves kwwk's own off`() {
        let openRouter = Model(
            id: "some/model",
            api: "openai-completions",
            provider: "openrouter",
            baseURL: "https://openrouter.ai/api/v1",
            contextWindow: 131_072,
            maxTokens: 32000,
        )
        #expect(OutputTokenPolicy.automaticLimit(for: openRouter) == nil)
        let limited = AgentModelLimits(maxOutputTokens: 8000).applied(to: openRouter)
        #expect(OutputTokenPolicy.automaticLimit(for: limited) == 8000)
    }

    @Test
    func `the automatic limits are the model's window and the reply kwwk sends on its own`() {
        let model = Model(id: "m", api: "anthropic-messages", provider: "anthropic", contextWindow: 200_000, maxTokens: 128_000)
        #expect(AgentModelLimits.automatic(of: model) == AgentModelLimits(contextWindow: 200_000, maxOutputTokens: 128_000))
        // OpenAI's wires never send more than kwwk's ceiling
        let openAI = Model(id: "m", api: "openai-completions", provider: "openai", contextWindow: 400_000, maxTokens: 128_000)
        #expect(AgentModelLimits.automatic(of: openAI).maxOutputTokens == OutputTokenPolicy.openAIMaximumOutputTokens)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a session opens with the limits, measures against them and takes new ones with a message`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let seen = SeenModels()
        let answer = FauxResponseStep.factory { _, _, _, model in
            await seen.add(model)
            return fauxAssistantMessage("Done.")
        }
        faux.setResponses([answer, answer, answer])
        let provider = ProviderConfiguration.registered(faux.getModel())
        let credentials = DeliveredCredentialSource()
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: provider,
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                modelLimits: AgentModelLimits(contextWindow: 50000, maxOutputTokens: 2048),
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: credentials,
        )
        // compaction is said in Apelin, at three quarters, against the user's window
        #expect(await session.automaticCompactionThreshold == 0.75)
        #expect(AgentContextBudget.automaticCompaction == 0.75)
        #expect(await session.requestUsage.window == 50000)

        try await session.prompt("One", messageID: UUID())
        await session.waitForIdle()
        // another message, other limits; then none, which is the model's own
        try await session.configure(
            provider: provider,
            thinking: .off,
            modelLimits: AgentModelLimits(contextWindow: 90000),
            credentials: credentials,
        )
        try await session.prompt("Two", messageID: UUID())
        await session.waitForIdle()
        try await session.configure(provider: provider, thinking: .off, credentials: credentials)
        try await session.prompt("Three", messageID: UUID())
        await session.waitForIdle()
        let models = await seen.all
        #expect(models.map(\.contextWindow) == [50000, 90000, 128_000])
        #expect(models.map(\.maxTokens) == [2048, 16384, 16384])
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `limits a caller could not have set are left automatic`() {
        #expect(AgentModelLimits(contextWindow: 10).sanitized == nil)
        #expect(AgentModelLimits(contextWindow: 20000, maxOutputTokens: 30000).sanitized == AgentModelLimits(contextWindow: 20000))
        #expect(AgentModelLimits(maxOutputTokens: 0).sanitized == nil)
    }

    // MARK: - The notes

    @Test
    func `a note is due when the context passes half, sixty and seventy percent, each once`() {
        var note = ContextNote()
        #expect(note.note(percent: 30) == nil)
        #expect(note.note(percent: 49) == nil)
        #expect(note.note(percent: 51) == ContextNote.text(percent: 51))
        #expect(note.note(percent: 55) == nil)
        #expect(note.note(percent: 60) == ContextNote.text(percent: 60))
        #expect(note.note(percent: 69) == nil)
        #expect(note.note(percent: 72) == ContextNote.text(percent: 72))
        #expect(note.note(percent: 74) == nil)
        // past the automatic share the next request compacts it anyway
        #expect(note.note(percent: 80) == nil)
    }

    @Test
    func `a share fallen below is told again once passed again, as after a compaction`() {
        var note = ContextNote()
        #expect(note.note(percent: 65) != nil)
        // compacted down: everything is forgotten
        #expect(note.note(percent: 20) == nil)
        #expect(note.told == 0)
        #expect(note.note(percent: 52) != nil)
        // a context that leaps past several shares hears one note
        var leap = ContextNote()
        #expect(leap.note(percent: 40) == nil)
        #expect(leap.note(percent: 73) == ContextNote.text(percent: 73))
        #expect(leap.note(percent: 74) == nil)
        // falling a little keeps the lower share told
        #expect(leap.note(percent: 61) == nil)
        #expect(leap.told == 60)
        #expect(leap.note(percent: 70) == ContextNote.text(percent: 70))
    }

    @Test
    func `the note names the tool and the automatic share, and comes off the shown result`() {
        let text = ContextNote.text(percent: 52)
        #expect(text.contains("<context-usage>The context is 52% full."))
        #expect(text.contains("apelin_conversation_compact"))
        #expect(text.contains("at 75% Apelin compacts it automatically"))
        let output: [ToolResultBlock] = [.text(TextContent(text: "listed 3 files"))]
        #expect(ContextNote.removing(text, from: output + [.text(TextContent(text: text))]) == output)
        #expect(ContextNote.removing(text, from: output) == output)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a tool's result past half the window ends with the note the model reads and the app does not show`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("README.md", "hello")
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        faux.setResponses([
            .message(fauxAssistantMessage("First: " + long)),
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "file_list", arguments: ["reason": "Look at the project"])],
                stopReason: .toolUse,
            )),
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "file_list", arguments: ["reason": "Look again"])],
                stopReason: .toolUse,
            )),
            .message(fauxAssistantMessage("Listed.")),
        ])
        let provider = ProviderConfiguration.registered(faux.getModel())
        let credentials = DeliveredCredentialSource()
        let session = try await openSession(home, provider: provider)
        try await session.prompt("one")
        await session.waitForIdle()
        // a window that puts the conversation a little past half
        let used = await session.requestUsage.tokens
        try await session.configure(
            provider: provider,
            thinking: .off,
            modelLimits: AgentModelLimits(contextWindow: used * 100 / 54),
            credentials: credentials,
        )
        try await session.prompt("list the files")
        await session.waitForIdle()

        let transcript = try await session.log.readTranscript()
        let results = transcript.compactMap { message -> ToolResultMessage? in
            guard case let .toolResult(result) = message else { return nil }
            return result
        }
        #expect(results.count == 2)
        // the first call's result ends with the note, the second's does not
        let notes = results.map { result in
            result.content.contains { block in
                if case let .text(text) = block {
                    return text.text.contains("<context-usage>The context is 5")
                }
                return false
            }
        }
        #expect(notes == [true, false], "\(results)")
        // and no event the app shows carries it
        let shown = try await session.log.records(afterSeq: 0).compactMap { record -> String? in
            guard case let .toolCallFinished(result) = record.event else { return nil }
            return result.output
        }
        #expect(shown.count == 2 && shown.allSatisfy { !$0.contains("context-usage") }, "\(shown)")
        await session.close()
    }

    // MARK: - The agent's own compaction

    @Test(.timeLimit(.minutes(1)))
    func `the agent's compaction runs at the next step, with the events the app shows`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        faux.setResponses([
            .message(fauxAssistantMessage("First: " + long)),
            .message(fauxAssistantMessage("Second: " + long)),
            .message(fauxAssistantMessage("Third: " + long)),
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "apelin_conversation_compact", arguments: ["reason": "Save space"])],
                stopReason: .toolUse,
            )),
            // the summary kwwk asks for
            .message(fauxAssistantMessage("The user built a tweak; the hook loads.")),
            .message(fauxAssistantMessage("Carrying on from the summary.")),
        ])
        let provider = ProviderConfiguration.registered(faux.getModel())
        let session = try await openSession(home, provider: provider)
        for prompt in ["one", "two", "three"] {
            try await session.prompt(prompt)
            await session.waitForIdle()
        }
        // half full: compacting is allowed, and nothing compacts on its own
        let used = await session.requestUsage.tokens
        try await session.configure(
            provider: provider,
            thinking: .off,
            modelLimits: AgentModelLimits(contextWindow: used * 2),
            credentials: DeliveredCredentialSource(),
        )
        let before = try await session.log.readTranscript().count
        try await session.prompt("four")
        await session.waitForIdle()

        let events = try await session.log.records(afterSeq: 0).map(\.event)
        let answer = events.compactMap { event -> String? in
            guard case let .toolCallFinished(result) = event, result.name == "apelin_conversation_compact" else { return nil }
            return result.output
        }
        #expect(answer.count == 1 && answer[0].hasPrefix("Apelin compacts this conversation before your next step"), "\(answer)")
        let started = events.firstIndex { event in
            if case .compactionStarted = event {
                return true
            }
            return false
        }
        let finished = events.compactMap { event -> AgentCompactionResult? in
            guard case let .compactionFinished(result) = event else { return nil }
            return result
        }
        #expect(started != nil)
        #expect(finished.count == 1)
        #expect(finished.first?.outcome == .compacted, "\(finished)")
        #expect(finished.first?.summary == "The user built a tweak; the hook loads.")
        // the run went on from the summary, which a reopened session reads back
        let transcript = try await session.log.readTranscript()
        #expect(transcript.count < before + 4)
        guard case let .assistant(reply)? = transcript.last else {
            Issue.record("no reply after compacting: \(String(describing: transcript.last))")
            return
        }
        #expect(reply.content == [fauxText("Carrying on from the summary.")])
        await session.close()
        let journal = try String(
            contentsOf: home.dataRoot.url.appendingPathComponent("Journal/Agent/\(session.id).log"),
            encoding: .utf8,
        )
        #expect(journal.contains("| Started trigger=tool ") && journal.contains("| Ended outcome=compacted trigger=tool "), "\(journal)")
    }

    @Test(.timeLimit(.minutes(1)))
    func `the agent's compaction is refused for a short conversation or a context still mostly free`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let compact = FauxResponseStep.message(fauxAssistantMessage(
            blocks: [fauxToolCall(name: "apelin_conversation_compact", arguments: ["reason": "Save space"])],
            stopReason: .toolUse,
        ))
        faux.setResponses([
            compact, .message(fauxAssistantMessage("Fine.")),
            .message(fauxAssistantMessage("Hello.")),
            compact, .message(fauxAssistantMessage("Fine again.")),
        ])
        // a window so large the conversation stays far under a quarter of it
        let session = try await openSession(
            home,
            provider: .registered(faux.getModel()),
            limits: AgentModelLimits(contextWindow: 5_000_000),
        )
        try await session.prompt("compact now")
        await session.waitForIdle()
        try await session.prompt("hi")
        await session.waitForIdle()
        try await session.prompt("compact now")
        await session.waitForIdle()

        let events = try await session.log.records(afterSeq: 0).map(\.event)
        let answers = events.compactMap { event -> (String, Bool)? in
            guard case let .toolCallFinished(result) = event, result.name == "apelin_conversation_compact" else { return nil }
            return (result.output, result.isError)
        }
        #expect(answers.count == 2)
        #expect(answers.first?.0.contains("too short to summarize") == true, "\(answers)")
        #expect(answers.last?.0.contains("% full") == true && answers.last?.0.contains("Not compacted") == true, "\(answers)")
        // the macro cannot take a closure here, so the answers are read first
        let refused = answers.allSatisfy(\.1)
        let compacted = events.contains { event in
            if case .compactionStarted = event {
                return true
            }
            return false
        }
        #expect(refused)
        #expect(!compacted)
        await session.close()
    }

    private func openSession(
        _ home: TemporaryHome,
        provider: ProviderConfiguration,
        limits: AgentModelLimits? = nil,
    ) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: provider,
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
                modelLimits: limits,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }
}

private actor SeenModels {
    private(set) var all: [Model] = []

    func add(_ model: Model) {
        all.append(model)
    }
}
