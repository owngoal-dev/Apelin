import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import Testing

/// A session host in memory: answers each operation from a table and
/// records what it was asked, in order.
final class FakeHost: ApelinTransport, @unchecked Sendable {
    typealias Answer = @Sendable (WireRequest) throws -> (Encodable & Sendable, [OwnedDescriptor])

    private let lock = PthreadLock()
    private var answers: [AppOperation: Answer] = [:]
    private var log: [WireRequest] = []

    func on(_ operation: AppOperation, _ answer: @escaping Answer) {
        lock.withLock { answers[operation] = answer }
    }

    func on(_ operation: AppOperation, reply: some Encodable & Sendable) {
        on(operation) { _ in (reply, []) }
    }

    var requests: [WireRequest] {
        lock.withLock { log }
    }

    func requests<R: OperationRequest>(_: R.Type) -> [R] {
        requests.filter { $0.operation == R.operation }.compactMap { try? $0.decode(R.self) }
    }

    func call(_ request: WireRequest, descriptors _: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        let answer = lock.withLock { () -> Answer? in
            log.append(request)
            return answers[request.operation]
        }
        guard let answer else { return (.failure(request.requestID, .unimplemented(request.operation)), []) }
        do {
            let (value, descriptors) = try answer(request)
            return (.success(request.requestID, AnyEncodable(value)), descriptors)
        } catch let error as ApelinError {
            return (.failure(request.requestID, error), [])
        }
    }
}

struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

/// A finished task's whole history in one batch.
func batch(_ taskID: String, _ events: [(String, ApelinCore.JSONValue?)]) -> TaskEventBatch {
    let numbered = events.enumerated().map { TaskEvent(seq: EventSeq(UInt64($0.offset + 1)), kind: $0.element.0, payload: $0.element.1) }
    let state = numbered.last { $0.kind == TaskEvent.stateKind }?.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)) ?? .running
    return TaskEventBatch(taskID: TaskID(taskID), events: numbered, state: state, lastSeq: numbered.last?.seq ?? .start, finished: state.isTerminal)
}

func stateEvent(_ state: TaskState, _ message: String? = nil) -> (String, ApelinCore.JSONValue?) {
    var payload: [String: ApelinCore.JSONValue] = ["state": .string(state.rawValue)]
    if let message {
        payload["message"] = .string(message)
    }
    return (TaskEvent.stateKind, .object(payload))
}

/// A descriptor holding `data`, from an unlinked temporary file.
func descriptor(holding data: Data) -> OwnedDescriptor {
    let path = NSTemporaryDirectory() + "apelin-agent-worker-\(UUID().uuidString)"
    FileManager.default.createFile(atPath: path, contents: data)
    let fd = open(path, O_RDONLY)
    unlink(path)
    return OwnedDescriptor(adopting: fd)
}

struct Fixture {
    let host = FakeHost()
    let project: ApelinAgent.ProjectIdentity
    let projectURL: URL
    let backend: ChannelHostBackend

    init(manifest: String? = nil) throws {
        project = try ApelinAgent.ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-000000000001", name: ApelinAgent.ProjectName("Hello"))
        projectURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-worker-tests-\(UUID().uuidString)/Hello", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        if let manifest {
            try manifest.write(to: projectURL.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        }
        backend = ChannelHostBackend(service: ApelinService(transport: host), sessionID: "11111111-2222-4333-8444-555555555555", project: project, projectURL: projectURL)
    }

    func context(_ approval: ApprovalEvidence = .relaxed) -> HostCallContext {
        HostCallContext(sessionID: backend.sessionID, project: project, toolCallID: "call-1", approval: approval)
    }

    /// Stands in for `~/Documents/wiki.qaq.apelin`: the project's parent.
    var dataFolder: URL {
        projectURL.deletingLastPathComponent()
    }
}

