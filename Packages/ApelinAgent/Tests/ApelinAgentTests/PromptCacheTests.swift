@testable import ApelinAgent
import ApelinCore
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// A provider caches a conversation as a prefix: the tools, then the system
/// prompt, then the messages. These hold Apelin's half of that: what a
/// session sends stays the same bytes from one request to the next, and
/// grows only at the end.
@Suite("Prompt caching")
struct PromptCacheTests {
    /// What the provider was sent, one entry per request.
    private actor Requests {
        struct Request {
            var systemPrompt: String?
            var tools: [Tool]?
            var messages: [Message]
            var sessionID: String?
        }

        private(set) var all: [Request] = []

        func add(_ context: Context, _ options: StreamOptions?) {
            all.append(Request(
                systemPrompt: context.systemPrompt,
                tools: context.tools,
                messages: context.messages,
                sessionID: options?.sessionId,
            ))
        }
    }

    /// A home with every section of the system prompt filled in: memory,
    /// a user skill, the project's instructions and a registered toolchain.
    private static func furnishedHome() throws -> TemporaryHome {
        let home = try TemporaryHome()
        _ = try EnvironmentContextTests.register(in: home)
        try home.write("AGENTS.md", "Build with apelin_project_build.")
        let skill = home.dataRoot.skills.appendingPathComponent("theme", isDirectory: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: theme-colours\ndescription: Use for theme work.\n---\nUse the palette.\n"
            .write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let store = MemoryStore(root: home.dataRoot.url)
        let snapshot = try store.save(MemoryRecord(title: "Language", body: "Reply in Chinese."), revision: store.read().revision)
        try store.save(MemoryRecord(title: "Target", body: "Hooks SpringBoard only.", projectID: home.project.id), revision: snapshot.revision)
        return home
    }

    private static func isPrefix(_ prefix: [Message], of messages: [Message]) -> Bool {
        prefix.count <= messages.count && Array(messages.prefix(prefix.count)) == prefix
    }

    /// A clock the test moves by hand.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) {
            self.date = date
        }

        var now: Date {
            lock.withLock { date }
        }

