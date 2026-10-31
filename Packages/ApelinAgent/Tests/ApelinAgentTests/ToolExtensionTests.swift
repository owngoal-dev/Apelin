@testable import ApelinAgent
import class ApelinProtocol.OwnedDescriptor
import struct ApelinToolCore.ToolManifestPolicy
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import KWWKAgent
import KWWKAI
import Testing

/// Agent tool extensions installed under a throwaway install root, as the
/// package manager installs them, but owned by this test's user rather
/// than root.
struct InstalledToolExtensions {
    static let policy = ToolManifestPolicy(requiredOwner: getuid())

    let root: URL

    init(in home: TemporaryHome) throws {
        root = home.home.appendingPathComponent("install-root", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var path: String {
        root.path
    }

    private var folder: URL {
        root.appendingPathComponent("usr/share/apelin/agent-tools", isDirectory: true)
    }

    /// The repository's own manifest of the Disassembler or the Assembler.
    static func shipped(_ tool: String) throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appendingPathComponent("Extensions/AgentTools/Disassembler/Packaging/\(tool)/manifest.json"))
    }

    /// An extension of `tools`, each described as doing its name, with an
    /// object schema of no properties unless it gives one.
    static func manifest(
        _ id: String,
        name: String,
        tools: [(name: String, parameters: [String: Any])],
    ) throws -> Data {
        let declared: [[String: Any]] = tools.map { tool in
            let parameters: [String: Any] = tool.parameters.isEmpty ? ["type": "object"] : tool.parameters
            return [
                "name": tool.name,
                "description": "Does \(tool.name).",
                "parameters": parameters,
                "risk": "readOnly",
                "timeoutSeconds": 30,
            ]
        }
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "id": id,
            "name": name,
            "version": "1.0.0",
            "license": "MIT",
            "executable": "usr/libexec/apelin/agent-tools/\(id)",
            "protocolVersions": [1],
            "tools": declared,
        ]
        return try JSONSerialization.data(withJSONObject: manifest)
    }

    /// Installs `manifest` as extension `id`, with the license files and
    /// the executable it names.
    func install(_ id: String, manifest: Data) throws {
        let directory = folder.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifest.write(to: directory.appendingPathComponent("manifest.json"))
        let fields = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any]
        for license in fields?["licenseFiles"] as? [String] ?? [] {
            let file = directory.appendingPathComponent(license)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("License text.\n".utf8).write(to: file)
        }
        guard let executable = fields?["executable"] as? String else { return }
        let file = root.appendingPathComponent(executable)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    func installShipped() throws {
        try install("wiki.qaq.apelin.agent-tools.disassembler", manifest: Self.shipped("disassembler"))
        try install("wiki.qaq.apelin.agent-tools.assembler", manifest: Self.shipped("assembler"))
    }

    func offer() -> ToolExtensionOffer {
        ToolExtensionOffer.read(installRoot: path, policy: Self.policy)
    }
}

/// A descriptor holding `data`, from an unlinked temporary file.
func descriptor(holding data: Data) -> OwnedDescriptor {
    let path = NSTemporaryDirectory() + "apelin-agent-tests-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: path, contents: data)
    let fd = open(path, O_RDONLY)
    unlink(path)
    return OwnedDescriptor(adopting: fd)
}

@Suite("Agent tool extensions")
struct ToolExtensionTests {
    private static let disassembler = "wiki.qaq.apelin.agent-tools.disassembler"