@Suite("ChannelHostBackend maps every tool onto one host operation")
struct ChannelHostBackendTests {
    @Test
    func `build is buildStart and its task read to the end`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.buildStart, reply: TaskHandle(taskID: TaskID("build-task"), kind: .build))
        try fixture.host.on(.buildAttach, reply: batch("build-task", [
            ("stage", .object(["stage": .string("compile")])),
            ("log", .object(["line": .string("clang Tweak.m")])),
            ("diagnostic", ApelinCore.JSONValue(encoding: ProjectDiagnostic(code: "clang", severity: .warning, message: "unused", file: "Sources/Tweak.m", line: 3))),
            ("artifact", ApelinCore.JSONValue(encoding: ApelinProtocol.BuildArtifact(artifactID: "art-1", digest: "sha256:ab", packageID: "wiki.qaq.hello", version: "0.0.1"))),
            stateEvent(.succeeded),
        ]))

        let response = try await fixture.backend.build(BuildRequest(context: fixture.context(), configuration: .release, buildDescriptionDigest: "sha256:00", bootstrap: "roothide"))

        let start = try #require(fixture.host.requests(BuildStartRequest.self).first)
        #expect(start.projectID == fixture.project.id)
        #expect(start.configuration == .release)
        #expect(start.bootstrap == .roothide)
        #expect(response.succeeded)
        #expect(response.buildID == "build-task")
        #expect(response.artifacts == [ApelinAgent.BuildArtifact(id: "art-1", kind: .package, name: "wiki.qaq.hello_0.0.1.deb", digest: "sha256:ab")])
        #expect(response.diagnostics.first?.severity == .warning)
        #expect(response.diagnostics.first?.line == 3)
        #expect(response.logExcerpt.contains("clang Tweak.m"))
    }

    @Test
    func `a build's findings keep their field, and a schema error says where the schema is`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.buildStart, reply: TaskHandle(taskID: TaskID("build-task"), kind: .build))
        try fixture.host.on(.buildAttach, reply: batch("build-task", [
            ("diagnostic", ApelinCore.JSONValue(encoding: ProjectDiagnostic(
                code: "project.invalid",
                severity: .error,
                message: "unknown member",
                file: "apelin-project.json",
                field: "/configurations/Debug/linkerFlags",
            ))),
            stateEvent(.failed, "the project check failed"),
        ]))
        let response = try await fixture.backend.build(BuildRequest(context: fixture.context(), configuration: .debug, buildDescriptionDigest: "d"))
        #expect(response.diagnostics.map(\.field) == ["/configurations/Debug/linkerFlags", nil])
        let note = try #require(response.diagnostics.last)
        #expect(note.severity == .note && note.message.contains("apelin-project.schema.json (apelin_skill_read)"))
    }

    @Test
    func `a build refused over a project file that does not read names each field and the schema`() async throws {
        let fixture = try Fixture()
        // In Strict mode the host has no description to match.
        fixture.host.on(.buildStart) { _ in
            throw ApelinError(.denied, "approval required: the host could not compute the build description of x, so it cannot tell it matches the template")
        }
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false, diagnostics: [
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "unknown member", file: "apelin-project.json", field: "/configurations/Debug/linkerFlags"),
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "missing optimization", file: "apelin-project.json", field: "/configurations/Release"),
        ]))
        let request = BuildRequest(context: fixture.context(), configuration: .debug, buildDescriptionDigest: "d")
        let refusal = await #expect(throws: ApelinError.self) { _ = try await fixture.backend.build(request) }
        #expect(refusal?.code == .badRequest)
        #expect(refusal?.message.contains("/configurations/Debug/linkerFlags: unknown member; /configurations/Release: missing optimization") == true)
        #expect(refusal?.message.contains("apelin-project.schema.json") == true)

        // A refusal over anything else stands as it came.
        fixture.host.on(.buildStart) { _ in throw ApelinError(.notFound, "toolchain clt-16.4-c is not registered") }
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false, diagnostics: [
            ProjectDiagnostic(code: "environment.device.toolchain", severity: .error, message: "not registered", field: "/environment/toolchain"),
        ]))
        await #expect(throws: ApelinError(.notFound, "toolchain clt-16.4-c is not registered")) {
            _ = try await fixture.backend.build(request)
        }
    }

    @Test
    func `apelin_project_check_distribution counts what stops the build, and says a workspace's package is checked by its build`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(
            passed: false,
            diagnostics: [ProjectDiagnostic(code: "external.build", severity: .error, message: "/external/script is not a regular file", field: "/external")],
            buildSystem: .external,
        ))
        let broken = try await fixture.backend.checkDistribution(DistributionCheckRequest(project: fixture.project, bootstrap: "rootless"))
        #expect(fixture.host.requests(ProjectCheckRequest.self).last?.purpose == .distribution)
        #expect(!broken.ready && broken.issues.map(\.message) == ["/external/script is not a regular file"])
        #expect(broken.note != nil, "a workspace's package is checked when it is built")

        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: true, buildSystem: .external))
        let declared = try await fixture.backend.checkDistribution(DistributionCheckRequest(project: fixture.project))
        #expect(declared.ready && declared.issues.isEmpty && declared.note != nil)

        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: true, diagnostics: [
            ProjectDiagnostic(code: "project.flag.unusual", severity: .warning, message: "unusual flag"),
            ProjectDiagnostic(code: "distribution.package.id.local", severity: .warning, message: "local identifier"),
        ]))
        let described = try await fixture.backend.checkDistribution(DistributionCheckRequest(project: fixture.project))
        #expect(!described.ready && described.issues.map(\.message) == ["local identifier"] && described.note == nil)
    }

    @Test
    func `apelin_project_check_distribution names each issue's field, and where the schema is`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false, diagnostics: [
            ProjectDiagnostic(code: "project.invalid", severity: .error, message: "unknown member", file: "apelin-project.json", field: "/configurations/Debug/linkerFlags"),
        ]))
        let check = try await fixture.backend.checkDistribution(DistributionCheckRequest(project: fixture.project))
        #expect(!check.ready && check.issues.map(\.field) == ["/configurations/Debug/linkerFlags", nil])
        #expect(check.issues.last?.severity == .note && check.issues.last?.message.contains("apelin-project-description") == true)
    }

    @Test
    func `a build that names its APELIN_BUILD_ID reports that id`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.buildStart, reply: TaskHandle(taskID: TaskID("build-task"), kind: .build))
        fixture.host.on(.buildAttach, reply: batch("build-task", [
            ("stage", .object(["stage": .string("compile"), "buildID": .string("B-42")])),
            stateEvent(.failed, "link failed"),
        ]))
        let response = try await fixture.backend.build(BuildRequest(context: fixture.context(), configuration: .debug, buildDescriptionDigest: "d"))
        #expect(response.buildID == "B-42")
        #expect(!response.succeeded)
        #expect(response.logExcerpt.contains("link failed"))
    }

    @Test
    func `install is installPackage with the artifact and its digest`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.installPackage, reply: TaskHandle(taskID: TaskID("install-task"), kind: .install))
        try fixture.host.on(.buildAttach, reply: batch("install-task", [
            ("result", ApelinCore.JSONValue(encoding: InstallResult(installationID: "inst-1", transactionID: "tx-1", packageID: "wiki.qaq.hello", version: "0.0.1"))),
            stateEvent(.succeeded),
        ]))
        let response = try await fixture.backend.install(InstallRequest(context: fixture.context(), artifactID: "art-1", artifactDigest: "sha256:ab", packagingDescriptionDigest: "p"))
        let sent = try #require(fixture.host.requests(InstallPackageRequest.self).first)
        #expect(sent.artifactID == "art-1")
        #expect(sent.digest == "sha256:ab")
        #expect(response.succeeded)
        #expect(response.installationID == "inst-1")
        #expect(response.transactionID == "tx-1")
        #expect(response.conflicts == nil)
    }

    @Test
    func `a refused install names the packages in its way, with the installation to remove`() async throws {
        let fixture = try Fixture()
        let renamed = InstallConflict(
            relation: .file,
            file: "/Library/MobileSubstrate/DynamicLibraries/DockFlip.dylib",
            packageID: "local.apelin.dockflip",
            version: "0.1",
            installationID: "0b6f3c2e-0000-4000-8000-000000000001",
            projectID: "p-1",
        )
        let declared = InstallConflict(relation: .conflicts, packageID: "com.example.old", version: "1.0")
        fixture.host.on(.installPackage, reply: TaskHandle(taskID: TaskID("install-task"), kind: .install))
        try fixture.host.on(.buildAttach, reply: batch("install-task", [
            ("irisin", .object(["seq": .number(1), "kind": .string("failure"), "text": .string("owned")])),
            ("conflict", ApelinCore.JSONValue(encoding: renamed)),
            ("conflict", ApelinCore.JSONValue(encoding: declared)),
            stateEvent(.failed, "…already belongs to local.apelin.dockflip 0.1…"),
        ]))
        let response = try await fixture.backend.install(InstallRequest(context: fixture.context(), artifactID: "art-2", artifactDigest: "sha256:cd", packagingDescriptionDigest: "p"))
        #expect(!response.succeeded)
        #expect(response.installationID == nil)
        #expect(response.conflicts == [renamed, declared])
        #expect(response.message.contains("local.apelin.dockflip"))
    }

    /// The tweak template's filterBundles is a list of bundle IDs: its
    /// default is listed as one, and one given is sent as a JSON array.
    @Test
    func `a list template value is listed and sent as a JSON array`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.extensionList, reply: ExtensionListResponse(extensions: [
            DevelopmentExtension(id: "wiki.qaq.apelin.dev.tweak", version: "0.1.0", kind: .tweak, displayName: "Tweak Development", templates: [
                TemplateSummary(id: "wiki.qaq.apelin.dev.tweak/objc-hook", displayName: "Objective-C Tweak", parameters: [
                    TemplateParameter(name: "filterBundles", kind: "bundleIDList", defaultValue: .array([.string("com.apple.springboard")])),
                    TemplateParameter(name: "mixed", kind: "bundleIDList", defaultValue: .array([.string("a.b"), .number(1)])),
                ]),
            ]),
        ]))
        let templates = try await fixture.backend.projectTemplates().templates
        #expect(templates.first?.parameters.map(\.defaultValue) == [.list(["com.apple.springboard"]), nil])

        fixture.host.on(.projectCreate, reply: ProjectCreateResponse(projectID: "p-1", name: "Settings Tweak", path: "/p"))
        _ = try await fixture.backend.createProject(ProjectCreateToolRequest(
            context: fixture.context(),
            templateID: "wiki.qaq.apelin.dev.tweak/objc-hook",
            name: "Settings Tweak",
            values: ["filterBundles": .list(["com.apple.springboard", "com.apple.Preferences"]), "displayName": .string("X")],
        ))
        let sent = try #require(fixture.host.requests(ProjectCreateRequest.self).first)
        #expect(sent.values == [
            "filterBundles": .array([.string("com.apple.springboard"), .string("com.apple.Preferences")]),
            "displayName": .string("X"),
        ])
    }

    @Test
    func `the installation list is installationList, each project named by its folder`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID":"6f1c5b0e-0000-4000-8000-000000000001"}"#)
        defer { try? FileManager.default.removeItem(at: fixture.dataFolder) }
        let installedAt = Date(timeIntervalSince1970: 1_790_000_000)
        fixture.host.on(.installationList, reply: InstallationListResponse(installations: [
            InstallationSummary(installationID: "inst-2", packageID: "wiki.qaq.hello", version: "0.0.2", projectID: fixture.project.id, buildID: "B-2", installedAt: installedAt, removable: true),
            InstallationSummary(installationID: "inst-1", packageID: "local.apelin.gone", version: "1", projectID: "deleted-project", installedAt: installedAt, removable: false, reason: "local.apelin.gone is now version 2"),
        ]))
        let listed = try await fixture.backend.installations(InstallationListToolRequest(packageID: "wiki.qaq.hello"))
        let sent = try #require(fixture.host.requests(InstallationListRequest.self).first)
        #expect(sent.packageID == "wiki.qaq.hello" && sent.projectID == nil)
        #expect(listed.installations.map(\.project) == ["Hello", nil], "a project still under Projects/ is named by its folder")
        #expect(listed.installations.last?.reason == "local.apelin.gone is now version 2" && listed.installations.last?.removable == false)
        #expect(listed.installations.first?.buildID == "B-2" && !listed.truncated)
    }

    @Test
    func `respring is the host's closed operation`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.respring, reply: Acknowledged())
        let response = try await fixture.backend.respring(ApelinAgent.RespringRequest(context: fixture.context()))
        #expect(response.succeeded)
        #expect(fixture.host.requests.map(\.operation) == [.respring])
    }

    @Test
    func `apelin_package_confirm_loaded starts a load check with the session's project and reads its answer from the final state`() async throws {
        let fixture = try Fixture()
        let answer = ApelinProtocol.ConfirmLoadedResponse(loaded: true, evidence: [
            LoadEvidence(kind: "log", passed: true, detail: "confirmed: Marker logged by pid 55."),
            LoadEvidence(kind: "image", passed: false, detail: "notRead: The image list was not read."),
            LoadEvidence(kind: "filter", passed: true, detail: "confirmed: com.apple.springboard"),
        ])
        fixture.host.on(.confirmLoaded, reply: TaskHandle(taskID: TaskID("confirm-task"), kind: .confirmLoaded))
        try fixture.host.on(.confirmLoadedAttach, reply: batch("confirm-task", [
            ("stage", .object(["stage": .string("listening")])),
            ("stage", .object(["stage": .string("trigger")])),
            (TaskEvent.stateKind, .object(["state": .string("succeeded"), ApelinProtocol.ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer)])),
        ]))
        let response = try await fixture.backend.confirmLoaded(ApelinAgent.ConfirmLoadedRequest(context: fixture.context(), buildID: "B-42", target: "SpringBoard", respring: true))
        let sent = try #require(fixture.host.requests(ApelinProtocol.ConfirmLoadedRequest.self).first)
        #expect(sent.buildID == "B-42")
        #expect(sent.targetID == "SpringBoard")
        #expect(sent.projectID == fixture.project.id)
        #expect(sent.trigger == .respring)
        #expect(sent.imageCheck == nil, "the agent never asks for the image list")
        #expect(fixture.host.requests.map(\.operation) == [.confirmLoaded, .confirmLoadedAttach])
        #expect(response.markerLogged)
        #expect(response.filterMatches == true)
        #expect(response.loaded)
        #expect(response.basis == ApelinAgent.ConfirmLoadedResponse.markerBasis)
        #expect(response.notes == "log: confirmed: Marker logged by pid 55.\nfilter: confirmed: com.apple.springboard", "the image is never read: basis says so once")
    }

    @Test
    func `apelin_package_confirm_loaded answers the host's verdict when the marker is not heard`() async throws {
        let fixture = try Fixture()
        let answer = ApelinProtocol.ConfirmLoadedResponse(loaded: false, evidence: [
            LoadEvidence(kind: "log", passed: false, detail: "absent: No line containing \"ApelinLoaded B-42\" from SpringBoard in 30 s."),
            LoadEvidence(kind: "image", passed: false, detail: "notRead: The image list was not read."),
            LoadEvidence(kind: "filter", passed: false, detail: "absent: com.apple.Preferences only"),
            LoadEvidence(kind: "trigger", passed: false, detail: "the respring failed"),
        ])
        fixture.host.on(.confirmLoaded, reply: TaskHandle(taskID: TaskID("confirm-task"), kind: .confirmLoaded))
        try fixture.host.on(.confirmLoadedAttach, reply: batch("confirm-task", [
            (TaskEvent.stateKind, .object(["state": .string("succeeded"), ApelinProtocol.ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer)])),
        ]))
        let response = try await fixture.backend.confirmLoaded(ApelinAgent.ConfirmLoadedRequest(context: fixture.context(), buildID: "B-42", target: "SpringBoard", respring: true))
        #expect(!response.loaded)
        #expect(!response.markerLogged)
        #expect(response.filterMatches == false)
        #expect(response.logEvidence == ["absent: No line containing \"ApelinLoaded B-42\" from SpringBoard in 30 s."])
        let kinds = response.notes.split(separator: "\n").map { line in String(line.prefix { $0 != ":" }) }
        #expect(kinds == ["log", "filter", "trigger"], "the trigger's failure stays; the image is never read")
    }

    @Test
    func `apelin_package_confirm_loaded without respring sends no trigger; a check that ended without an answer throws`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.confirmLoaded, reply: TaskHandle(taskID: TaskID("confirm-task"), kind: .confirmLoaded))
        fixture.host.on(.confirmLoadedAttach, reply: batch("confirm-task", [stateEvent(.failed, "apelin-diagnostics exited")]))
        await #expect(throws: ApelinError.self) {
            _ = try await fixture.backend.confirmLoaded(ApelinAgent.ConfirmLoadedRequest(context: fixture.context(), buildID: "B-42", target: "SpringBoard"))
        }
        #expect(fixture.host.requests(ApelinProtocol.ConfirmLoadedRequest.self).first?.trigger == nil)
        #expect(fixture.host.requests(ApelinProtocol.ConfirmLoadedRequest.self).first?.logWindowSeconds == nil, "the host's default window")
    }

    @Test
    func `apelin_package_confirm_loaded listens as long as asked and says the target never ran`() async throws {
        let fixture = try Fixture()
        let answer = ApelinProtocol.ConfirmLoadedResponse(loaded: false, evidence: [
            LoadEvidence(kind: "log", passed: false, detail: "absent: No line containing \"ApelinLoaded B-42\" from dtremotedisplayd in 180 s."),
            LoadEvidence(kind: "image", passed: false, detail: "notRead: The image list was not read."),
            LoadEvidence(kind: "filter", passed: true, detail: "confirmed: Executables names dtremotedisplayd."),
            LoadEvidence(kind: "process", passed: false, detail: "absent: No process named dtremotedisplayd ran while the check looked."),
        ], process: LoadTargetProcess(runningAtStart: [], startedDuring: [], watchedSeconds: 180.2))
        fixture.host.on(.confirmLoaded, reply: TaskHandle(taskID: TaskID("confirm-task"), kind: .confirmLoaded))
        try fixture.host.on(.confirmLoadedAttach, reply: batch("confirm-task", [
            (TaskEvent.stateKind, .object(["state": .string("succeeded"), ApelinProtocol.ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer)])),
        ]))
        let response = try await fixture.backend.confirmLoaded(ApelinAgent.ConfirmLoadedRequest(context: fixture.context(), buildID: "B-42", target: "dtremotedisplayd", waitSeconds: 180))
        #expect(fixture.host.requests(ApelinProtocol.ConfirmLoadedRequest.self).first?.logWindowSeconds == 180)
        #expect(!response.loaded)
        #expect(response.targetProcess?.hasPrefix("dtremotedisplayd never ran while the call listened (180 s)") == true, "\(response.targetProcess ?? "nil")")
        #expect(response.notes.contains("process: absent: No process named dtremotedisplayd ran"))
    }

    @Test
    func `the target process is told plainly: never ran, ran before the call, started during it`() {
        func sentence(loaded: Bool = false, _ start: [Int32], _ started: [Int32]) -> String? {
            ChannelHostBackend.targetProcess(
                "dtremotedisplayd",
                loaded: loaded,
                process: LoadTargetProcess(runningAtStart: start, startedDuring: started, watchedSeconds: 30),
            )
        }
        #expect(ChannelHostBackend.targetProcess("dtremotedisplayd", loaded: false, process: nil) == nil, "a process list the host could not read says nothing")
        #expect(sentence([], [])?.contains("never ran while the call listened (30 s)") == true)
        #expect(sentence([], [])?.contains("call again with wait_seconds") == true)
        #expect(sentence([55], [])?.contains("was already running when the call began (pid 55) and did not start again") == true)
        #expect(sentence([55], [])?.contains("restart it while the call listens") == true)
        #expect(sentence([], [812]) == "dtremotedisplayd started while the call listened (pid 812) and logged no marker: the tweak did not load into it, or no longer logs its marker.")
        #expect(sentence(loaded: true, [55], [812, 900]) == "dtremotedisplayd started while the call listened (pids 812, 900) and logged the marker.")
    }

    /// Stop ends the call, and the listen of minutes it was waiting on with
    /// it, as it does a build.
    @Test
    func `a stopped apelin_package_confirm_loaded stops its load check`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.confirmLoaded, reply: TaskHandle(taskID: TaskID("confirm-task"), kind: .confirmLoaded))
        fixture.host.on(.confirmLoadedAttach) { _ in
            Thread.sleep(forTimeInterval: 0.01)
            return (TaskEventBatch(taskID: TaskID("confirm-task"), events: [], state: .running, lastSeq: .start, finished: false), [])
        }
        fixture.host.on(.confirmLoadedCancel, reply: Acknowledged())
        let backend = fixture.backend
        let context = fixture.context()
        let call = Task {
            try await backend.confirmLoaded(ApelinAgent.ConfirmLoadedRequest(context: context, buildID: "B-42", target: "dtremotedisplayd", waitSeconds: 180))
        }
        try await Task.sleep(for: .milliseconds(200))
        call.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await call.value
        }
        for _ in 0 ..< 200 where fixture.host.requests(ConfirmLoadedCancelRequest.self).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.host.requests(ConfirmLoadedCancelRequest.self).map(\.taskID) == [TaskID("confirm-task")])
    }

    @Test
    func `apelin_log_read opens a bounded stream and reads it to its end`() async throws {
        let fixture = try Fixture()
        let entry: ApelinCore.JSONValue = .object([
            "time": .string("2026-10-17T10:00:00Z"), "process": .string("SpringBoard"),
            "subsystem": .string("wiki.qaq.hello"), "category": .string("tweak"),
            "level": .string("default"), "message": .string("ApelinLoaded B-42 in SpringBoard"),
        ])
        fixture.host.on(.logStream) { request in
            let poll = try request.decode(LogStreamRequest.self)
            if poll.stream == nil {
                return (TaskEventBatch(taskID: TaskID("logs"), events: [TaskEvent(seq: EventSeq(1), kind: "log", payload: entry)], state: .running, lastSeq: EventSeq(1), finished: false), [])
            }
            return (TaskEventBatch(taskID: TaskID("logs"), events: [
                TaskEvent(seq: EventSeq(2), kind: "log", payload: entry),
                TaskEvent(seq: EventSeq(3), kind: TaskEvent.stateKind, payload: .object(["state": .string("succeeded")])),
            ], state: .succeeded, lastSeq: EventSeq(3), finished: true), [])
        }
        let response = try await fixture.backend.readLogs(ReadLogsRequest(context: fixture.context(), process: "SpringBoard", subsystem: "wiki.qaq.hello", listenSeconds: 300, limit: 1))
        let open = try #require(fixture.host.requests(LogStreamRequest.self).first)
        #expect(open.filter?.subsystem == "wiki.qaq.hello")
        #expect(open.filter?.process == "SpringBoard")
        #expect(open.filter?.windowSeconds == Double(ReadLogsRequest.maximumListenSeconds), "a listen is cut to its most")
        #expect(response.entries.count == 1)
        #expect(response.truncated)
        #expect(response.entries.first?.message.hasPrefix("ApelinLoaded") == true)
    }

    @Test
    func `apelin_crash_read reads the descriptor crashOpen hands back, bounded`() async throws {
        let fixture = try Fixture()
        let text = Data(String(repeating: "x", count: 100).utf8)
        fixture.host.on(.crashOpen) { _ in (CrashOpenResponse(descriptor: DescriptorSlot(index: 0), size: 100), [descriptor(holding: text)]) }
        let response = try await fixture.backend.readCrash(ReadCrashRequest(context: fixture.context(), reportID: "SpringBoard-2026-10-17-100000.ips", maxBytes: 40))
        #expect(response.text.count == 40)
        #expect(response.truncated)
        #expect(fixture.host.requests(CrashOpenRequest.self).first?.id == "SpringBoard-2026-10-17-100000.ips")
    }

    @Test
    func `apelin_crash_symbolicate asks the diagnostics worker with the project`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.crashSymbolicate, reply: CrashSymbolicateResponse(id: "r.ips", process: "SpringBoard", matchedImageUUIDs: ["UUID-1"], crashedThread: [
            ApelinProtocol.SymbolicatedFrame(index: 0, image: "Hello.dylib", address: "0x1000", symbol: "HookedDidFinishLaunching", file: "Tweak.m", line: 30),
        ], suspects: ["Hello.dylib"]))
        let response = try await fixture.backend.symbolicateCrash(SymbolicateCrashRequest(context: fixture.context(), reportID: "r.ips", buildID: nil))
        #expect(fixture.host.requests(CrashSymbolicateRequest.self).first?.projectID == fixture.project.id)
        #expect(response.matchedImageUUID == "UUID-1")
        #expect(response.crashedThread.first?.symbol == "HookedDidFinishLaunching")
        #expect(response.suspects == ["Hello.dylib"])
    }

    @Test
    func `apelin_screen_capture reads the image from the reply's descriptor`() async throws {
        let fixture = try Fixture()
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        fixture.host.on(.captureScreen) { _ in (ApelinProtocol.CaptureScreenResponse(image: DescriptorSlot(index: 0), width: 10, height: 20), [descriptor(holding: jpeg)]) }
        let response = try await fixture.backend.captureScreen(ApelinAgent.CaptureScreenRequest(context: fixture.context(), targetID: nil))
        #expect(response.imageData == jpeg)
        #expect(response.mimeType == "image/jpeg")
        #expect(response.width == 10)
    }

    @Test
    func `the UI tree is one root and its elements; tapping one goes by identifier or text`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.readUITree, reply: ReadUITreeResponse(tree: .object([
            "pid": .number(42),
            "elements": .array([
                .object(["identifier": .string("ok-button"), "label": .string("OK"), "role": .string("button"), "frame": .object(["x": .number(1), "y": .number(2), "width": .number(3), "height": .number(4)])]),
                .object(["identifier": .string(""), "label": .string("Cancel"), "role": .string("button")]),
            ]),
        ])))
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse())
        let tree = try await fixture.backend.readUITree(ApelinAgent.ReadUITreeRequest(context: fixture.context(), targetID: nil, maxDepth: 4))
        #expect(tree.root.children.map(\.id) == ["ok-button", "text:Cancel"])
        #expect(tree.root.children.first?.frame == [1, 2, 3, 4])

        _ = try await fixture.backend.uiAction(ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .tapElement(id: "text:Cancel")))
        _ = try await fixture.backend.uiAction(ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .tapElement(id: "ok-button")))
        let actions = fixture.host.requests(ApelinProtocol.UIActionRequest.self).map(\.action)
        #expect(actions == [.tapElement(text: "Cancel", identifier: nil), .tapElement(text: nil, identifier: "ok-button")])
    }

    @Test
    func `a wake says what it left, and a device still locked is the user's to unlock`() async throws {
        let fixture = try Fixture()
        let press = ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .pressButton("wake"))
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: true, screenOff: false))
        let locked = try await fixture.backend.uiAction(press)
        #expect(locked.performed)
        #expect(locked.message.contains("still locked"))
        #expect(locked.message.contains("ask the user to unlock the device"))
        #expect(locked.message.contains("never ask for or type the passcode"))
        #expect(fixture.host.requests(ApelinProtocol.UIActionRequest.self).map(\.action) == [.press(button: "wake")])

        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: false, screenOff: false))
        #expect(try await fixture.backend.uiAction(press).message == "The screen is on and the device is unlocked.")
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: true, screenOff: true))
        #expect(try await fixture.backend.uiAction(press).message.hasPrefix("The screen is still off."))
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse())
        let tap = ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .tap(x: 1, y: 2))
        #expect(try await fixture.backend.uiAction(tap).message == "", "only a wake answers the lock state")
    }

    @Test
    func `an unlock says what it left, and a lock screen that stays is the user's`() async throws {
        let fixture = try Fixture()
        let press = ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .pressButton("unlock"))
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: false, screenOff: false))
        #expect(try await fixture.backend.uiAction(press).message == "The device is unlocked and its screen is on.")
        #expect(fixture.host.requests(ApelinProtocol.UIActionRequest.self).map(\.action) == [.press(button: "unlock")])
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: true, screenOff: false))
        let stayed = try await fixture.backend.uiAction(press).message
        #expect(stayed.contains("lock screen is still up"))
        #expect(stayed.contains("never ask for or type the passcode"))
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: true, screenOff: true))
        #expect(try await fixture.backend.uiAction(press).message.hasPrefix("The screen is still off. Press unlock once more"))
    }

    /// The way the unlock went, as the model is to report it: a device
    /// without a passcode was not unlocked with the saved one.
    @Test
    func `an unlock says the way it went, and the passcode only where it was used`() async throws {
        let fixture = try Fixture()
        let press = ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .pressButton("unlock"))
        let messages: [(DeviceUnlockPath, String)] = [
            (.nothing, "The device was already unlocked with its screen on; nothing was pressed."),
            (.wake, "The device was already unlocked; its screen was off, so it was woken."),
            (.lockScreen, "No passcode was needed: the device was woken, taken past its lock screen and to the Home Screen."),
            (.passcode, "The device was unlocked with the passcode saved in Apelin's Settings, taken past its lock screen and to the Home Screen."),
        ]
        for (path, message) in messages {
            fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(locked: false, screenOff: false, unlockedBy: path))
            let said = try await fixture.backend.uiAction(press).message
            #expect(said == message)
            #expect(path == .passcode || !said.contains("passcode saved"), "\(path)")
        }
    }

    @Test
    func `a swipe keeps its duration, and typed text answers what the fields hold`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse())
        _ = try await fixture.backend.uiAction(ApelinAgent.UIActionRequest(
            context: fixture.context(),
            targetID: nil,
            action: .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMilliseconds: 1200),
        ))
        #expect(fixture.host.requests(ApelinProtocol.UIActionRequest.self).map(\.action) == [
            .swipe(fromX: 1, fromY: 2, toX: 3, toY: 4, durationMilliseconds: 1200),
        ])

        fixture.host.on(.uiAction, reply: ApelinProtocol.UIActionResponse(typedTextMatches: false, fieldValues: ["Hello wrd"]))
        let typed = try await fixture.backend.uiAction(ApelinAgent.UIActionRequest(context: fixture.context(), targetID: nil, action: .typeText("Hello world")))
        #expect(typed.typedTextMatches == false)
        #expect(typed.fieldValues == ["Hello wrd"])
        #expect(typed.message.contains("fieldValues is what they hold now"))

        let untouched = ChannelHostBackend.readBackMessage(ApelinProtocol.UIActionResponse(typedTextMatches: false, fieldValues: []))
        #expect(untouched.hasPrefix("No field changed"))
        #expect(ChannelHostBackend.readBackMessage(ApelinProtocol.UIActionResponse(typedTextMatches: true, fieldValues: ["Hello world"])).isEmpty)
        #expect(ChannelHostBackend.readBackMessage(ApelinProtocol.UIActionResponse()).isEmpty, "a tap says nothing")
    }

    @Test
    func `shell_run is agentRunCode: a shell line becomes an sh script, the evidence is passed on`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentRunCode, reply: AgentRunCodeResponse(exitCode: 0, stdout: "ok", stderr: "", durationMilliseconds: 5))
        let response = try await fixture.backend.runCode(RunCodeRequest(
            context: fixture.context(.user(requestID: "approval-7", fingerprint: "f")),
            invocation: .shell("ls | wc -l"),
            workingDirectory: "Sources",
            timeoutSeconds: 30,
        ))
        let sent = try #require(fixture.host.requests(AgentRunCodeRequest.self).first)
        #expect(sent.sessionID == fixture.backend.sessionID)
        #expect(sent.spec == .script(interpreter: "sh", source: "ls | wc -l"))
        #expect(sent.workingDirectory == "Sources")
        #expect(sent.timeoutSeconds == 30)
        #expect(sent.approval == .user(approvalID: "approval-7"))
        #expect(response.stdout == "ok")

        _ = try await fixture.backend.runCode(RunCodeRequest(context: fixture.context(.preset("ls")), invocation: .argv(["ls", "-l"]), workingDirectory: ".", timeoutSeconds: 5))
        let second = try #require(fixture.host.requests(AgentRunCodeRequest.self).last)
        #expect(second.spec == .argv(["ls", "-l"]))
        #expect(second.approval == .preset("ls"))

        // A call the user approved for the session is sent as one.
        let sessionEvidence = ApprovalEvidence.user(requestID: ApprovalEvidence.sessionRequestID, fingerprint: "f")
        _ = try await fixture.backend.runCode(RunCodeRequest(context: fixture.context(sessionEvidence), invocation: .argv(["make"]), workingDirectory: ".", timeoutSeconds: 5))
        #expect(fixture.host.requests(AgentRunCodeRequest.self).last?.approval == .session)
    }

    @Test
    func `a preset the host does not count comes back as HostRefusedPresetError, so the runner asks`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.agentRunCode) { _ in throw RunCodeApproval.presetRefusal }
        await #expect(throws: HostRefusedPresetError.self) {
            _ = try await fixture.backend.runCode(RunCodeRequest(context: fixture.context(.preset("cat")), invocation: .argv(["cat", "x"]), workingDirectory: ".", timeoutSeconds: 5))
        }
        // Any other refusal is the host's answer as it is.
        fixture.host.on(.agentRunCode) { _ in throw ApelinError(.denied, "this session is in Confirm mode") }
        await #expect(throws: ApelinError.self) {
            _ = try await fixture.backend.runCode(RunCodeRequest(context: fixture.context(.preset("cat")), invocation: .argv(["cat", "x"]), workingDirectory: ".", timeoutSeconds: 5))
        }
    }

    @Test
    func `the host's preset refusal is known by its reason, across a real channel, whatever its message says`() async throws {
        let (local, remote) = try WorkerChannel.makePair()
        let host = WorkerChannel(adopting: local)
        let worker = WorkerChannel(adopting: remote)
        defer { host.close(); worker.close() }
        let answer = PthreadLock()
        nonisolated(unsafe) var refusal = ApelinError(.denied, "reworded for people", reason: .notAPreset)
        host.onRequest { request in
            (.failure(request.request.requestID, answer.withLock { refusal }), [])
        }
        host.start()
        worker.start()
        let fixture = try Fixture()
        let backend = ChannelHostBackend(
            service: ApelinService(transport: ChannelTransport(channel: worker)),
            sessionID: fixture.backend.sessionID,
            project: fixture.project,
            projectURL: fixture.projectURL,
        )
        let request = RunCodeRequest(
            context: fixture.context(.preset("cat")),
            invocation: .argv(["cat", "x"]),
            workingDirectory: ".",
            timeoutSeconds: 5,
        )
        await #expect(throws: HostRefusedPresetError.self) { _ = try await backend.runCode(request) }

        // The old message without the reason is the host's answer as it is.
        answer.withLock { refusal = ApelinError(.denied, RunCodeApproval.presetRefusal.message) }
        await #expect(throws: ApelinError.self) { _ = try await backend.runCode(request) }
    }

    @Test
    func `the app's approval scope reaches the session's gate`() {
        #expect(WorkerState.decision(AgentApproveRequest(sessionID: "s", approvalID: "a", decision: .approve)) == .approve(.once))
        #expect(WorkerState.decision(AgentApproveRequest(sessionID: "s", approvalID: "a", decision: .approve, scope: .once)) == .approve(.once))
        #expect(WorkerState.decision(AgentApproveRequest(sessionID: "s", approvalID: "a", decision: .approve, scope: .session)) == .approve(.session))
        #expect(WorkerState.decision(AgentApproveRequest(sessionID: "s", approvalID: "a", decision: .deny, scope: .session)) == .deny(reason: "denied in Apelin"))
    }

    @Test
    func `the framework tools read the SDK the project is pinned to`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID": "x", "environment": {"sdk": {"id": "iPhoneOS16.5-bbbbbbbb", "digest": "sha256:00"}}}"#)
        fixture.host.on(.sdkList, reply: SDKListResponse(sdks: [
            SDKRecord(id: "iPhoneOS17.0-aaaaaaaa", canonicalName: "iphoneos17.0", version: "17.0", path: "/sdk/17"),
            SDKRecord(id: "iPhoneOS16.5-bbbbbbbb", canonicalName: "iphoneos16.5", version: "16.5", path: "/sdk/16.5"),
        ]))
        let pinned = try await fixture.backend.registeredSDK(RegisteredSDKRequest(sdkID: nil, project: fixture.project))
        #expect(pinned.rootPath == "/sdk/16.5")
        let named = try await fixture.backend.registeredSDK(RegisteredSDKRequest(sdkID: "iPhoneOS17.0-aaaaaaaa", project: fixture.project))
        #expect(named.version == "17.0")
        await #expect(throws: ApelinError.self) {
            _ = try await fixture.backend.registeredSDK(RegisteredSDKRequest(sdkID: "nope", project: fixture.project))
        }
    }

    @Test
    func `a host refusal reaches the tool as the host's error`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.respring) { _ in throw ApelinError(.denied, "not now") }
        await #expect(throws: ApelinError(.denied, "not now")) {
            _ = try await fixture.backend.respring(ApelinAgent.RespringRequest(context: fixture.context()))
        }
    }

    @Test
    func `Confirm reads the host's ledger: the digest apelin-build computed, then approvalDigestState`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID": "x", "build": {"steps": []}}"#)
        let template = "sha256:" + String(repeating: "a", count: 64)
        let changed = "sha256:" + String(repeating: "b", count: 64)
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: true, descriptionDigests: DescriptionDigests(build: template, packaging: changed)))
        fixture.host.on(.approvalDigestState) { request in
            let query = try request.decode(ApprovalDigestStateRequest.self)
            let baseline: ApprovalBaseline = query.digest == template ? .matchesTemplate : .changed
            return (ApprovalDigestStateResponse(baseline: baseline, templateDigest: template, lastApprovedDigest: nil), [])
        }
        let ledger = HostDigestLedger(service: fixture.backend.service, projectURL: fixture.projectURL, dataFolder: fixture.dataFolder)
        let build = try await ledger.state(of: .build, for: fixture.project)
        #expect(build == DescriptionState(digest: template, baseline: .matchesTemplate))
        let asked = try #require(fixture.host.requests(ApprovalDigestStateRequest.self).first)
        #expect(asked.projectID == fixture.project.id)
        #expect(asked.kind == .build)
        let packaging = try await ledger.state(of: .packaging, for: fixture.project)
        #expect(packaging.digest == changed)
        if case .changed = packaging.baseline {} else {
            Issue.record("a changed packaging digest asks")
        }
    }

    @Test
    func `a workspace's package is judged by the packaging digest its build recorded`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID": "x", "kind": "workspace", "buildSystem": "external"}"#)
        let recorded = "sha256:" + String(repeating: "c", count: 64)
        fixture.host.on(.approvalDigestState) { request in
            let query = try request.decode(ApprovalDigestStateRequest.self)
            return (ApprovalDigestStateResponse(baseline: query.digest == recorded ? .approved : .changed, templateDigest: nil, lastApprovedDigest: nil), [])
        }
        let artifacts = fixture.dataFolder.appendingPathComponent("Builds/artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let record = #"{"projectID": "\#(fixture.project.id)", "packagingDigest": "\#(recorded)"}"#
        try Data(record.utf8).write(to: artifacts.appendingPathComponent("B-1.json"))
        try Data(#"{"projectID": "other", "packagingDigest": "\#(recorded)"}"#.utf8).write(to: artifacts.appendingPathComponent("B-2.json"))
        let ledger = HostDigestLedger(service: fixture.backend.service, projectURL: fixture.projectURL, dataFolder: fixture.dataFolder)

        #expect(try await ledger.packagingState(ofArtifact: "B-1", for: fixture.project) == DescriptionState(digest: recorded, baseline: .approved))
        let asked = try #require(fixture.host.requests(ApprovalDigestStateRequest.self).last)
        #expect(asked.kind == .packaging && asked.digest == recorded)
        #expect(try await ledger.packagingState(ofArtifact: "B-2", for: fixture.project) == nil, "another project's package")
        #expect(try await ledger.packagingState(ofArtifact: "B-3", for: fixture.project) == nil, "no record")
        #expect(try await ledger.packagingState(ofArtifact: "../B-1", for: fixture.project) == nil, "an id is a name, never a path")
    }

    @Test
    func `without a digest from apelin-build the agent's own stands in, and asks`() async throws {
        let fixture = try Fixture(manifest: #"{"projectID": "x", "build": {"steps": []}}"#)
        fixture.host.on(.projectCheck, reply: ProjectCheckResponse(passed: false))
        let ledger = HostDigestLedger(service: fixture.backend.service, projectURL: fixture.projectURL, dataFolder: fixture.dataFolder)
        let state = try await ledger.state(of: .build, for: fixture.project)
        #expect(try state.digest == (HostDigestLedger.digest(of: .build, projectURL: fixture.projectURL)))
        if case .changed = state.baseline {} else {
            Issue.record("an unknown digest asks")
        }
    }

    @Test
    func `an artifact's build id and file name reach the agent`() async throws {
        let fixture = try Fixture()
        fixture.host.on(.buildStart, reply: TaskHandle(taskID: TaskID("build-task"), kind: .build))
        try fixture.host.on(.buildAttach, reply: batch("build-task", [
            ("artifact", ApelinCore.JSONValue(encoding: ApelinProtocol.BuildArtifact(
                artifactID: "art-1", digest: "sha256:ab", packageID: "wiki.qaq.hello", version: "0.0.1",
                buildID: "B-7", bootstrap: "rootless", packagingDigest: "sha256:cd",
                path: "/var/mobile/Documents/wiki.qaq.apelin/Builds/p/B-7/wiki.qaq.hello_0.0.1_iphoneos-arm64.deb", projectID: "p",
            ))),
            stateEvent(.succeeded),
        ]))
        let response = try await fixture.backend.build(BuildRequest(context: fixture.context(), configuration: .debug, buildDescriptionDigest: "d"))
        #expect(response.buildID == "B-7")
        #expect(response.artifacts.first?.name == "wiki.qaq.hello_0.0.1_iphoneos-arm64.deb")
    }
}
