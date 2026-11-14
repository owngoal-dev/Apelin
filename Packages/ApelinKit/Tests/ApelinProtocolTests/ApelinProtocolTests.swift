import ApelinCore
@testable import ApelinProtocol
import Foundation
import XCTest

final class OperationTableTests: XCTestCase {
    func testEveryOperationHasItsOwnRequestType() {
        var seen = Set<String>()
        for operation in AppOperation.allCases {
            let type = operation.requestType
            XCTAssertEqual(type.operation, operation, "\(type) names \(type.operation), not \(operation)")
            XCTAssertTrue(seen.insert(String(describing: type)).inserted, "\(type) serves two operations")
        }
    }

    func testAttachOperationsAreAttaches() {
        for kind in [TaskKind.environment, .build, .install, .agent, .terminal, .logStream, .confirmLoaded, .signIn] {
            XCTAssertTrue(kind.attachOperation.requestType is any TaskAttachRequest.Type, "\(kind)")
        }
    }

    /// A sign-in's answers travel as a plain map keyed by the field names
    /// kwwk keeps them under; the typed initializer spells them the same.
    func testSignInFieldsKeepKwwksNames() throws {
        let typed = AgentSignInRespondRequest(taskID: TaskID("t"), fields: [.apiKey: "k", .baseURL: "u", .defaultModel: "m"])
        XCTAssertEqual(typed.values, ["apiKey": "k", "baseUrl": "u", "defaultModel": "m"])
        let decoded = try JSONCoding.decode(
            AgentSignInRespondRequest.self,
            from: Data(#"{"taskID":"t","values":{"callbackURL":"http://localhost:53692/callback?code=c"}}"#.utf8),
        )
        XCTAssertEqual(decoded.values[AgentSignInField.callbackURL.rawValue], "http://localhost:53692/callback?code=c")
        let signIn = try JSONCoding.decode(AgentSignInRequest.self, from: Data(#"{"provider":"anthropicOAuth"}"#.utf8))
        XCTAssertEqual(signIn.provider, .anthropicOAuth)
        XCTAssertNil(signIn.method)
        let byKey = try JSONCoding.decode(AgentSignInRequest.self, from: Data(#"{"provider":"openRouter","method":"apiKey"}"#.utf8))
        XCTAssertEqual(byKey.provider, .openRouter)
        XCTAssertEqual(byKey.method, .apiKey)
        XCTAssertEqual(TaskHandle(taskID: TaskID("t"), kind: .signIn).attachOperation, .agentAttach)
    }

    /// #60: a further OpenAI-compatible endpoint is a provider of its own
    /// on the wire, `openAICompatible.<number>`, in one spelling only.
    func testAFurtherEndpointIsAProviderOfItsOwn() throws {
        let second = AgentProvider.openAICompatibleEndpoint(2)
        XCTAssertEqual(second.rawValue, "openAICompatible.2")
        XCTAssertEqual(AgentProvider(rawValue: "openAICompatible.2"), second)
        XCTAssertEqual(try JSONCoding.decode(AgentProvider.self, from: Data(#""openAICompatible.17""#.utf8)), .openAICompatibleEndpoint(17))
        XCTAssertEqual(try String(decoding: JSONCoding.encode(second), as: UTF8.self), #""openAICompatible.2""#)
        XCTAssertNotEqual(second, .openAICompatible)
        XCTAssertNotEqual(second, .openAICompatibleEndpoint(3))
        XCTAssertEqual(second.kind, .openAICompatible)
        XCTAssertEqual(AgentProvider.deepSeek.kind, .deepSeek)
        XCTAssertFalse(AgentProvider.allCases.contains(second))
        for bad in [
            "openAICompatible.", "openAICompatible.1", "openAICompatible.0", "openAICompatible.100",
            "openAICompatible.02", "openAICompatible.+2", "openAICompatible.2 ", "openAICompatible.two",
            "openAICompatible.-2", "openaicompatible.2", "deepSeek.2", "nobody",
        ] {
            XCTAssertNil(AgentProvider(rawValue: bad), bad)
            XCTAssertThrowsError(try JSONCoding.decode(AgentProvider.self, from: Data("\"\(bad)\"".utf8)), bad)
        }
        // A request carries it where it carried the provider.
        let request = try JSONCoding.decode(
            AgentSignInRequest.self,
            from: Data(#"{"provider":"openAICompatible.3","method":"apiKey"}"#.utf8),
        )
        XCTAssertEqual(request.provider, .openAICompatibleEndpoint(3))
    }

    /// The first four providers keep the names scripts and fixtures already
    /// carry; every case decodes from its own name.
    func testProviderNamesStay() throws {
        XCTAssertEqual(
            AgentProvider.allCases.prefix(4).map(\.rawValue),
            ["githubCopilot", "anthropic", "anthropicOAuth", "openAICompatible"],
        )
        for provider in AgentProvider.allCases {
            let decoded = try JSONCoding.decode(AgentProvider.self, from: Data("\"\(provider.rawValue)\"".utf8))
            XCTAssertEqual(decoded, provider)
        }
        let account = try JSONCoding.decode(
            AgentAccount.self,
            from: Data(#"{"provider":"githubCopilot","method":"deviceCode","signedIn":false}"#.utf8),
        )
        XCTAssertNil(account.alternativeMethods)
    }

    /// The console writes requests by hand; Documents/Console.md shows these.
    func testHandWrittenRequestsDecode() throws {
        let setup = try JSONCoding.decode(ToolchainSetupRequest.self, from: Data(#"{"source":{"appleCatalog":{}},"components":["c"]}"#.utf8))
        XCTAssertEqual(setup.source, .appleCatalog(productID: nil))
        let action = try JSONCoding.decode(UIActionRequest.self, from: Data(#"{"action":{"tap":{"x":10,"y":20}}}"#.utf8))
        XCTAssertEqual(action.action, .tap(x: 10, y: 20))
        let sdk = try JSONCoding.decode(SDKImportRequest.self, from: Data(#"{"source":{"repository":{"url":"u","branch":"b"}}}"#.utf8))
        XCTAssertEqual(sdk.source, .repository(url: "u", branch: "b"))
        let confirm = try JSONCoding.decode(ConfirmLoadedRequest.self, from: Data(#"{"buildID":"B-1","targetID":"com.apple.springboard","trigger":"respring","imageCheck":"regionPaths"}"#.utf8))
        XCTAssertEqual(confirm.trigger, .respring)
        XCTAssertEqual(confirm.imageCheck, .regionPaths)
        let plain = try JSONCoding.decode(ConfirmLoadedRequest.self, from: Data(#"{"buildID":"B-1","targetID":"SpringBoard"}"#.utf8))
        XCTAssertNil(plain.imageCheck, "the image list is not read unless asked")
    }

    /// A tap answers nothing, as `Acknowledged` did; a `type` answers what
    /// the fields hold.
    func testAUIActionAnswersOnlyWhatATypeLeft() throws {
        XCTAssertEqual(try JSONCoding.decode(UIActionResponse.self, from: Data("{}".utf8)), UIActionResponse())
        let typed = UIActionResponse(typedTextMatches: false, fieldValues: ["Hello wrd"])
        XCTAssertEqual(try JSONCoding.decode(UIActionResponse.self, from: JSONCoding.encode(typed)), typed)
        XCTAssertEqual(try String(decoding: JSONCoding.encode(UIActionResponse()), as: UTF8.self), "{}")
    }

    /// Full is a new mode; old stored and wire values still decode, and a
    /// shell_run request carries `asRoot` and the approve request
    /// `ownerVerified` through the wire.
    func testApprovalModeFullAndRootRunWire() throws {
        XCTAssertEqual(ApprovalMode(rawValue: "full"), .full)
        XCTAssertEqual(ApprovalMode(rawValue: "relaxed"), .relaxed)
        XCTAssertEqual(ApprovalMode(rawValue: "confirm"), .confirm)
        XCTAssertEqual(ApprovalMode.relaxed.asks, false)
        XCTAssertEqual(ApprovalMode.full.asks, false)
        XCTAssertEqual(ApprovalMode.confirm.asks, true)
        for mode in [ApprovalMode.relaxed, .confirm, .full] {
            let data = try JSONCoding.encode(mode)
            XCTAssertEqual(try JSONCoding.decode(ApprovalMode.self, from: data), mode)
        }
        // An open request written before Full decodes unchanged.
        let open = try JSONCoding.decode(AgentOpenRequest.self, from: Data(#"{"approvalMode":"confirm"}"#.utf8))
        XCTAssertEqual(open.approvalMode, .confirm)
        // Ask Before Using the Screen: absent is on, so a caller that never
        // heard of it cannot turn it off; only false does.
        XCTAssertNil(open.asksBeforeScreen)
        XCTAssertTrue(ScreenConsent.asks(open.asksBeforeScreen))
        XCTAssertFalse(try ScreenConsent.asks(request(for: AgentOpenRequest(asksBeforeScreen: false)).asksBeforeScreen))
        let prompt = try request(for: AgentPromptRequest(sessionID: "s", text: "t", asksBeforeScreen: true))
        XCTAssertEqual(prompt.asksBeforeScreen, true)
        XCTAssertNil(try request(for: AgentPromptRequest(sessionID: "s", text: "t")).asksBeforeScreen)
        XCTAssertTrue(ScreenConsent.usesScreen(.argv(["icli", "url", "open", "https://example.com"])))
        XCTAssertTrue(ScreenConsent.usesScreen(.script(interpreter: "sh", source: "icli screen info | head")))
        XCTAssertFalse(ScreenConsent.usesScreen(.argv(["make", "all"])))

        let root = AgentRunCodeRequest(sessionID: "s", spec: .argv(["irisin-cli", "install"]), approval: .relaxed, asRoot: true)
        let rootWire = try request(for: root)
        XCTAssertEqual(rootWire.asRoot, true)
        // An older request with no asRoot field is a mobile run.
        let mobile = try JSONCoding.decode(AgentRunCodeRequest.self, from: Data(#"{"sessionID":"s","spec":{"argv":{"_0":["make"]}},"workingDirectory":".","timeoutSeconds":120,"approval":{"relaxed":{}}}"#.utf8))
        XCTAssertNil(mobile.asRoot)

        let approve = AgentApproveRequest(sessionID: "s", approvalID: "a", decision: .approve, ownerVerified: true)
        XCTAssertEqual(try request(for: approve).ownerVerified, true)
        let old = try JSONCoding.decode(AgentApproveRequest.self, from: Data(#"{"sessionID":"s","approvalID":"a","decision":"approve"}"#.utf8))
        XCTAssertNil(old.ownerVerified, "an approve without the field claims no owner check")

        XCTAssertEqual(RunCodeApproval.rootCommandDetail, "rootCommand")
    }

    private func request<R: OperationRequest>(for request: R) throws -> R {
        try WireRequest(request).decode(R.self)
    }

    func testEnvelopeRoundTrip() throws {
        let request = try WireRequest(BuildStartRequest(projectID: "p1", configuration: .release))
        XCTAssertEqual(request.operation, .buildStart)
        XCTAssertEqual(request.protocolVersion, Wire.protocolVersion)
        let decoded = try request.decode(BuildStartRequest.self)
        XCTAssertEqual(decoded.projectID, "p1")
        XCTAssertThrowsError(try request.decode(BuildCancelRequest.self))
    }
}

/// Answers every request from a closure, as the session host would.
struct LoopbackTransport: ApelinTransport {
    let handler: @Sendable (WireRequest) -> WireReply

    func call(_ request: WireRequest, descriptors _: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        (handler(request), [])
    }
}

final class ServiceTests: XCTestCase {
    func testTypedCallAndError() async throws {
        let service = ApelinService(transport: LoopbackTransport { request in
            switch request.operation {
            case .hello: .success(request.requestID, HelloResponse(installRoot: "/var/jb"))
            default: .failure(request.requestID, .unimplemented(request.operation))
            }
        })
        let hello = try await service.hello()
        XCTAssertEqual(hello.installRoot, "/var/jb")
        do {
            _ = try await service.toolchainStatus()
            XCTFail("expected unimplemented")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .unimplemented)
        }
    }

    func testUntypedCall() async throws {
        let service = ApelinService(transport: LoopbackTransport { request in
            let create = try! request.decode(ProjectCreateRequest.self)
            return .success(request.requestID, ProjectCreateResponse(projectID: "id-1", name: create.name, path: "/p/\(create.name)"))
        })
        let request: JSONValue = .object(["templateID": .string("tweak/objc"), "name": .string("Hello"), "values": .object([:])])
        let (response, _) = try await service.sendUntyped(.projectCreate, request: request)
        XCTAssertEqual(response.value(at: "projectID"), .string("id-1"))
        do {
            _ = try await service.sendUntyped(.projectCreate, request: .object([:]))
            XCTFail("expected badRequest")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
        }
    }

    func testEventsReplayAfterSeq() async throws {
        let all = (1 ... 5).map { TaskEvent(seq: EventSeq(UInt64($0)), kind: "log", payload: .number(Double($0))) }
        let service = ApelinService(transport: LoopbackTransport { request in
            let attach = try! request.decode(BuildAttachRequest.self)
            // Two events per poll, finished once the last is delivered.
            let pending = all.filter { $0.seq > attach.afterSeq }.prefix(2)
            let last = pending.last?.seq ?? attach.afterSeq
            return .success(request.requestID, TaskEventBatch(taskID: attach.taskID, events: Array(pending), state: last.rawValue == 5 ? .succeeded : .running, lastSeq: last, finished: last.rawValue == 5))
        })
        var seqs: [UInt64] = []
        for try await event in service.events(of: TaskHandle(taskID: TaskID("t"), kind: .build), afterSeq: EventSeq(1)) {
            seqs.append(event.seq.rawValue)
        }
        XCTAssertEqual(seqs, [2, 3, 4, 5])
    }

    /// confirmLoaded answers a handle; the convenience reads the task to its
    /// end and takes the answer out of the final `state`.
    func testConfirmLoadedReadsTheAnswerFromTheFinalState() async throws {
        let answer = ConfirmLoadedResponse(loaded: true, evidence: [
            LoadEvidence(kind: "log", passed: true, detail: "confirmed: Marker logged by pid 55."),
            LoadEvidence(kind: "image", passed: false, detail: "notRead: the image check is off"),
        ])
        let final = try TaskEvent(seq: EventSeq(2), kind: TaskEvent.stateKind, payload: .object([
            "state": .string("succeeded"),
            ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer),
        ]))
        let service = ApelinService(transport: LoopbackTransport { request in
            switch request.operation {
            case .confirmLoaded:
                let start = try! request.decode(ConfirmLoadedRequest.self)
                XCTAssertEqual(start.trigger, .respring)
                return .success(request.requestID, TaskHandle(taskID: TaskID("c1"), kind: .confirmLoaded))
            case .confirmLoadedAttach:
                let attach = try! request.decode(ConfirmLoadedAttachRequest.self)
                let all = [TaskEvent(seq: EventSeq(1), kind: "stage", payload: .object(["stage": .string("listening")])), final]
                let pending = all.filter { $0.seq > attach.afterSeq }
                return .success(request.requestID, TaskEventBatch(taskID: attach.taskID, events: pending, state: .succeeded, lastSeq: EventSeq(2), finished: true))
            default:
                return .failure(request.requestID, .unimplemented(request.operation))
            }
        })
        let response = try await service.confirmLoaded(buildID: "B-1", targetID: "SpringBoard", trigger: .respring)
        XCTAssertEqual(response, answer)
    }

    func testALoadCheckWithoutAnAnswerThrows() {
        let interrupted = TaskEvent(seq: EventSeq(1), kind: TaskEvent.stateKind, payload: .object(["state": .string("interrupted"), "message": .string("the session host stopped while this ran")]))
        XCTAssertThrowsError(try ConfirmLoadedResponse.from(finalState: interrupted)) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .unavailable)
        }
        let failed = TaskEvent(seq: EventSeq(1), kind: TaskEvent.stateKind, payload: .object(["state": .string("failed"), "message": .string("apelin-diagnostics exited")]))
        XCTAssertThrowsError(try ConfirmLoadedResponse.from(finalState: failed)) { error in
            XCTAssertEqual((error as? ApelinError)?.message, "apelin-diagnostics exited")
        }
    }
}

/// A transport that keeps what was sent and answers with descriptors, as
/// the session host would.
final class DescriptorTransport: ApelinTransport, @unchecked Sendable {
    let handler: @Sendable (WireRequest, [OwnedDescriptor]) -> (WireReply, [OwnedDescriptor])
    init(handler: @escaping @Sendable (WireRequest, [OwnedDescriptor]) -> (WireReply, [OwnedDescriptor])) {
        self.handler = handler
    }

    func call(_ request: WireRequest, descriptors: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        handler(request, descriptors)
    }
}

final class ToolHostCallTests: XCTestCase {
    private func pipeEnd(writing text: String) -> OwnedDescriptor {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&fds), 0)
        _ = text.withCString { write(fds[1], $0, strlen($0)) }
        close(fds[1])
        return OwnedDescriptor(adopting: fds[0])
    }

    private func read(_ descriptor: OwnedDescriptor) -> String {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(descriptor.rawValue, &buffer, buffer.count)
        return String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
    }

    /// Files go out as slots 0…n−1 beside the request, and each attachment
    /// in the response comes back with the descriptor its slot names.
    func testFilesTravelBothWaysBesideTheEnvelope() async throws {
        let service = ApelinService(transport: DescriptorTransport { request, descriptors in
            let call = try! request.decode(ToolHostCallRequest.self)
            XCTAssertEqual(call.attachments.map(\.descriptor.index), [0, 1])
            XCTAssertEqual(call.attachments.map(\.argument), ["binary", nil])
            XCTAssertEqual(descriptors.count, 2)
            let response = ToolHostCallResponse(text: "ok", attachments: [
                ToolHostAttachment(descriptor: DescriptorSlot(index: 1), name: "second", byteCount: 3, sha256: "sha256:b"),
                ToolHostAttachment(descriptor: DescriptorSlot(index: 0), name: "first", mimeType: "text/plain", byteCount: 3, sha256: "sha256:a"),
            ])
            // Answers with the request's own descriptors.
            return (.success(request.requestID, response), [descriptors[0], descriptors[1]])
        })
        let files = [
            ToolHostOutgoingFile(descriptor: pipeEnd(writing: "one"), argument: "binary", name: "a"),
            ToolHostOutgoingFile(descriptor: pipeEnd(writing: "two")),
        ]
        let (response, received) = try await service.toolHostCall(ToolHostCallRequest(sessionID: "s", tool: "t"), files: files)
        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(received.map(\.attachment.name), ["second", "first"])
        XCTAssertEqual(read(received[0].descriptor), "two")
        XCTAssertEqual(read(received[1].descriptor), "one")
    }

    func testAnAttachmentWithNoDescriptorIsAnError() async {
        let service = ApelinService(transport: DescriptorTransport { request, _ in
            let response = ToolHostCallResponse(text: "", attachments: [ToolHostAttachment(descriptor: DescriptorSlot(index: 0), byteCount: 1, sha256: "sha256:x")])
            return (.success(request.requestID, response), [])
        })
        do {
            _ = try await service.toolHostCall(ToolHostCallRequest(sessionID: "s", tool: "t"), files: [])
            XCTFail("expected an error")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .internal)
        } catch {
            XCTFail("\(error)")
        }
    }

    /// The console writes calls by hand, with no attachments field.
    func testACallWithoutAttachmentsDecodes() throws {
        let call = try JSONCoding.decode(ToolHostCallRequest.self, from: Data(#"{"sessionID":"s","tool":"symbols","arguments":{"binary":"/usr/lib/dyld"}}"#.utf8))
        XCTAssertEqual(call.attachments, [])
        XCTAssertEqual(call.arguments.value(at: "binary"), .string("/usr/lib/dyld"))
    }
}
