import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation

/// What apelin-build serves (Workers/Build/main.swift is one call to this):
/// `extensionList`, `projectCreate`, `projectCheck`, `projectRename` and
/// `projectDelete` answered directly;
/// `buildStart` accepted, then run on its own thread as the task the host
/// registered, every stage, log line, diagnostic and the artifact an event,
/// ending in a `state` event that also carries the artifact's ID and digest
/// (so a console script reads them from `lastEvent`). `buildCancel` reaches
/// `cancel(_:)` and kills the build's tools. A `buildStart` the host sends
/// again after it restarted (`resumed`) keeps its build ID and starts over:
/// the artifact record and folder the lost run left are removed first.
public final class BuildWorker: @unchecked Sendable {
    private static let emptyWorkspaceTemplateID = "wiki.qaq.apelin.workspace/empty"

    public let installRoot: String
    public let home: String
    public let registry: EnvironmentRegistry
    private let lock = NSLock()
    private var running: [TaskID: BuildCancellation] = [:]

    /// Where extensions are scanned; the install root's development folder unless a test says otherwise.
    public let extensionDirectory: URL

    public init(
        installRoot: String,
        home: String,
        registry: EnvironmentRegistry? = nil,
        extensionDirectory: URL? = nil,
    ) {
        self.extensionDirectory = extensionDirectory ?? ExtensionCatalog.directory(installRoot: installRoot)
        self.installRoot = installRoot
        self.home = home
        self.registry = registry ?? EnvironmentStores(dataFolder: DataFolder(home: home))
    }

    public convenience init(assignment: WorkerAssignment) {
        self.init(installRoot: assignment.installRoot, home: assignment.home)
    }

    public var dataFolder: DataFolder {
        DataFolder(home: home)
    }

    public var store: ProjectStore {
        ProjectStore(dataFolder: dataFolder)
    }

    public var catalog: ExtensionCatalog {
        ExtensionCatalog(directory: extensionDirectory)
    }

    /// Emits one event of a task.
    public typealias Emit = @Sendable (TaskID, String, JSONValue?) -> Void