        func set(_ date: Date) {
            lock.withLock { self.date = date }
        }
    }

    private static let zone = TimeZone(identifier: "Asia/Shanghai")!

    /// 23:58 on Saturday 2026-10-24 in Shanghai, two minutes before midnight.
    private static let beforeMidnight = Date(timeIntervalSince1970: 1_792_857_480)

    private static func source(_ clock: Clock) -> SystemStateSource {
        SystemStateSource(languages: { ["zh-Hans-CN", "en-US"] }, region: { "CN" }, now: { clock.now }, timeZone: { zone })
    }

    private static func text(_ message: Message) -> String? {
        guard case let .user(user) = message else { return nil }
        return user.content.compactMap { block -> String? in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined()
    }

    /// The `<system-state>` block of a message the model read, tags and all.
    private static func block(_ text: String) -> String? {
        guard let start = text.range(of: SystemState.openingTag),
              let end = text.range(of: SystemState.closingTag, range: start.upperBound ..< text.endIndex) else { return nil }
        return String(text[start.lowerBound ..< end.upperBound])
    }

    /// The changes a message's block reports, one line each.
    private static func changes(_ block: String) -> [String] {
        block.components(separatedBy: "\n").filter { $0.hasPrefix("  - ") }
    }

    private static func saveSkill(_ home: TemporaryHome, _ name: String, _ description: String) throws {
        let folder = home.dataRoot.skills.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "---\nname: \(name)\ndescription: \(description)\n---\nBody.\n"
            .write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test(.timeLimit(.minutes(1)))
    func `the system prompt and tools stay the same while memory, skills, instructions, environment, date and mode change, each said once`() async throws {
        let home = try Self.furnishedHome()
        defer { home.remove() }
        let clock = Clock(Self.beforeMidnight)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        func reply(_ message: AssistantMessage) -> FauxResponseStep {
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return message
            }
        }
        provider.setResponses([
            // The first run: two calls, one of them a notice, then an answer.
            reply(fauxAssistantMessage(blocks: [
                fauxToolCall(name: "file_list", arguments: ["reason": "Look at the project", "path": "."], id: "call-1"),
                fauxToolCall(name: "apelin_notification_send", arguments: ["reason": "Say it is done", "body": "The list is ready."], id: "call-2"),
            ], stopReason: .toolUse)),
            reply(fauxAssistantMessage("Listed.")),
            // The second run, past midnight, in another mode, after
            // everything the prompt shows changed elsewhere.
            reply(fauxAssistantMessage("Again.")),
            // The third, with nothing new.
            reply(fauxAssistantMessage("Still.")),
            // The fourth, from the session opened again as a new process
            // opens it.
            reply(fauxAssistantMessage("Reopened.")),
        ])
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            systemState: Self.source(clock),
        )
        var session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("List the project.", messageID: UUID())
        await session.waitForIdle()

        clock.set(Self.beforeMidnight.addingTimeInterval(5 * 60))
        let store = MemoryStore(root: home.dataRoot.url)
        var revision = try store.save(MemoryRecord(title: "Editor", body: "Prefers tabs."), revision: store.read().revision).revision
        revision = try store.save(MemoryRecord(title: "Other", body: "Not this project's.", projectID: "another-project"), revision: revision).revision
        try Self.saveSkill(home, "release-notes", "Use for writing release notes.")
        try home.write("AGENTS.md", "Build with apelin_project_build, then confirm it loaded.")
        try FileManager.default.removeItem(at: home.dataRoot.url.appendingPathComponent("SDKs/.registry/\(EnvironmentContextTests.olderSDKID).json"))
        // The app sends the mode it has with every message.
        await session.setApprovalMode(.relaxed)
        try await session.prompt("And again.", messageID: UUID())
        await session.waitForIdle()
        clock.set(Self.beforeMidnight.addingTimeInterval(6 * 60))
        try await session.prompt("Third.", messageID: UUID())
        await session.waitForIdle()
        var log = try await session.log.records(afterSeq: 0)
        await session.close()

        clock.set(Self.beforeMidnight.addingTimeInterval(7 * 60))
        session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.setApprovalMode(.relaxed)
        try await session.prompt("Once more.", messageID: UUID())
        await session.waitForIdle()
        log += try await session.log.records(afterSeq: log.last?.seq ?? 0)
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 5)
        // The open session's four requests: one prompt, one tool list.
        for (index, request) in sent.prefix(4).enumerated() {
            #expect(request.systemPrompt == sent[0].systemPrompt, "request \(index) sent another system prompt")
            #expect(request.tools == sent[0].tools, "request \(index) sent other tools")
        }
        for (index, request) in sent.enumerated() {
            #expect(request.sessionID == configuration.id, "request \(index) has no cache key")
            if index > 0 {
                #expect(Self.isPrefix(sent[index - 1].messages, of: request.messages), "request \(index) changed what came before")
            }
        }
        let prompt = try #require(sent[0].systemPrompt)
        for section in ["Reply in Chinese.", "Hooks SpringBoard only.", "theme-colours", "Build with apelin_project_build.", "# Environment", "# Approval modes"] {
            #expect(prompt.contains(section), "the prompt has no \(section)")
        }
        for changing in ["2026-10-2", "Approval mode:", SystemState.closingTag, "Prefers tabs.", "release-notes"] {
            #expect(!prompt.contains(changing), "the prompt has \(changing)")
        }
        // Reopened, the session takes the prompt afresh, with every change
        // in it; the tools are the same.
        let reopened = try #require(sent[4].systemPrompt)
        #expect(reopened != prompt)
        for change in ["Prefers tabs.", "release-notes", "then confirm it loaded.", "# Approval modes"] {
            #expect(reopened.contains(change), "the fresh prompt has no \(change)")
        }
        #expect(!reopened.contains("Not this project's.") && !reopened.contains(EnvironmentContextTests.olderSDKID))
        #expect(sent[4].tools == sent[0].tools)

        // Each message carries its own moment, and each change once.
        let users = try #require(sent.last).messages.compactMap(Self.text)
        #expect(users.count == 4)
        let blocks = users.compactMap(Self.block)
        try #require(blocks.count == 4)
        #expect(blocks[0].contains("- Local time: Saturday 2026-10-24 23:58, Asia/Shanghai (UTC+08:00)."))
        #expect(blocks[0].contains("- Approval mode: Strict."))
        #expect(blocks[1].contains("- Local time: Sunday 2026-10-25 00:03, Asia/Shanghai (UTC+08:00)."))
        #expect(blocks[1].contains("- Approval mode: Relaxed."))
        #expect(blocks[2].contains("- Local time: Sunday 2026-10-25 00:04, Asia/Shanghai (UTC+08:00)."))
        #expect(blocks[3].contains("- Local time: Sunday 2026-10-25 00:05, Asia/Shanghai (UTC+08:00)."))
        for block in blocks {
            #expect(block.contains("; preferred: zh-Hans-CN, en-US; region CN."))
            #expect(block.contains("- Write to the user in the language they write in, progress notes included; when that is unclear, in Chinese"))
        }
        let told = Self.changes(blocks[1])
        #expect(told.contains("  - memory added (all chats): Editor: Prefers tabs."), "\(told)")
        #expect(told.contains("  - skill added: release-notes (user): Use for writing release notes."), "\(told)")
        #expect(told.contains("  - project instructions: AGENTS.md is now:"), "\(told)")
        #expect(told.contains("  - environment:"), "\(told)")
        #expect(blocks[1].contains("Build with apelin_project_build, then confirm it loaded."))
        #expect(blocks[1].contains("    - no longer: \(EnvironmentContextTests.olderSDKID): iOS 17.0"))
        #expect(!blocks[1].contains("Not this project's."), "another project's memory is not this chat's")
        for index in [0, 2, 3] {
            #expect(Self.changes(blocks[index]).isEmpty, "block \(index) told a change again: \(blocks[index])")
        }
        #expect(users[0].hasPrefix(ProjectContext.openingTag), "the project's context still opens the conversation")
        for (user, typed) in zip(users, ["List the project.", "And again.", "Third.", "Once more."]) {
            #expect(user.hasSuffix(SystemState.closingTag + "\n\n" + typed))
        }

        // What the app is told is the text alone, and what it is told about
        // the run never reaches the model: the messages and kwwk's one tool
        // declaration.
        let shown = log.compactMap { record -> String? in
            if case let .userMessage(_, text, _) = record.event {
                return text
            }
            return nil
        }
        #expect(shown == ["List the project.", "And again.", "Third.", "Once more."])
        #expect(log.contains {
            if case .notice = $0.event {
                true
            } else {
                false
            }
        })
        let declarations = try #require(sent.last).messages.filter {
            if case .system = $0 {
                true
            } else {
                false
            }
        }
        #expect(declarations.count == 1, "the reopened session declared its tools again")
    }

    @Test(.timeLimit(.minutes(1)))
    func `the agent's own memory and skill changes are not told again, while one made elsewhere meanwhile is`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        let store = MemoryStore(root: home.dataRoot.url)
        provider.setResponses([
            .factory { _, _, _, _ in
                try fauxAssistantMessage(blocks: [
                    fauxToolCall(name: "apelin_memory_save", arguments: ["reason": "Remember it", "revision": .string(store.read().revision), "title": "Editor", "body": "Prefers tabs.", "scope": "global"], id: "save"),
                    fauxToolCall(name: "apelin_skill_save", arguments: ["reason": "Keep it", "name": "release-notes", "description": "Use for release notes.", "instructions": "Write them."], id: "skill"),
                ], stopReason: .toolUse)
            },
            .factory { _, _, _, _ in
                // the user, in Settings, while the run goes
                try store.save(MemoryRecord(title: "Language", body: "Reply in Chinese."), revision: store.read().revision)
                return fauxAssistantMessage("Saved.")
            },
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return fauxAssistantMessage("Next.")
            },
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Remember that I prefer tabs.")
        await session.waitForIdle()
        try await session.prompt("Go on.")
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        let last = try #require(sent.last?.messages.compactMap(Self.text).last.flatMap(Self.block))
        #expect(Self.changes(last) == ["  - memory added (all chats): Language: Reply in Chinese."], "\(last)")
        #expect(try store.read().records.map(\.title).sorted() == ["Editor", "Language"], "the agent's save went through")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a memory the agent keeps for another project is not this chat's, so one of its title made here meanwhile is still told`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        let store = MemoryStore(root: home.dataRoot.url)
        let weather = try ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-00000000beef", name: ProjectName("Weather"))
        let backend = MockBackend()
        await backend.addProject(weather)
        provider.setResponses([
            .factory { _, _, _, _ in
                // the user, in Settings, for this project
                try store.save(MemoryRecord(title: "Build", body: "Runs make.", projectID: home.project.id), revision: store.read().revision)
                return try fauxAssistantMessage(blocks: [
                    fauxToolCall(name: "apelin_memory_save", arguments: ["reason": "Note it there", "revision": .string(store.read().revision), "title": "Build", "body": "Runs cmake.", "project": "Weather"], id: "save"),
                ], stopReason: .toolUse)
            },
            .message(fauxAssistantMessage("Saved.")),
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return fauxAssistantMessage("Next.")
            },
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            ),
            backend: backend, digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Note Weather's build.")
        await session.waitForIdle()
        try await session.prompt("Go on.")
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        let last = try #require(sent.last?.messages.compactMap(Self.text).last.flatMap(Self.block))
        #expect(Self.changes(last) == ["  - memory added (this project): Build: Runs make."], "\(last)")
        #expect(try store.read().records.map(\.projectID) == [home.project.id, weather.id], "the agent's save went to Weather")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a change a dropped message carried is told again, and a compaction takes the prompt afresh`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        let store = MemoryStore(root: home.dataRoot.url)
        // three replies of about 10k tokens each: more than kwwk keeps as they are
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        provider.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return fauxAssistantMessage("First: " + long)
            },
            .message(fauxAssistantMessage("Second: " + long)),
            .message(fauxAssistantMessage("Third: " + long)),
            .message(fauxAssistantMessage("The user removed a package and keeps its logs.")),
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return fauxAssistantMessage("Carrying on from the summary.")
            },
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        for await record in stream {
            if case .approvalRequested = record.event {
                try store.save(MemoryRecord(title: "Logs", body: "Keep the logs."), revision: store.read().revision)
                try await session.prompt("and keep the logs", messageID: UUID())
                await session.abort()
            }
            if case .finished = record.event {
                break
            }
        }
        await session.waitForIdle()
        try await session.prompt("one")
        await session.waitForIdle()
        for text in ["two", "three"] {
            try await session.prompt(text)
            await session.waitForIdle()
        }
        try store.save(MemoryRecord(title: "Editor", body: "Prefers tabs."), revision: store.read().revision)
        try await session.compact()
        await session.waitForIdle()
        try await session.prompt("four")
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 2)
        // The queued message was dropped with the run: the next one tells it.
        let one = try #require(sent[0].messages.compactMap(Self.text).last.flatMap(Self.block))
        #expect(Self.changes(one) == ["  - memory added (all chats): Logs: Keep the logs."], "\(one)")
        // After the compaction the prompt is taken afresh, with both, and the
        // message after it has nothing to tell.
        #expect(sent[1].systemPrompt?.contains("Prefers tabs.") == true)
        #expect(sent[1].systemPrompt?.contains("Keep the logs.") == true)
        #expect(sent[0].systemPrompt?.contains("Keep the logs.") == false)
        let four = try #require(sent[1].messages.compactMap(Self.text).last.flatMap(Self.block))
        #expect(Self.changes(four).isEmpty, "\(four)")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a queued message, a steer and another conversation's message each carry their block, and the app sees only the text`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let clock = Clock(Self.beforeMidnight)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        func reply(_ message: AssistantMessage) -> FauxResponseStep {
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return message
            }
        }
        // The run takes the queued message and the steer one turn each,
        // then the other conversation's message starts the next.
        provider.setResponses([
            reply(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_package_remove", arguments: ["reason": "Remove it", "installation_id": "inst-1"])], stopReason: .toolUse)),
            reply(fauxAssistantMessage("Removed, and the logs kept.")),
            reply(fauxAssistantMessage("It was inst-1.")),
            reply(fauxAssistantMessage("Reviewed.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()),
                approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
                systemState: Self.source(clock),
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("remove it")
        for await record in stream {
            if case let .approvalRequested(request) = record.event {
                clock.set(Self.beforeMidnight.addingTimeInterval(60))
                try await session.prompt("and keep the logs", messageID: UUID())
                try await session.steer("and say which")
                try await session.approve(requestID: request.id, decision: .approve(.once))
            }
            if case .finished = record.event {
                break
            }
        }
        await session.waitForIdle()
        let sender = ConversationSender(sessionID: "opener-session", title: "Plan the tweak")
        try await session.prompt("Review it", from: sender)
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 4)
        let users = try #require(sent.last).messages.compactMap(Self.text)
        let tail = SystemState.closingTag + "\n\n"
        for typed in ["remove it", "and keep the logs", "and say which", sender.prefix + "\nReview it"] {
            let message = users.first { $0.hasSuffix(tail + typed) }
            #expect(message.flatMap(Self.block) != nil, "no block before \(typed)")
        }
        #expect(users.first { $0.hasSuffix("and keep the logs") }.map { $0.contains("Saturday 2026-10-24 23:59") } == true)
        for index in 1 ..< sent.count {
            #expect(Self.isPrefix(sent[index - 1].messages, of: sent[index].messages), "request \(index) changed what came before")
        }
        for event in events {
            switch event {
            case let .promptSubmitted(text, _), let .userMessage(_, text, _), let .userMessageQueued(_, text, _), let .steered(text):
                #expect(!text.contains(SystemState.openingTag), "the app was shown the block")
            default:
                break
            }
        }
        #expect(events.contains(.steered(text: "and say which")))
        #expect(events.contains(.promptSubmitted(text: "Review it", from: "opener-session")))
    }

    @Test
    func `the system language is read from the preferences, and a block stays small`() throws {
        let source = SystemStateSource.preferences { key -> Any? in
            switch key {
            case "AppleLanguages": ["zh-Hans-CN", "en-US"]
            case "AppleLocale": "zh_CN"
            default: nil
            }
        }
        #expect(source.languages() == ["zh-Hans-CN", "en-US"])
        #expect(source.region() == "CN")
        // Without AppleLocale, the first language's region; without either, none.
        #expect(SystemStateSource.preferences { $0 == "AppleLanguages" ? ["pt-BR"] : nil }.region() == "BR")
        #expect(SystemStateSource.preferences { _ in nil }.region() == nil)
        #expect(SystemState.region(locale: "en_GB@calendar=gregorian") == "GB")
        #expect(SystemState.region(language: "es-419") == "419")

        let facts = try SystemState.Facts(languages: ["<script>", "en_US", "fr-FR"], region: "us", date: Self.beforeMidnight, timeZone: #require(TimeZone(identifier: "UTC")), mode: .full)
        let block = SystemState.make(facts)
        #expect(!block.contains("<script>"), "the preferences are a file the user can write")
        #expect(block.contains("; preferred: en-US, fr-FR; region US."))
        #expect(block.contains("- Local time: Saturday 2026-10-24 15:58, GMT (UTC+00:00)."))
        #expect(block.contains("- Approval mode: Full."))
        #expect(block.hasSuffix(SystemState.closingTag + "\n\n"))
        // A few dozen tokens, at about four bytes a token, the screen
        // setting's line (2026-10-30) included.
        #expect(block.utf8.count < 440, "\(block.utf8.count) bytes")
        let none = SystemState.make(SystemState.Facts(languages: [], region: nil, date: Self.beforeMidnight, timeZone: Self.zone, mode: .confirm))
        #expect(none.contains("- System language: not known."))
        #expect(none.contains("- Write to the user in the language they write in, progress notes included.\n"))
    }

    @Test
    func `a memory another project keeps leaves the prompt as it was, and one this chat sees changes only the memory`() throws {
        let home = try Self.furnishedHome()
        defer { home.remove() }
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .githubCopilot(model: "m"),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        )
        let root = try ScopedRoot(home.projectURL)
        let skills = SkillCatalog.load(userDirectory: home.dataRoot.skills).skills
        func prompt() -> String {
            AgentSession.systemPrompt(configuration, root: root, skills: skills, device: .current)
        }
        let before = prompt()
        #expect(prompt() == before, "the same files give the same prompt")

        let store = MemoryStore(root: home.dataRoot.url)
        var snapshot = try store.save(
            MemoryRecord(title: "Other", body: "Another project's fact.", projectID: "another-project"),
            revision: store.read().revision,
        )
        #expect(prompt() == before, "another project's memory changed this chat's prompt")
        #expect(!before.contains(snapshot.revision))

        snapshot = try store.save(MemoryRecord(title: "Editor", body: "Prefers tabs."), revision: snapshot.revision)
        let after = prompt()
        #expect(after != before)
        #expect(after.contains("Prefers tabs."))
        let memory = try #require(before.range(of: "# Long-term memory"))
        #expect(after.hasPrefix(before[..<memory.lowerBound]), "a memory changed more than the memory section")
    }

    @Test(.timeLimit(.minutes(1)))
    func `the user's instructions changed in Settings reach an open session once, as a delta, and the prompt stays the same`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        provider.setResponses((0 ..< 4).map { index -> FauxResponseStep in
            .factory { context, options, _, _ in
                await requests.add(context, options)
                return fauxAssistantMessage("Reply \(index).")
            }
        })
        let store = CustomInstructionsStore(root: home.dataRoot.url)
        try store.save("Check my premises first.", for: .allChats, replacing: "")
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(provider.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        )
        var session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("One.")
        await session.waitForIdle()
        try store.save("Say when the evidence is thin.", for: .allChats, replacing: "Check my premises first.")
        try store.save("Package each patch on its own.", for: .project(home.project.id), replacing: "")
        try await session.prompt("Two.")
        await session.waitForIdle()
        try await session.prompt("Three.")
        await session.waitForIdle()
        await session.close()
        session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("Four.")
        await session.waitForIdle()
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 4)
        let prompt = try #require(sent[0].systemPrompt)
        #expect(prompt.contains("## For all conversations\nCheck my premises first."))
        for index in 1 ..< 3 {
            #expect(sent[index].systemPrompt == prompt, "request \(index) sent another system prompt")
            #expect(sent[index].tools == sent[0].tools)
            #expect(Self.isPrefix(sent[index - 1].messages, of: sent[index].messages), "request \(index) changed what came before")
        }
        let blocks = try #require(sent[2].messages.compactMap(Self.text)).compactMap(Self.block)
        try #require(blocks.count == 3)
        #expect(Self.changes(blocks[0]).isEmpty)
        #expect(Self.changes(blocks[1]) == [
            "  - the user's instructions for all conversations are now:",
            "  - the user's instructions for this project are now:",
        ], "\(blocks[1])")
        #expect(blocks[1].contains("are now:\n    Say when the evidence is thin."))
        #expect(blocks[1].contains("are now:\n    Package each patch on its own."))
        #expect(Self.changes(blocks[2]).isEmpty, "told once")
        // Reopened, the session takes the prompt afresh, with both.
        let reopened = try #require(sent[3].systemPrompt)
        #expect(reopened.contains("## For all conversations\nSay when the evidence is thin."))
        #expect(reopened.contains("## For this project\nPackage each patch on its own."))
        #expect(!reopened.contains("Check my premises first."))
    }

    @Test
    func `a wait on another conversation ends before the provider's cache of this one does`() {
        // Five minutes from the start of the request that asked; the model
        // takes some of them writing the call.
        #expect(ConversationReadToolRequest.maximumWaitSeconds <= 180)
    }
}
