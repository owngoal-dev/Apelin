@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("The diagnostic journal")
struct SessionJournalTests {
    // MARK: - The file

    @Test
    func `entries are Dog's lines, one a message, with the category when it changes`() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = DiagnosticJournal(folder: folder, name: "session")
        #expect(journal.write("Tool", "Started call=a\n[Fake] category\n* |error| fake| entry", level: .info))
        #expect(journal.write("Tool", "Ended call=a", level: .warning))
        #expect(journal.write("Compaction", "Failed", level: .error))
        let lines = try String(contentsOf: journal.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 5, "\(lines)")
        #expect(lines[0] == "[Tool]")
        #expect(lines[1].hasPrefix("* |info| ") && lines[1].hasSuffix(#"| Started call=a\n[Fake] category\n* |error| fake| entry"#))
        #expect(lines[2].hasPrefix("* |warning| "))
        #expect(lines[3] == "[Compaction]")
        #expect(lines[4].hasPrefix("* |error| "))
        // Dog's timestamp: the time to the second
        let timestamp = lines[2].dropFirst("* |warning| ".count).prefix(19)
        #expect(timestamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}/) != nil, "\(timestamp)")

        // reopened, the category is written again: what the file ended with is not known
        let again = DiagnosticJournal(folder: folder, name: "session")
        again.write("Compaction", "Started")
        #expect(try String(contentsOf: journal.url, encoding: .utf8).hasSuffix("[Compaction]\n" + Self.lastLine(of: again)))
    }

    @Test
    func `a full file is rotated into one predecessor, and the journals written last are kept`() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = DiagnosticJournal(folder: folder, name: "session", rotationBytes: 400)
        for index in 0 ..< 40 {
            journal.write("Tool", "line \(index)")
        }
        let current = try String(contentsOf: journal.url, encoding: .utf8)
        let previous = try String(contentsOf: journal.previousURL, encoding: .utf8)
        #expect(current.utf8.count <= 400 && previous.utf8.count <= 400)
        #expect(current.hasPrefix("[Tool]\n"), "a new file names its category")
        #expect(current.hasSuffix("| line 39\n"))
        #expect(journal.contents() == previous + current)
        #expect(!journal.contents().contains("| line 0\n"), "only one predecessor is kept")

        // deleted from Settings while it is written: a new file takes its place
        try FileManager.default.removeItem(at: journal.url)
        #expect(journal.write("Tool", "after"))
        #expect(try String(contentsOf: journal.url, encoding: .utf8).hasPrefix("[Tool]\n"))

        for (index, name) in ["a", "b", "c", "d"].enumerated() {
            let other = DiagnosticJournal(folder: folder, name: name)
            other.write("Session", "Opened")
            other.write("Session", String(repeating: "x", count: 10))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(index - 10) * 60)],
                ofItemAtPath: other.url.path,
            )
        }
        try Data("old".utf8).write(to: folder.appendingPathComponent("a.old.log"))
        DiagnosticJournal.prune(folder: folder, keeping: 2, sparing: "b")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        // `session` and `d` were written last; `b` is the one being written
        #expect(left == ["b.log", "d.log", "session.log", "session.old.log"], "\(left)")
    }

    @Test
    func `a link or a file of more than one link where the journal goes is not written through`() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target.txt")
        try Data("kept".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("linked.log"), withDestinationURL: target)
        #expect(!DiagnosticJournal(folder: folder, name: "linked").write("Tool", "line"))
        try FileManager.default.linkItem(at: target, to: folder.appendingPathComponent("hard.log"))
        #expect(!DiagnosticJournal(folder: folder, name: "hard").write("Tool", "line"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "kept")
    }

    // MARK: - Redaction

    @Test
    func `nothing reaches the file before it is redacted`() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = DiagnosticJournal(folder: folder, name: "redacted")
        let journal = SessionJournal(
            sessionID: "redacted",
            file: file,
            redaction: JournalRedaction(home: "/var/mobile", installRoot: "/var/jb"),
        )
        let key = "ghp_" + String(repeating: "a1", count: 18)
        journal.toolStarted(id: "call-1", name: "shell_run", arguments: .object([
            "command": .string("curl -H 'Authorization: Bearer \(key)' https://api.github.com"),
            "cwd": .string("/var/mobile/Documents/wiki.qaq.apelin/Projects/Hello"),
        ]))
        journal.toolEnded(
            id: "call-1",
            name: "shell_run",
            result: AgentToolResult(content: [.text(TextContent(text: "token=\(key)\nmail me at someone@example.com"))]),
            isError: false,
            runStopped: false,
        )
        journal.runFailed("401 from https://user:hunter22@example.com with \(key)")
        let text = file.contents()
        for secret in [key, "hunter22", "someone@example.com", "/var/mobile"] {
            #expect(!text.contains(secret), "\(secret) survived:\n\(text)")
        }
        #expect(text.contains("~/Documents/wiki.qaq.apelin/Projects/Hello"), "\(text)")
        #expect(text.contains(#"result=token=<redacted>\nmail me at <email>"#), "\(text)")
    }

    @Test
    func `arguments keep their shape, each string bounded and a secret field masked`() {
        let redaction = JournalRedaction(home: "/var/mobile", installRoot: "/var/jb")
        let arguments: KWWKAI.JSONValue = .object([
            "path": .string("/var/mobile/Documents/wiki.qaq.apelin/Projects/Hello/Sources/Tweak.m"),
            "content": .string(String(repeating: "x", count: 5000)),
            "headers": .object(["Authorization": .string("Bearer something"), "Accept": .string("text/html")]),
            "max_tokens": .int(4000),
        ])
        let summary = redaction.arguments(arguments, tool: AgentToolName.fileWrite.rawValue)
        #expect(summary.utf8.count < 1024)
        #expect(summary.contains(#""path":"~/Documents/wiki.qaq.apelin/Projects/Hello/Sources/Tweak.m""#), "\(summary)")
        #expect(summary.contains("[truncated from 5,000 bytes]"))
        #expect(summary.contains(#""Authorization":"<redacted>""#) && summary.contains(#""Accept":"text/html""#))
        #expect(summary.contains(#""max_tokens":4000"#))

        let credential = redaction.arguments(
            .object(["host": .string("git.example.com"), "username": .string("me"), "token": .string("plain")]),
            tool: AgentToolName.gitSaveCredential.rawValue,
        )
        #expect(!credential.contains("plain") && credential.contains("git.example.com"), "\(credential)")

        let huge = KWWKAI.JSONValue.array(Array(repeating: .string(String(repeating: "y", count: 200)), count: 50))
        #expect(redaction.arguments(huge, tool: "shell_run").hasSuffix("bytes]"))
    }

    // MARK: - Outcomes

    @Test
    func `what a call's error comes to`() {
        #expect(ToolCallOutcome.of(CancellationError(), stopped: false).status == .cancelled)
        #expect(ToolCallOutcome.of(ToolArgumentError("bad"), stopped: true).status == .cancelled)
        #expect(ToolCallOutcome.of(ToolDeniedError(message: "refused"), stopped: false).status == .denied)
        #expect(ToolCallOutcome.of(HostRefusedPresetError(message: "no"), stopped: false).status == .denied)
        #expect(ToolCallOutcome.of(ApelinError(.denied, "no"), stopped: false).status == .denied)
        #expect(ToolCallOutcome.of(ApelinError(.timeout, "slow"), stopped: false).status == .timedOut)
        #expect(ToolCallOutcome.of(ApelinError(.cancelled), stopped: false).status == .cancelled)
        #expect(ToolCallOutcome.of(ApelinError(.internal, "boom"), stopped: false).status == .failed)
        #expect(ToolCallOutcome.of(ToolTimeoutError(message: "slow"), stopped: false).status == .timedOut)
        #expect(ToolCallOutcome.of(URLError(.timedOut), stopped: false).status == .timedOut)
        #expect(ToolCallOutcome.of(ToolArgumentError("bad"), stopped: false).status == .failed)
    }

    // MARK: - A session's journal

    @Test(.timeLimit(.minutes(1)))
    func `a call that succeeds is journaled from its start to its end`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("README.md", "hello\n")
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(
                blocks: [fauxToolCall(name: "file_read", arguments: ["reason": "Read it", "path": "README.md"], id: "call-read")],
                stopReason: .toolUse,
            )),
            .message(fauxAssistantMessage("It says hello.")),
        ])
        let session = try await Self.open(home, faux: faux)
        try await session.prompt("What does the README say?")
        await session.waitForIdle()
        await session.close()

        let text = try Self.journal(of: session, in: home)
        let started = try #require(Self.line(in: text, containing: "Started call=call-read tool=file_read session=\(session.id) "))
        #expect(started.hasPrefix("* |info| "))
        #expect(started.contains(#"arguments={"path":"README.md","reason":"Read it"}"#), "\(started)")
        let ended = try #require(Self.line(in: text, containing: "Ended call=call-read tool=file_read session=\(session.id) "))
        #expect(ended.contains(" status=succeeded started="), "\(ended)")
        #expect(ended.contains(" duration=") && ended.contains("result="))
        #expect(text.contains("[Session]\n") && text.contains("| Opened session=\(session.id) "))
        #expect(text.contains(" api=\(faux.getModel().api) ") && text.contains("| Run 1 started "))
        #expect(text.contains("| Run 1 ended reason=completed ") && text.contains(" tools=1"))
        #expect(text.contains("| Closed session=\(session.id)"))
        #expect(SessionJournal.unfinishedCalls(in: text, session: session.id).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a call the user declines ends denied, and one a stop interrupts ends cancelled`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            Self.removal(id: "call-declined"),
            .message(fauxAssistantMessage("Left it installed.")),
            Self.removal(id: "call-stopped"),
            .message(fauxAssistantMessage("never reached")),
        ])
        let session = try await Self.open(home, faux: faux)
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt("Remove the package")
        var stopping = false
        var finished = 0
        for await record in stream {
            switch record.event {
            case let .approvalRequested(request) where request.toolCallID == "call-declined":
                try await session.approve(requestID: request.id, decision: .deny(reason: "not now"))
            case .approvalRequested:
                stopping = true
                await session.abort()
            case .finished:
                finished += 1
                if finished == 1 {
                    try await session.prompt("Remove it after all")
                }
            default:
                break
            }
            if finished == 2 {
                break
            }
        }
        #expect(stopping)
        await session.close()

        let text = try Self.journal(of: session, in: home)
        let declined = try #require(Self.line(in: text, containing: "Ended call=call-declined "))
        #expect(declined.contains(" status=denied ") && declined.contains(#"detail="the user declined it""#), "\(declined)")
        let stopped = try #require(Self.line(in: text, containing: "Ended call=call-stopped "))
        #expect(stopped.contains(" status=cancelled "), "\(stopped)")
        #expect(text.contains("[Approval]\n") && text.contains("| Asked approval="))
        #expect(text.contains(#"call=call-declined tool=apelin_package_remove after="#))
        #expect(text.contains(#"decision="denied: not now""#))
        #expect(text.contains("| Run 2 ended reason=aborted "))
    }

    @Test(.timeLimit(.minutes(1)))
    func `a compaction is journaled to its end, and a failed one with its status`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        var refused = fauxAssistantMessage("", stopReason: .error, errorMessage: #"{"detail":"Unsupported parameter: metadata"}"#)
        refused.failure = ProviderFailure(
            message: #"{"detail":"Unsupported parameter: metadata"}"#,
            httpStatus: 400,
            requestId: "req-26",
        )
        faux.setResponses([
            .message(fauxAssistantMessage("First: " + long)),
            .message(fauxAssistantMessage("Second: " + long)),
            .message(fauxAssistantMessage("Third: " + long)),
            .message(refused),
            .message(refused),
        ])
        let session = try await Self.open(home, faux: faux)
        let stream = try await session.events(afterSeq: 0)
        var events = stream.makeAsyncIterator()
        for prompt in ["one", "two", "three"] {
            try await session.prompt(prompt)
            await session.waitForIdle()
        }

        try await session.compact()
        let failed = try #require(await Self.compaction(from: &events))
        #expect(failed.outcome == .failed, "\(failed)")
        // the replies left over make a summary the second time
        faux.setResponses([.message(fauxAssistantMessage("The user built a tweak; the hook loads."))])
        try await session.compact()
        let compacted = try #require(await Self.compaction(from: &events))
        #expect(compacted.outcome == .compacted, "\(compacted)")
        await session.close()

        let text = try Self.journal(of: session, in: home)
        let failure = try #require(Self.line(in: text, containing: "| Failed trigger=requested "))
        #expect(failure.hasPrefix("* |error| "))
        #expect(failure.contains(" status=400 ") && failure.contains("Unsupported parameter: metadata"), "\(failure)")
        #expect(failure.contains(" duration=") && failure.contains(" summary=local "))
        let request = try #require(Self.line(in: text, containing: "| Request failed status=400 "))
        #expect(request.contains(" request=req-26 ") && request.contains(" api=\(faux.getModel().api) "), "\(request)")
        let started = text.components(separatedBy: "| Started trigger=requested messages=")
        #expect(started.count == 3, "both compactions name what they started from: \(text)")
        #expect(started[1].contains(" tokens≈") && started[1].contains(" window="))
        let ended = try #require(Self.line(in: text, containing: "| Ended outcome=compacted trigger=requested "))
        #expect(ended.contains(" summary=local ") && ended.contains(" tokens≈"), "\(ended)")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a native compaction that fails is journaled with its status`() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let file = DiagnosticJournal(folder: folder, name: "native")
        let journal = SessionJournal(sessionID: "native", file: file, redaction: JournalRedaction(home: nil, installRoot: nil))
        let refusing = AgentContextCompactionConfig(nativeCompaction: { _, _, _, _ in
            throw ProviderFailure(message: #"{"detail":"Unsupported parameter: metadata"}"#, httpStatus: 400)
        })
        let model = faux.getModel()
        let usage = AgentContextUsage(tokens: 30000, window: 200_000)
        journal.compactionStarted(.automatic, model: model, messages: 6, usage: usage)
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        let messages: [Message] = ["one", "two", "three"].flatMap { prompt -> [Message] in
            [.user(UserMessage(text: prompt)), .assistant(fauxAssistantMessage(prompt + ": " + long))]
        }
        let result = await AgentContextCompactor.compactMessages(
            messages: messages,
            model: model,
            sessionId: "native",
            config: journal.observingCompaction(refusing),
        )
        guard case let .failure(.failed(reason)) = result else {
            Issue.record("the refused compaction went on: \(result)")
            return
        }
        journal.compactionEnded(.failed(reason), usage: usage, stopped: false)

        let text = file.contents()
        let native = try #require(Self.line(in: text, containing: "| Native compaction failed status=400 "))
        #expect(native.hasPrefix("* |warning| ") && native.contains("Unsupported parameter: metadata"), "\(text)")
        let failed = try #require(Self.line(in: text, containing: "| Failed trigger=automatic "))
        #expect(failed.contains(" summary=native status=400 "), "\(text)")
    }

    @Test(.timeLimit(.minutes(1)))
    func `a call left running ends interrupted when the conversation closes, and one a crash left when it opens again`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let id = UUID().uuidString
        // what a process killed mid-call leaves
        try FileManager.default.createDirectory(at: home.dataRoot.agentJournals, withIntermediateDirectories: true)
        DiagnosticJournal(folder: home.dataRoot.agentJournals, name: id)
            .write("Tool", "Started call=crashed-1 tool=shell_run session=\(id) at=10:00:00.000 arguments={}")

        let session = try await Self.open(home, faux: faux, id: id)
        session.journal.toolStarted(id: "running-1", name: "apelin_project_build", arguments: .object([:]))
        await session.close()
        var text = try Self.journal(of: session, in: home)
        let crashed = try #require(Self.line(in: text, containing: "Ended call=crashed-1 tool=shell_run session=\(id) "))
        #expect(crashed.hasPrefix("* |error| ") && crashed.contains(" status=interrupted "), "\(crashed)")
        #expect(crashed.contains("found when the conversation opened again"))
        let closed = try #require(Self.line(in: text, containing: "Ended call=running-1 tool=apelin_project_build "))
        #expect(closed.contains(" status=interrupted ") && closed.contains("the conversation closed while it ran"))

        // opened again, nothing is left to end
        let reopened = try await Self.open(home, faux: faux, id: id)
        await reopened.close()
        text = try Self.journal(of: reopened, in: home)
        #expect(text.components(separatedBy: " status=interrupted ").count == 3, "\(text)")
        #expect(text.contains("| Reopened session=\(id) "))
    }

    // MARK: - Helpers

    private static func folder() throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("apelin-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func lastLine(of journal: DiagnosticJournal) -> String {
        let lines = journal.contents().split(separator: "\n")
        return (lines.last.map(String.init) ?? "") + "\n"
    }

    private static func open(
        _ home: TemporaryHome,
        faux: FauxProviderRegistration,
        id: String = UUID().uuidString,
    ) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                id: id,
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }

    private static func removal(id: String) -> FauxResponseStep {
        .message(fauxAssistantMessage(
            blocks: [fauxToolCall(
                name: "apelin_package_remove",
                arguments: ["reason": "Remove it", "installation_id": "inst-1"],
                id: id,
            )],
            stopReason: .toolUse,
        ))
    }

    private static func journal(of session: AgentSession, in home: TemporaryHome) throws -> String {
        try String(
            contentsOf: home.dataRoot.agentJournals.appendingPathComponent(session.id + ".log"),
            encoding: .utf8,
        )
    }

    private static func line(in text: String, containing fragment: String) -> String? {
        text.split(separator: "\n").first { $0.contains(fragment) }.map(String.init)
    }

    /// The outcome the next `compactionFinished` reports, after its start.
    private static func compaction(
        from events: inout AsyncStream<SessionEventRecord>.Iterator,
    ) async -> AgentCompactionResult? {
        var started = false
        while let record = await events.next() {
            switch record.event {
            case .compactionStarted:
                started = true
            case let .compactionFinished(result) where started:
                return result
            default:
                continue
            }
        }
        return nil
    }
}