    private static func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { block -> String? in
            if case let .text(text) = block {
                return text.text
            }
            return nil
        }.joined()
    }

    private static func runner(_ home: TemporaryHome, backend: MockBackend) throws -> ToolRunner {
        try ToolRunner(
            sessionID: UUID().uuidString,
            project: home.project,
            root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .relaxed),
            backend: backend,
            digests: MockDigestLedger(),
            gate: ApprovalGate { _ in },
        )
    }

    /// The agent's tool `name` among those `runner` offers for `offer`.
    private static func tool(_ name: String, of runner: ToolRunner, offer: ToolExtensionOffer) throws -> AgentTool {
        try #require(runner.agentTools(mcp: [], extensions: offer.extensions).first { $0.name == name })
    }

    // MARK: What is offered

    @Test
    func `the shipped extensions are offered under their own names, by id and then manifest`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let offer = installed.offer()
        #expect(offer.leftOut.isEmpty, "\(offer.leftOut)")
        #expect(offer.extensions.map(\.id) == ["wiki.qaq.apelin.agent-tools.assembler", Self.disassembler])
        #expect(offer.tools.map(\.name) == ["assemble", "disassemble", "symbols"])
        #expect(offer.tools.map(\.timeoutSeconds) == [30, 30, 30])
        #expect(offer.tools[1].required == ["binary", "address"])

        let runner = try Self.runner(home, backend: MockBackend())
        let names = runner.agentTools(mcp: []).map(\.name)
        let tools = runner.agentTools(mcp: [], extensions: offer.extensions)
        #expect(tools.map(\.name) == names + ["assemble", "disassemble", "symbols"], "after Apelin's own")
        let symbols = try #require(tools.last)
        #expect(symbols.description.hasPrefix("List the symbol table (LC_SYMTAB)"))
        #expect(symbols.description.hasSuffix("From Disassembler 1.1.0, an agent tool extension: it runs in its own process as mobile, outside the project, so give it absolute paths."))
        #expect(symbols.parameters["properties"]?["reason"] != nil, "a call carries its reason as every tool's does")
        #expect(symbols.parameters["required"] == ["binary", "reason"])
        #expect(symbols.parameters["properties"]?["limit"]?["maximum"] == .int(5000), "a whole number is an integer")
        #expect(symbols.omitsBlankOptionalArguments)
    }

    @Test
    func `a name Apelin's tools have or had, one a provider refuses, a reason argument, or a name two extensions declare is left out`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        let reason: [String: Any] = ["type": "object", "properties": ["reason": ["type": "string"]]]
        try installed.install("example.first", manifest: InstalledToolExtensions.manifest("example.first", name: "First", tools: [
            ("shell_run", [:]), ("build", [:]), ("Upper", [:]), ("two__parts", [:]), ("trailing_", [:]),
            ("with-dash", [:]), ("kept", [:]), ("shared", [:]),
        ]))
        try installed.install("example.second", manifest: InstalledToolExtensions.manifest("example.second", name: "Second", tools: [
            ("shared", [:]), ("explains", reason),
        ]))
        let offer = installed.offer()
        #expect(offer.extensions.map(\.id) == ["example.first"], "an extension with nothing left is not listed")
        #expect(offer.tools.map(\.name) == ["kept"])
        let leftOut = offer.leftOut.joined(separator: "\n")
        for line in [
            "example.first: tool shell_run is the name of one of Apelin's own tools",
            "example.first: tool build is the name of one of Apelin's own tools",
            "example.first: tool Upper is not a name",
            "example.first: tool two__parts is not a name",
            "example.first: tool trailing_ is not a name",
            "example.first: tool with-dash is not a name",
            "example.first: tool shared is declared by example.second as well",
            "example.second: tool shared is declared by example.first as well",
            "example.second: tool explains takes an argument named reason",
        ] {
            #expect(leftOut.contains(line), "no \(line) in \(leftOut)")
        }
    }

    @Test
    func `a manifest that does not validate is left out alone, and one root does not own is never offered`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        try installed.install("example.broken", manifest: Data("{\"schemaVersion\": 1".utf8))
        try installed.install("example.misnamed", manifest: InstalledToolExtensions.manifest("example.other", name: "Other", tools: [("other", [:])]))
        let offer = installed.offer()
        #expect(offer.tools.map(\.name) == ["assemble", "disassemble", "symbols"])
        #expect(offer.leftOut.count == 2)
        #expect(offer.leftOut.contains { $0.hasPrefix("example.broken: manifest.json does not parse") })
        #expect(offer.leftOut.contains("example.misnamed: manifest id example.other does not match its directory"))

        // The device's rule: root's files only.
        let device = ToolExtensionOffer.read(installRoot: installed.path, policy: ToolManifestPolicy())
        #expect(device.extensions.isEmpty)
        #expect(device.leftOut.count == 4 && device.leftOut.allSatisfy { $0.contains("is owned by uid \(getuid()), not 0") })
        #expect(ToolExtensionOffer.read(installRoot: nil, policy: InstalledToolExtensions.policy) == ToolExtensionOffer.none)
    }

    @Test
    func `the environment names each extension offered and its tools, and nothing when none is`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            installRoot: installed.path, toolExtensionPolicy: InstalledToolExtensions.policy,
        )
        let root = try ScopedRoot(home.projectURL)
        let section = EnvironmentPrompt.section(EnvironmentPrompt.inputs(
            configuration,
            root: root,
            device: .current,
            toolExtensions: installed.offer().extensions,
        ))
        #expect(section.contains("\n- Agent tool extensions, packages the user installs and removes with their package manager, whose tools are among yours. Each runs in its own process as mobile, outside the project, so give it absolute paths; their tools ask in Strict mode:\n  - Assembler 1.0.0 (wiki.qaq.apelin.agent-tools.assembler): assemble.\n  - Disassembler 1.1.0 (wiki.qaq.apelin.agent-tools.disassembler): disassemble, symbols."))
        let none = EnvironmentPrompt.section(EnvironmentPrompt.inputs(configuration, root: root, device: .current))
        #expect(!none.contains("Agent tool extensions"))
        // The state a session reads finds them itself when given none.
        #expect(PromptState.read(configuration, root: root, skills: []).environment == section)
    }

    // MARK: Approval

    @Test
    func `Strict asks about every call naming the extension, whatever risk it declares; Relaxed and Full run it`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let symbols = try #require(installed.offer().tools.first { $0.name == "symbols" })
        let facts = InvocationFacts(tool: .toolExtension(symbols))
        let root = try ScopedRoot(home.projectURL)
        #expect(ApprovalPolicy(mode: .relaxed).evaluate(facts, root: root) == .allow(.relaxed))
        #expect(ApprovalPolicy(mode: .full).evaluate(facts, root: root) == .allow(.relaxed))
        #expect(ApprovalPolicy(mode: .confirm).evaluate(facts, root: root) == .ask(
            reason: "symbols is a tool of Disassembler 1.1.0, an agent tool extension that runs in its own process. Review it before running.",
            detail: .none,
        ))
        #expect(ToolRunner.allowsSessionScope(.toolExtension(symbols), detail: .none), "as an MCP tool's")
    }

    @Test(.timeLimit(.minutes(1)))
    func `under Strict a call waits for the user, and one approved for the session runs again without asking until the extension changes`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let offer = installed.offer()
        let backend = MockBackend()
        let requests = EventCollector()
        let gate = ApprovalGate { await requests.add($0) }
        let runner = try ToolRunner(
            sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
            policy: ApprovalPolicy(mode: .confirm), backend: backend, digests: MockDigestLedger(), gate: gate,
        )
        let assemble = try Self.tool("assemble", of: runner, offer: offer)
        let arguments: JSONValue = ["reason": "Encode a return", "arch": "arm64", "source": "ret"]
        // The requests asked so far, once there are `count`.
        func asked(_ count: Int) async -> [ApprovalRequest] {
            var asked: [ApprovalRequest] = []
            while asked.count < count {
                await Task.yield()
                asked = await requests.events.compactMap { event -> ApprovalRequest? in
                    if case let .approvalRequested(request) = event {
                        return request
                    }
                    return nil
                }
            }
            return asked
        }
        let first = Task { try await assemble.execute("call-1", arguments, nil, nil) }
        let request = try #require(await asked(1).first)
        #expect(request.tool == "assemble" && request.allowsSessionScope)
        #expect(request.arguments == #"{"arch":"arm64","source":"ret"}"#, "the reason is no argument")
        #expect(await backend.toolCalls.isEmpty, "nothing runs before the user answers")
        try await gate.resolve(request.id, decision: .approve(.session))
        _ = try await first.value
        _ = try await assemble.execute("call-2", arguments, nil, nil)
        #expect(await backend.toolCalls.count == 2)
        #expect(await asked(1).count == 1, "the session's grant covers the same call")

        // The Assembler upgraded while the chat is open: its grant was for 1.0.0.
        var upgraded = offer
        upgraded.extensions[0].version = "1.0.1"
        let newer = try Self.tool("assemble", of: runner, offer: upgraded)
        let third = Task { try await newer.execute("call-3", arguments, nil, nil) }
        let again = try #require(await asked(2).last)
        #expect(again.reason.contains("Assembler 1.0.1"))
        try await gate.resolve(again.id, decision: .approve(.once))
        _ = try await third.value
        #expect(await backend.toolCalls.count == 3)
    }

    // MARK: Calls

    @Test
    func `an extension is opened on its first call, kept, and opened again once when it has exited`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let offer = installed.offer()
        let backend = MockBackend()
        let runner = try Self.runner(home, backend: backend)
        #expect(await backend.toolSessionsOpened.isEmpty, "nothing is opened before it is called")
        let symbols = try Self.tool("symbols", of: runner, offer: offer)
        let disassemble = try Self.tool("disassemble", of: runner, offer: offer)
        let assemble = try Self.tool("assemble", of: runner, offer: offer)

        let result = try await symbols.execute("call-1", [
            "reason": "List the symbols",
            "binary": "/usr/lib/dyld",
            "filter": "",
            "arch": .null,
            "kind": "defined",
        ], nil, nil)
        #expect(Self.text(result) == "symbols ran")
        _ = try await disassemble.execute("call-2", ["reason": "Look", "binary": "", "address": "_main"], nil, nil)
        #expect(await backend.toolSessionsOpened == [Self.disassembler], "one session for both of its tools")
        let calls = await backend.toolCalls
        #expect(calls.map(\.sessionID) == ["tool-session-1", "tool-session-1"])
        #expect(calls.map(\.tool) == ["symbols", "disassemble"])
        #expect(calls[0].arguments == ["binary": "/usr/lib/dyld", "kind": "defined"], "no reason, no empty optional argument")
        #expect(calls[1].arguments == ["binary": "", "address": "_main"], "a required one is the extension's to refuse")
        #expect(calls.allSatisfy { $0.timeoutSeconds == 30 })

        // The extension exits; the host lets its session go.
        await backend.endToolSession("tool-session-1")
        _ = try await symbols.execute("call-3", ["reason": "Again", "binary": "/usr/lib/dyld"], nil, nil)
        #expect(await backend.toolSessionsOpened == [Self.disassembler, Self.disassembler])
        #expect(await backend.toolCalls.suffix(2).map(\.sessionID) == ["tool-session-1", "tool-session-2"])
        _ = try await assemble.execute("call-4", ["reason": "Encode", "arch": "arm64", "source": "nop"], nil, nil)

        await runner.closeToolExtensions()
        #expect(await backend.toolSessionsClosed == ["tool-session-3", "tool-session-2"], "every session it holds, by extension id")
        // a call after the close was stopped with its conversation, not refused
        await #expect(throws: ConversationClosingError.self) {
            try await symbols.execute("call-5", ["reason": "Late", "binary": "/usr/lib/dyld"], nil, nil)
        }
        #expect(await backend.toolSessionsOpened.count == 3, "nothing opens once the session closed")
    }

    @Test
    func `an error answer is the call's failure, in the extension's words`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let backend = MockBackend()
        await backend.setToolAnswer { _ in
            ToolExtensionCallResponse(text: "", failure: ToolExtensionFailure(code: "invalidArguments", message: "count must be at most 1000"))
        }
        let runner = try Self.runner(home, backend: backend)
        let disassemble = try Self.tool("disassemble", of: runner, offer: installed.offer())
        do {
            _ = try await disassemble.execute("call-1", ["reason": "Look", "binary": "/usr/lib/dyld", "address": "0x1000", "count": 5000], nil, nil)
            Issue.record("the call succeeded")
        } catch {
            #expect(error.localizedDescription == "Disassembler answered invalidArguments: count must be at most 1000")
        }
    }

    @Test
    func `a file the tool returns is saved under Attachments for file_read and listed for the app; an image is shown too`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        try installed.installShipped()
        let listing = Data("0000000100003f50 T _main\n".utf8)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        let image = png as Data
        let backend = MockBackend()
        await backend.setToolAnswer { _ in
            ToolExtensionCallResponse(text: "1 symbol", files: [
                ToolExtensionFile(name: "symbols.txt", mimeType: "text/plain", descriptor: descriptor(holding: listing)),
                ToolExtensionFile(name: "graph.png", mimeType: nil, descriptor: descriptor(holding: image)),
            ])
        }
        let runner = try Self.runner(home, backend: backend)
        let symbols = try Self.tool("symbols", of: runner, offer: installed.offer())
        let result = try await symbols.execute("call-1", ["reason": "List them", "binary": "/usr/lib/dyld", "output": "file"], nil, nil)

        let copies = FileShow.copies(in: result.details)
        #expect(copies.map(\.name) == ["symbols.txt", "graph.png"])
        #expect(copies.map(\.mimeType) == ["text/plain", "image/png"], "a type the tool gave none is its name's")
        #expect(copies.allSatisfy { $0.path.hasPrefix("Attachments/") })
        #expect(try copies.map { try Data(contentsOf: home.projectURL.appendingPathComponent($0.path)) } == [listing, image])
        #expect(Self.text(result) == """
        1 symbol

        Files it returned, shown to the user in this conversation and saved for file_read:
        - \(copies[0].path): symbols.txt, text/plain, \(listing.count) bytes
        - \(copies[1].path): graph.png, image/png, \(image.count) bytes
        """)
        let images = result.content.filter {
            if case .image = $0 {
                true
            } else {
                false
            }
        }
        #expect(images.count == 1, "the picture is before the model as well")

        // A file and no text; neither.
        await backend.setToolAnswer { _ in
            ToolExtensionCallResponse(text: "", files: [
                ToolExtensionFile(name: "symbols.txt", mimeType: "text/plain", descriptor: descriptor(holding: listing)),
            ])
        }
        let fileOnly = try await symbols.execute("call-2", ["reason": "List them", "binary": "/usr/lib/dyld", "output": "file"], nil, nil)
        #expect(Self.text(fileOnly).hasPrefix("Files it returned, shown to the user"))
        await backend.setToolAnswer { _ in ToolExtensionCallResponse(text: "") }
        let nothing = try await symbols.execute("call-3", ["reason": "List them", "binary": "/usr/lib/dyld"], nil, nil)
        #expect(Self.text(nothing) == "symbols answered with nothing.")
        #expect(FileShow.copies(in: nothing.details).isEmpty)
    }

    // MARK: A session

    /// What the provider was sent, one entry per request.
    private actor Requests {
        private(set) var all: [(systemPrompt: String?, tools: [Tool]?, messages: [Message])] = []

        func add(_ context: Context) {
            all.append((context.systemPrompt, context.tools, context.messages))
        }
    }

    private static func lastUserText(_ messages: [Message]) -> String {
        guard case let .user(user)? = messages.last(where: {
            if case .user = $0 {
                true
            } else {
                false
            }
        }) else { return "" }
        return user.content.compactMap { block -> String? in
            if case let .text(content) = block {
                return content.text
            }
            return nil
        }.joined()
    }

    @Test(.timeLimit(.minutes(1)))
    func `an extension installed while a chat is open is callable from the next message, which says so; its file is shown`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let installed = try InstalledToolExtensions(in: home)
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let requests = Requests()
        func reply(_ message: AssistantMessage) -> FauxResponseStep {
            .factory { context, _, _, _ in
                await requests.add(context)
                return message
            }
        }
        provider.setResponses([
            reply(fauxAssistantMessage("Nothing to disassemble with.")),
            reply(fauxAssistantMessage(blocks: [fauxToolCall(name: "symbols", arguments: [
                "reason": "List the symbols", "binary": "/usr/lib/dyld", "output": "file",
            ], id: "call-1")], stopReason: .toolUse)),
            reply(fauxAssistantMessage("Listed.")),
        ])
        let backend = MockBackend()
        await backend.setToolAnswer { _ in
            ToolExtensionCallResponse(text: "1 symbol", files: [
                ToolExtensionFile(name: "symbols.txt", mimeType: "text/plain", descriptor: descriptor(holding: Data("T _main\n".utf8))),
            ])
        }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()), approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot, installRoot: installed.path, toolExtensionPolicy: InstalledToolExtensions.policy,
            ),
            backend: backend,
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("Disassemble dyld.", messageID: UUID())
        await session.waitForIdle()
        try installed.installShipped()
        try await session.prompt("I installed the Disassembler.", messageID: UUID())
        await session.waitForIdle()
        let log = try await session.log.records(afterSeq: 0)
        await session.close()

        let sent = await requests.all
        try #require(sent.count == 3)
        #expect(sent[0].tools?.contains { $0.name == "symbols" } == false)
        #expect(sent[1].tools?.map(\.name).suffix(3) == ["assemble", "disassemble", "symbols"])
        #expect(sent[1].tools == sent[2].tools)
        #expect(sent[1].systemPrompt == sent[0].systemPrompt, "the system prompt stays the session's")
        let told = Self.lastUserText(sent[1].messages)
        #expect(told.contains("- now: Disassembler 1.1.0 (wiki.qaq.apelin.agent-tools.disassembler): disassemble, symbols."), "\(told)")
        #expect(!Self.lastUserText(sent[0].messages).contains("Agent tool extensions"))

        #expect(await backend.toolSessionsOpened == [Self.disassembler])
        #expect(await backend.toolSessionsClosed == ["tool-session-1"], "closed with the session")
        let finished = log.compactMap { record -> ToolResultRecord? in
            if case let .toolCallFinished(result) = record.event {
                return result
            }
            return nil
        }
        let shown = try #require(finished.first?.attachments)
        #expect(shown.map(\.name) == ["symbols.txt"])
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(shown[0].path)) == Data("T _main\n".utf8))
    }
}
