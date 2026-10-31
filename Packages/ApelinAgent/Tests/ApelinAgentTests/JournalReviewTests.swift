@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// What a review of the conversation journal found (issue #27): a secret
/// it kept, a call it lost, a status it got wrong, a session it held up.
@Suite("The diagnostic journal, as reviewed")
struct JournalReviewTests {
    let redaction = JournalRedaction(home: "/var/mobile", installRoot: "/var/jb")

    @Test
    func `a secret inside a JSON string argument is taken out`() {
        // file_write of a config file: the content is JSON inside a string
        let summary = redaction.arguments(.object([
            "path": .string("config.json"),
            "content": .string(#"{"apiKey": "q9w8e7r6t5y4u3i2", "password": "hunter2hunter2"}"#),
        ]), tool: "file_write")
        #expect(!summary.contains("q9w8e7r6t5y4u3i2"), "\(summary)")
        #expect(!summary.contains("hunter2hunter2"), "\(summary)")
    }

    @Test
    func `a key the field bound would cut is taken out before the cut`() {
        let key = "AIza" + String(repeating: "B", count: 35)
        let command = "curl " + String(repeating: "x", count: 256 - 5 - 1 - 34) + " " + key + " -o out.json"
        let summary = redaction.arguments(.object(["command": .string(command)]), tool: "shell_run")
        #expect(!summary.contains("AIza" + String(repeating: "B", count: 20)), "\(summary)")
    }

    @Test
    func `a call ID used again is another call, and one never ended is found`() {
        // a provider whose call IDs repeat across turns (index-based)
        let text = """
        [Tool]
        * |info| 2026-10-31_10-00-00| Started call=call_0 tool=shell_run session=S at=10:00:00.000 arguments={}
        * |info| 2026-10-31_10-00-01| Ended call=call_0 tool=shell_run session=S status=succeeded result=ok
        * |info| 2026-10-31_10-05-00| Started call=call_0 tool=shell_run session=S at=10:05:00.000 arguments={}
        """
        let open = SessionJournal.unfinishedCalls(in: text, session: "S")
        #expect(open.map(\.id) == ["call_0"], "the second call, never ended: \(open)")
    }

    @Test
    func `a sign-in that is missing is a failure, not a refusal`() {
        let outcome = ToolCallOutcome.of(
            ApelinError(.denied, "sign in", reason: .authenticationRequired),
            stopped: false,
        )
        #expect(outcome.status == .failed, "\(outcome)")
    }

    @Test
    func `an endpoint on the local network is not named`() async {
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        var model = faux.getModel()
        for address in ["http://192.168.1.5:8080/v1", "http://adas-mac.local:11434", "http://[fd12:3456::1]:8080"] {
            model.baseURL = address
            let described = SessionJournal.describe(model)
            #expect(described.hasSuffix("host=local-endpoint"), "\(described)")
        }
        model.baseURL = "https://api.githubcopilot.com"
        #expect(SessionJournal.describe(model).hasSuffix("host=api.githubcopilot.com"))
    }

    @Test
    func `a rotated file whose journal is gone still counts, and goes with it`() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (index, name) in ["orphan.old.log", "a.log", "b.log"].enumerated() {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)],
                ofItemAtPath: url.path,
            )
        }
        DiagnosticJournal.prune(folder: folder, keeping: 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(left == ["a.log", "b.log"], "\(left)")
    }

    @Test(.timeLimit(.minutes(2)))
    func `a call's end never holds up the session, however long its result`() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = DiagnosticJournal(folder: folder, name: "slow")
        let journal = SessionJournal(sessionID: "slow", file: file, redaction: redaction)
        // what `xxd -p` or `ioreg -l` prints: no rule's match, all of it
        let dump = String(repeating: "0123456789abcdef", count: 16 * 1024)
        let start = Date()
        journal.toolStarted(id: "call-1", name: "shell_run", arguments: .object(["command": .string(dump)]))
        journal.toolEnded(
            id: "call-1",
            name: "shell_run",
            result: AgentToolResult(content: [.text(TextContent(text: dump))]),
            isError: false,
            runStopped: false,
        )
        #expect(Date().timeIntervalSince(start) < 0.1, "the caller waits for neither redaction nor the file")
        let ended = await Self.line(in: file, containing: "Ended call=call-1 ")
        #expect(ended?.contains("[truncated from 262,144 bytes]") == true, "\(ended ?? "no line")")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a stop while a call waits for its approval is no decline`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let file = DiagnosticJournal(folder: home.projectURL, name: "stopped")
        let journal = SessionJournal(sessionID: "stopped", file: file, redaction: redaction)
        let (asked, signal) = AsyncStream<Void>.makeStream()
        let runner = try ToolRunner(
            sessionID: "stopped",
            project: home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            gate: ApprovalGate { event in
                if case .approvalRequested = event {
                    signal.yield()
                }
            },
            journal: journal,
        )
        journal.toolStarted(id: "call-1", name: "shell_run", arguments: .object([:]))
        let call = Task {
            try await runner.run(
                .local(.shellRun),
                toolCallID: "call-1",
                arguments: .object(["argv": .array([.string("make")])]),
                cancellation: nil,
                mcp: nil,
            )
        }
        for await _ in asked {
            break
        }
        call.cancel()
        _ = try? await call.value
        journal.toolEnded(
            id: "call-1",
            name: "shell_run",
            result: AgentToolResult(content: [.text(TextContent(text: "aborted"))]),
            isError: true,
            runStopped: false,
        )
        let ended = await Self.line(in: file, containing: "Ended call=call-1 ")
        #expect(ended?.contains(" status=cancelled ") == true, "\(ended ?? "no line")")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a route with no native compaction says nothing of one`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        faux.setResponses([
            .message(fauxAssistantMessage("First: " + long)),
            .message(fauxAssistantMessage("Second: " + long)),
            .message(fauxAssistantMessage("Third: " + long)),
            .message(fauxAssistantMessage("The user built a tweak; the hook loads.")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        let stream = try await session.events(afterSeq: 0)
        for prompt in ["one", "two", "three"] {
            try await session.prompt(prompt)
            await session.waitForIdle()
        }
        try await session.compact()
        for await record in stream {
            if case .compactionFinished = record.event {
                break
            }
        }
        await session.close()
        let text = try String(
            contentsOf: home.dataRoot.agentJournals.appendingPathComponent(session.id + ".log"),
            encoding: .utf8,
        )
        #expect(!text.contains("Native compaction"), "\(text)")
        #expect(text.contains("| Ended outcome=compacted trigger=requested ") && text.contains(" summary=local "), "\(text)")
    }

    /// The line of `file` that holds `fragment`, once it is written.
    static func line(in file: DiagnosticJournal, containing fragment: String) async -> String? {
        for _ in 0 ..< 200 {
            if let line = file.contents().split(separator: "\n").first(where: { $0.contains(fragment) }) {
                return String(line)
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return nil
    }
}