    public func handle(_ request: ChannelRequest, emit: @escaping Emit) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .extensionList:
            return await WorkerMain.serve(ExtensionListRequest.self, request) { _ in extensionList() }
        case .projectCreate:
            return await WorkerMain.serve(ProjectCreateRequest.self, request) { try projectCreate($0) }
        case .projectCheck:
            return await WorkerMain.serve(ProjectCheckRequest.self, request) { try projectCheck($0) }
        case .projectRename:
            return await WorkerMain.serve(ProjectRenameRequest.self, request) {
                try ProjectMetadata.rename($0, in: dataFolder)
            }
        case .projectDelete:
            return await WorkerMain.serve(ProjectDeleteRequest.self, request) {
                try ProjectDeletion.delete($0, in: dataFolder)
            }
        case .buildStart:
            guard let taskID = request.taskID else {
                return (
                    .failure(
                        request.request.requestID,
                        ApelinError(.badRequest, "buildStart reaches apelin-build only as a task"),
                    ),
                    [],
                )
            }
            return await WorkerMain.serve(BuildStartRequest.self, request) { start in
                try buildStart(start, taskID: taskID, resumed: request.resumed, emit: emit)
                return TaskHandle(taskID: taskID, kind: .build)
            }
        default:
            return WorkerMain.unimplemented(request)
        }
    }

    public func cancel(_ taskID: TaskID) {
        lock.lock()
        let cancellation = running[taskID]
        lock.unlock()
        cancellation?.cancel()
    }

    /// The host closed the channel: kill every build's tools before the
    /// worker exits, so none of them writes into a folder a resumed build
    /// is starting over in.
    @objc public dynamic func killAll() {
        lock.lock()
        let all = Array(running.values)
        lock.unlock()
        all.forEach { $0.kill() }
    }

    // MARK: Extensions and projects

    public func extensionList() -> ExtensionListResponse {
        ExtensionListResponse(
            extensions: [
                DevelopmentExtension(
                    id: "wiki.qaq.apelin.workspace",
                    version: "1",
                    kind: .workspace,
                    displayName: "Workspace",
                    templates: [
                        TemplateSummary(
                            id: Self.emptyWorkspaceTemplateID,
                            displayName: "Empty",
                            summary: "An empty workspace. No SDK or toolchain is required.",
                            byteCount: 0,
                        ),
                    ],
                ),
            ] + catalog.extensions.map { found in
                guard let manifest = found.manifest else {
                    return DevelopmentExtension(
                        id: found.folderName,
                        version: "",
                        kind: Self.guessKind(found.folderName),
                        displayName: found.folderName,
                        problems: found.problems,
                    )
                }
                return DevelopmentExtension(
                    id: manifest.id,
                    version: manifest.version,
                    kind: Self.kind(manifest.kind),
                    displayName: manifest.displayName,
                    templates: manifest.templates.map { template in
                        TemplateSummary(
                            id: "\(manifest.id)/\(template.id)",
                            displayName: template.displayName,
                            summary: template.summary,
                            byteCount: found.isUsable ? Self.templateByteCount(template, root: found.root) : nil,
                            parameters: template.parameters.map { parameter in
                                TemplateParameter(
                                    name: parameter.name,
                                    kind: parameter.type,
                                    summary: parameter.help ?? parameter.label,
                                    defaultValue: parameter.default?.value.jsonValue,
                                )
                            },
                        )
                    },
                    problems: found.problems,
                )
            },
        )
    }

    private static func templateByteCount(_ template: ExtensionManifest.Template, root: URL) -> Int64? {
        let directory = root.appendingPathComponent(template.directory, isDirectory: true)
        return try? template.files.reduce(Int64(0)) { total, file in
            try total + Int64(ProjectFiles.read(file.path, in: directory).count)
        }
    }

    static func kind(_ kind: ProjectKind) -> DevelopmentExtensionKind {
        switch kind {
        case .app: .app
        case .tweak: .tweak
        case .cli: .commandLineTool
        case .preferences: .preferenceBundle
        }
    }

    /// For an extension whose manifest did not read, from the folder name
    /// the four packages use; only to file it in the list.
    static func guessKind(_ name: String) -> DevelopmentExtensionKind {
        if name.hasSuffix(".tweak") {
            return .tweak
        }
        if name.hasSuffix(".cli") {
            return .commandLineTool
        }
        if name.hasSuffix(".preferences") {
            return .preferenceBundle
        }
        return .app
    }

    public func projectCreate(_ request: ProjectCreateRequest) throws -> ProjectCreateResponse {
        if request.templateID == Self.emptyWorkspaceTemplateID {
            return try store.createEmpty(name: request.name, automaticallyName: request.automaticallyName == true)
        }
        let values = request.values.mapValues(JSONDocument.init)
        let created = try store.create(
            templateID: request.templateID,
            name: request.name,
            values: values,
            catalog: catalog,
            registry: registry,
            automaticallyName: request.automaticallyName == true,
        )
        return ProjectCreateResponse(
            projectID: created.projectID,
            name: created.name,
            path: created.root.path,
            baseline: created.baseline,
        )
    }

    /// With `environment`, the check a switch to those registered
    /// components would get, nothing written; a component that is not
    /// registered is `notFound`. A project file that does not read has no
    /// binding to switch: its check answers, field by field, with none.
    public func projectCheck(_ request: ProjectCheckRequest) throws -> ProjectCheckResponse {
        if let (_, root) = try? store.root(of: request.projectID), let manifest = Workspace.manifest(at: root) {
            return Self.workspaceCheck(manifest, root: root)
        }
        let check = ProjectCheck(store: store, catalog: catalog, registry: registry, installRoot: installRoot)
        var candidate: ProjectDocument.EnvironmentBinding?
        if let choice = request.environment, let current = try? store.locate(request.projectID).project.environment {
            candidate = try check.binding(choice, replacing: current)
        }
        let result = check.run(projectID: request.projectID, environment: candidate)
        var diagnostics = result.diagnostics
        if request.purpose == .distribution {
            diagnostics += DistributionCheck(store: store, catalog: catalog).run(
                projectID: request.projectID,
                bootstrap: request.bootstrap.flatMap { Bootstrap(rawValue: $0.rawValue) },
            )
        }
        return ProjectCheckResponse(
            passed: result.passed,
            diagnostics: diagnostics,
            descriptionDigests: result.digests.map {
                DescriptionDigests(build: $0.build.digest, packaging: $0.packaging.digest)
            },
            environment: result.project.map {
                ProjectEnvironmentBinding(
                    toolchain: ProjectComponentBinding(id: $0.environment.toolchain.id, digest: $0.environment.toolchain.digest),
                    sdk: ProjectComponentBinding(id: $0.environment.sdk.id, digest: $0.environment.sdk.digest),
                )
            },
        )
    }

    /// A workspace has no description to check and no digests: it passes
    /// when its `external` declaration reads and names a script in it.
    static func workspaceCheck(_ manifest: JSONDocument, root: URL) -> ProjectCheckResponse {
        let problem: String?
        do {
            problem = try ExternalBuildDeclaration.read(manifest, root: root) == nil
                ? "This workspace declares no build: add \"external\": {\"script\": \"<a project file>\"} to its apelin-project.json; the script writes one .deb into APELIN_PACKAGE_DIR."
                : nil
        } catch {
            problem = (error as? ApelinError)?.message ?? "\(error)"
        }
        var diagnostics: [ProjectDiagnostic] = []
        if let problem {
            diagnostics.append(ProjectDiagnostic(code: "external.build", severity: .error, message: problem, field: "/external"))
        }
        return ProjectCheckResponse(passed: problem == nil, diagnostics: diagnostics, buildSystem: .external)
    }

    // MARK: Builds

    public func buildStart(
        _ request: BuildStartRequest,
        taskID: TaskID,
        resumed: Bool = false,
        emit: @escaping Emit,
    ) throws {
        if resumed {
            // The lost run may have registered its package before the host
            // heard; this run writes its own.
            try? FileManager.default.removeItem(at: ArtifactStore(store: store).url(of: taskID.rawValue))
        }
        if let (_, root) = try? store.root(of: request.projectID), let manifest = Workspace.manifest(at: root) {
            try externalBuildStart(request, manifest: manifest, root: root, taskID: taskID, emit: emit)
            return
        }
        var resolved = try BuildInputs.resolve(
            buildID: taskID.rawValue,
            projectID: request.projectID,
            configuration: request.configuration == .debug ? .debug : .release,
            store: store,
            catalog: catalog,
            registry: registry,
            installRoot: installRoot,
            home: home,
            bootstrap: request.bootstrap.flatMap { Bootstrap(rawValue: $0.rawValue) },
        )
        resolved.approvedBuildDigest = request.approvedBuildDigest
        let inputs = resolved
        if resumed {
            try? FileManager.default.removeItem(at: inputs.workDirectory)
        }
        let store = store
        run(taskID, emit: emit) { reporter, cancellation in
            try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: cancellation).record
        }
    }

    /// A workspace's build: its own script (`ExternalBuild`). A workspace
    /// that declares none is refused before the task is accepted. A
    /// resumed one starts over too: `ExternalBuild` clears the folder.
    private func externalBuildStart(
        _ request: BuildStartRequest,
        manifest: JSONDocument,
        root: URL,
        taskID: TaskID,
        emit: @escaping Emit,
    ) throws {
        guard let declaration = try ExternalBuildDeclaration.read(manifest, root: root) else {
            throw ApelinError(
                .badRequest,
                "this workspace declares no build: add \"external\": {\"script\": \"<a project file>\"} to its apelin-project.json; the script writes one .deb into APELIN_PACKAGE_DIR",
            )
        }
        let inputs = ExternalBuild.Inputs(
            buildID: taskID.rawValue,
            projectID: request.projectID,
            projectRoot: root,
            declaration: declaration,
            configuration: request.configuration == .debug ? .debug : .release,
            bootstrap: request.bootstrap.flatMap { Bootstrap(rawValue: $0.rawValue) }
                ?? BootstrapResolution.bootstrap(installRoot: installRoot, home: home),
            workDirectory: store.buildsDirectory
                .appendingPathComponent(request.projectID, isDirectory: true)
                .appendingPathComponent(taskID.rawValue, isDirectory: true),
            installRoot: installRoot,
            home: home,
        )
        let store = store
        run(taskID, emit: emit) { reporter, cancellation in
            try ExternalBuild.run(inputs: inputs, store: store, reporter: reporter, cancellation: cancellation)
        }
    }

    /// Runs one build on a thread of its own as the task `taskID`: its
    /// artifact and a final `state` that also carries the artifact's ID and
    /// digest, or the failure or cancel.
    private func run(
        _ taskID: TaskID,
        emit: @escaping Emit,
        build: @escaping @Sendable (TaskReporter, BuildCancellation) throws -> ArtifactRecord,
    ) {
        let cancellation = BuildCancellation()
        lock.lock()
        running[taskID] = cancellation
        lock.unlock()
        let reporter = TaskReporter(taskID: taskID, emit: emit)
        let thread = Thread { [self] in
            defer {
                lock.lock()
                running[taskID] = nil
                lock.unlock()
            }
            do {
                let record = try build(reporter, cancellation)
                let artifact = record.wireArtifact
                emit(taskID, "artifact", try? JSONValue(encoding: artifact))
                emit(taskID, TaskEvent.stateKind, .object([
                    "state": .string(TaskState.succeeded.rawValue),
                    "artifactID": .string(artifact.artifactID),
                    "digest": .string(artifact.digest),
                    "buildID": .string(record.buildID),
                    "packageID": .string(artifact.packageID),
                    "version": .string(artifact.version),
                    "bootstrap": .string(record.bootstrap),
                ]))
            } catch is BuildCancelled {
                emit(taskID, TaskEvent.stateKind, .object([
                    "state": .string(TaskState.cancelled.rawValue),
                    "message": .string("the build was cancelled"),
                ]))
            } catch let failure as BuildFailure {
                for diagnostic in failure.diagnostics where !reporter.reported(diagnostic) {
                    emit(taskID, "diagnostic", try? JSONValue(encoding: diagnostic))
                }
                emit(taskID, TaskEvent.stateKind, .object([
                    "state": .string(TaskState.failed.rawValue),
                    "message": .string(failure.description),
                ]))
            } catch {
                emit(taskID, TaskEvent.stateKind, .object([
                    "state": .string(TaskState.failed.rawValue),
                    "message": .string(String(describing: error)),
                ]))
            }
        }
        thread.name = "apelin-build \(taskID.rawValue)"
        thread.stackSize = 8 << 20
        thread.start()
    }
}

/// Stages, log lines and diagnostics as task events.
final class TaskReporter: BuildReporter, @unchecked Sendable {
    let taskID: TaskID
    let emit: BuildWorker.Emit
    private let lock = NSLock()
    private var seen: [ProjectDiagnostic] = []

    init(taskID: TaskID, emit: @escaping BuildWorker.Emit) {
        self.taskID = taskID
        self.emit = emit
    }

    @objc dynamic func stage(_ name: String, product: String?) {
        var payload: [String: JSONValue] = ["stage": .string(name)]
        if let product {
            payload["product"] = .string(product)
        }
        emit(taskID, "stage", .object(payload))
    }

    @objc dynamic func log(_ line: String) {
        emit(taskID, "log", .object(["line": .string(line)]))
    }

    func diagnostic(_ diagnostic: ProjectDiagnostic) {
        lock.lock()
        seen.append(diagnostic)
        lock.unlock()
        emit(taskID, "diagnostic", try? JSONValue(encoding: diagnostic))
    }

    func reported(_ diagnostic: ProjectDiagnostic) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.contains(diagnostic)
    }
}
