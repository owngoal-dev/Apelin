import ApelinCore
import ApelinDebian
import ApelinProtocol
import Darwin
import Foundation

/// transferExport, transferInspect and transferImport: a toolchain, an SDK
/// or a project as one file the user carries to another device
/// (`Operations/Transfer.swift` has the format).
///
/// Exports land in `Exports/<kind>-<id>/<name>.<extension>`, replacing the
/// item's earlier export; the app shares the file from there and deletes it.
/// An import reads the whole file into the task's staging, every member
/// checked against the manifest (`TransferArchiveReader`), before the kind's
/// own path runs: nothing is installed, registered or placed from a file
/// that did not read whole.
public struct TransferService: Sendable {
    public let layout: EnvironmentLayout
    let toolchains: ToolchainService
    let sdk: SDKManager
    let projects: ProjectLocator
    var limits = TransferLimits()

    public init(layout: EnvironmentLayout, toolchains: ToolchainService, sdk: SDKManager) {
        self.layout = layout
        self.toolchains = toolchains
        self.sdk = sdk
        projects = ProjectLocator(layout: layout)
    }

    // MARK: Files

    /// A transfer file to read: where libarchive opens it, the name it came
    /// with, and its size.
    struct Input: Sendable {
        var archive: ArchiveExtractor.Input
        var fileName: String?
        var size: Int64
        /// Holds a descriptor open while the task runs.
        var descriptor: OwnedDescriptor?
    }

    func input(_ source: TransferSource, fileName: String?, descriptors: [OwnedDescriptor]) throws -> Input {
        switch source {
        case let .file(slot):
            guard descriptors.indices.contains(slot.index) else {
                throw ApelinError(.badRequest, "no descriptor at slot \(slot.index)")
            }
            let descriptor = descriptors[slot.index]
            var metadata = stat()
            guard fstat(descriptor.rawValue, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw ApelinError(.badRequest, "the descriptor is not a regular file")
            }
            if let fileName, CanonicalPath.containsNUL(fileName) {
                throw ApelinError(.badRequest, "a bad file name")
            }
            return Input(
                archive: .descriptor(descriptor.rawValue),
                fileName: fileName,
                size: Int64(metadata.st_size),
                descriptor: descriptor,
            )
        case let .inbox(path):
            return try file(path, inside: layout.inbox, folder: "inbox")
        case let .exported(path):
            return try file(path, inside: layout.exports, folder: "Exports")
        }
    }

    /// A regular file named relative to `folder` (or absolute inside it),
    /// resolved with realpath and compared by components.
    private func file(_ path: String, inside folder: URL, folder name: String) throws -> Input {
        guard !path.isEmpty, !CanonicalPath.containsNUL(path) else { throw ApelinError(.badRequest, "no file named") }
        guard let base = CanonicalPath.resolve(folder.path) else {
            throw ApelinError(.notFound, "there is no \(name) folder in the data folder")
        }
        let candidate = path.hasPrefix("/") ? path : folder.appendingPathComponent(path).path
        guard let resolved = CanonicalPath.resolve(candidate) else {
            throw ApelinError(.notFound, "\(path) is not in \(name)")
        }
        guard CanonicalPath.isCanonical(resolved, inside: base), resolved != base else {
            throw ApelinError(.denied, "\(path) is not inside \(name)")
        }
        var metadata = stat()
        guard stat(resolved, &metadata) == 0 else { throw ApelinError(.notFound, "\(path) is not in \(name)") }
        if metadata.st_mode & S_IFMT == S_IFDIR {
            // An export's own folder (`sdk-<id>`) names the one file in it.
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: resolved)) ?? [])
                .filter { !$0.hasPrefix(".") && TransferKind(fileName: $0) != nil }
            guard files.count == 1 else { throw ApelinError(.notFound, "\(path) holds no single transfer file") }
            return try file(path + "/" + files[0], inside: folder, folder: name)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.badRequest, "\(path) is not a file")
        }
        return Input(
            archive: .path(resolved),
            fileName: (resolved as NSString).lastPathComponent,
            size: Int64(metadata.st_size),
        )
    }

    /// The manifest, after the checks every file passes: its own rules, and
    /// the kind its name's extension and the caller say.
    func manifest(of input: Input, expecting kind: TransferKind? = nil) throws -> TransferManifest {
        let manifest = try TransferArchiveReader(limits: limits).manifest(input.archive)
        try Self.checkKind(manifest, fileName: input.fileName, expecting: kind)
        return manifest
    }

    static func checkKind(_ manifest: TransferManifest, fileName: String?, expecting kind: TransferKind?) throws {
        if let fileName {
            guard let named = TransferKind(fileName: fileName) else {
                throw ApelinError(
                    .badRequest,
                    "Apelin cannot open \(fileName). Choose a toolchain (.apetc), SDK (.apesdk) or project (.apeproj) file.",
                )
            }
            guard named == manifest.kind else {
                throw ApelinError(
                    .badRequest,
                    "\(fileName) contains \(manifest.kind.description), not \(named.description). Export it again.",
                )
            }
        }
        if let kind, kind != manifest.kind {
            throw ApelinError(
                .badRequest,
                "This file contains \(manifest.kind.description), not \(kind.description). Choose another file.",
            )
        }
    }

    // MARK: Inspect

    public func inspect(
        _ request: TransferInspectRequest,
        descriptors: [OwnedDescriptor],
    ) throws -> TransferInspection {
        let input = try input(request.source, fileName: request.fileName, descriptors: descriptors)
        let manifest = try manifest(of: input)
        var inspection = TransferInspection(summary: manifest.summary, fileSize: input.size, importable: true)
        switch manifest.kind {
        case .toolchain: inspectToolchain(manifest, into: &inspection)
        case .sdk: inspectSDK(manifest, into: &inspection)
        case .project: inspectProject(manifest, into: &inspection)
        }
        inspection.importable = inspection.problems.isEmpty
        return inspection
    }

    private func inspectToolchain(_ manifest: TransferManifest, into inspection: inout TransferInspection) {
        guard let toolchain = manifest.toolchain else { return }
        if let refusal = HostSigning.toolchainRefusal(installRoot: layout.installRoot) ?? HostCPU.toolchainRefusal {
            inspection.problems.append(refusal)
        } else if let refusal = toolchains.backend.importRefusal(toolchain) {
            inspection.problems.append(refusal)
        }
        if let existing = ToolchainRegistry.load(layout).toolchains.first(where: { $0.id == manifest.id }) {
            inspection.existingID = existing.id
            inspection.problems.append("This toolchain is already set up on this device.")
        }
        let registered = sdk.store.list()
        let newest = toolchain.record.newestSDK
        if !registered.contains(where: { SDKVersionLimit.allows(sdkVersion: $0.version, newestSDK: newest) }) {
            if toolchains.supplier.hasEnabledSource {
                inspection.notes.append(
                    "No SDK on this device fits its self-test; one is downloaded from your SDK sources first.",
                )
            } else {
                inspection.problems.append(
                    "Its self-test compiles against an iPhoneOS SDK up to \(newest ?? "any version"), and none is registered here. Import one first.",
                )
            }
        }
        let here = layout.isRoothide ? BootstrapFlavor.roothide.rawValue : BootstrapFlavor.rootless.rawValue
        if toolchain.bootstrap != here {
            inspection.notes.append(
                "It was exported from a \(toolchain.bootstrap) device; it is packaged again for this \(here) one.",
            )
        }
        inspection.notes.append(
            "It is installed through Irisin and self-tested on this device, and kept only if the self-test passes.",
        )
    }

    private func inspectSDK(_ manifest: TransferManifest, into inspection: inout TransferInspection) {
        if let existing = sdk.store.record(manifest.id) {
            inspection.existingID = existing.id
            inspection.problems.append("This SDK is already registered on this device.")
        }
        if manifest.sdk?.record.swiftCompilerVersion != nil, !toolchains.hasSwift {
            inspection.notes.append(
                "No toolchain here has Swift yet; Swift projects cannot build against it until one does.",
            )
        }
    }

    // MARK: Export

    /// What an accepted export will write.
    struct PreparedExport: Sendable {
        var kind: TransferKind
        var id: String
        var createdBy: String
        var toolchain: ToolchainRecord?
        var sdk: SDKRecord?
        var project: ProjectLocator.Project?
    }

    public func prepareExport(_ request: TransferExportRequest) throws -> PreparedExportHandle {
        let createdBy = request.createdBy
            .flatMap { $0.isEmpty || CanonicalPath.containsNUL($0) ? nil : String($0.prefix(120)) }
            ?? "Apelin (protocol \(Wire.protocolVersion))"
        var prepared = PreparedExport(kind: request.kind, id: request.id, createdBy: createdBy)
        switch request.kind {
        case .toolchain:
            guard let record = ToolchainRegistry.load(layout).toolchains.first(where: { $0.id == request.id }) else {
                throw ApelinError(.notFound, "no toolchain \(request.id.debugDescription)")
            }
            guard toolchains.backend.isAvailable else {
                throw ApelinError(.unavailable, UnavailableToolchainBackend.transferUnavailable)
            }
            guard let path = record.path, FileManager.default.fileExists(atPath: path) else {
                throw ApelinError(
                    .notFound,
                    "The files for \(record.id) are missing. Remove the toolchain and set it up again.",
                )
            }
            prepared.toolchain = record
        case .sdk:
            guard let record = sdk.store.record(request.id) else {
                throw ApelinError(.notFound, "no SDK \(request.id.debugDescription)")
            }
            prepared.sdk = record
        case .project:
            let project = try projects.locate(request.id)
            guard project.projectID != nil else {
                throw ApelinError(
                    .badRequest,
                    "\(project.name) cannot be exported because its project file is missing.",
                )
            }
            prepared.project = project
            prepared.id = project.projectID ?? project.name
        }
        return PreparedExportHandle(prepared: prepared)
    }

    /// An accepted export, opaque outside the module.
    public struct PreparedExportHandle: Sendable {
        let prepared: PreparedExport
    }

    public func export(
        _ handle: PreparedExportHandle,
        staging: URL,
        reporter: TaskReporter,
    ) async throws -> TransferExport {
        let prepared = handle.prepared
        reporter.stage("collecting")
        var collected: Collected = switch prepared.kind {
        case .toolchain: try toolchainContents(prepared.toolchain!, staging: staging, reporter: reporter)
        case .sdk: try sdkContents(prepared.sdk!, reporter: reporter)
        case .project: try projectContents(prepared.project!, staging: staging, reporter: reporter)
        }
        try reporter.checkCancelled()
        collected.manifest.createdBy = prepared.createdBy
        collected.manifest.created = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        collected.manifest.members = collected.tree.members
        try TransferArchiveReader.check(collected.manifest, limits: limits)

        reporter.stage("packing")
        try layout.make(layout.exports)
        let folderName = prepared.kind.rawValue + "-" + Self.fileSafe(prepared.id)
        let folder = layout.exports.appendingPathComponent(folderName, isDirectory: true)
        // An earlier export of the same item goes: this one replaces it.
        try? FileManager.default.removeItem(at: folder)
        try layout.make(folder)
        let fileName = Self.fileSafe(collected.fileStem) + "." + prepared.kind.fileExtension
        let partial = folder.appendingPathComponent("." + fileName + ".partial")
        let destination = folder.appendingPathComponent(fileName)
        let digest: String
        let size: Int64
        do {
            try TransferArchiveWriter(root: collected.tree.root, sources: collected.tree.sources)
                .write(collected.manifest, to: partial, reporter: reporter)
            reporter.stage("verifying")
            let total = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            let throttle = ProgressThrottle()
            reporter.progress("verifying", completed: 0, total: total)
            (digest, size) = try TransferDigest.file(partial) { completed in
                try reporter.checkCancelled()
                if throttle.shouldEmit() {
                    reporter.progress("verifying", completed: completed, total: total)
                }
            }
            reporter.progress("verifying", completed: size, total: size)
            try reporter.checkCancelled()
            guard rename(partial.path, destination.path) == 0 else { throw ArchiveExtractor.posix("name the export") }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        collected.warnings.forEach(reporter.warning)
        return TransferExport(
            path: destination.path,
            exportedPath: folderName + "/" + fileName,
            fileName: fileName,
            size: size,
            sha256: digest,
            summary: collected.manifest.summary,
        )
    }

    /// A manifest without members yet, the tree its members come from, and
    /// what the file will be called.
    struct Collected {
        var manifest: TransferManifest
        var tree: TransferTree
        var fileStem: String
        var warnings: [String] = []
    }

    private func toolchainContents(
        _ record: ToolchainRecord,
        staging: URL,
        reporter: TaskReporter,
    ) throws -> Collected {
        let tree = staging.appendingPathComponent("toolchain", isDirectory: true)
        let prepared = try toolchains.backend.exportTree(installed: URL(fileURLWithPath: record.path!), into: tree)
        guard prepared.id == record.id else {
            throw ApelinError(.conflict, "the tree at \(record.path!) is toolchain \(prepared.id), not \(record.id)")
        }
        let facts = (try? JSONCoding.decode(JSONValue.self, from: prepared.manifest)) ?? .null
        var shared = record
        shared.path = nil
        shared.installationID = nil
        let flavor: BootstrapFlavor = layout.isRoothide ? .roothide : .rootless
        let toolchain = TransferToolchain(
            record: shared,
            retargetScheme: Int(facts["retargetSchemeVersion"]?.doubleValue ?? 0),
            productID: prepared.product.productID,
            sourceSHA256: facts["sourceSHA256"]?.stringValue ?? "",
            bootstrap: flavor.rawValue,
            architecture: PackageLayout(flavor: flavor).architecture,
            minimumOS: facts["minimumOS"]?.stringValue ?? "",
        )
        let swift = record.components.contains { $0.kind == .swift }
        let name = "Command Line Tools \(record.version)" + (swift ? " with Swift" : "")
        return try Collected(
            manifest: TransferManifest(
                kind: .toolchain,
                id: record.id,
                name: name,
                createdBy: "",
                toolchain: toolchain,
            ),
            tree: TransferTree.collect(tree, reporter: reporter),
            fileStem: name,
        )
    }

    private func sdkContents(_ record: SDKRecord, reporter: TaskReporter) throws -> Collected {
        var shared = record
        shared.path = ""
        let name = "\(Self.platform(of: record)) \(record.version)"
        return try Collected(
            manifest: TransferManifest(
                kind: .sdk,
                id: record.id,
                name: name,
                createdBy: "",
                sdk: TransferSDK(record: shared),
            ),
            tree: TransferTree.collect(sdk.store.tree(record.id), reporter: reporter),
            fileStem: name + " SDK",
        )
    }

    /// `iPhoneOS27.0` → `iPhoneOS`.
    static func platform(of record: SDKRecord) -> String {
        let letters = record.canonicalName.prefix { !$0.isNumber }
        return letters.lowercased() == "iphoneos" ? "iPhoneOS" : String(letters)
    }

    /// A name a file can have: no slash, colon, NUL or leading dot.
    static func fileSafe(_ name: String) -> String {
        var cleaned = String(name.map { "/:\\\0".contains($0) ? "-" : $0 })
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        cleaned = String(cleaned.prefix(120))
        return cleaned.isEmpty ? "Apelin" : cleaned
    }

    // MARK: Import

    /// An accepted import: its file, held open, and its manifest.
    public struct PreparedImport: Sendable {
        let input: Input
        let manifest: TransferManifest
        let request: TransferImportRequest
    }

    /// Checks an import before the task is accepted: the file reads, its
    /// manifest holds, and this device would take it.
    public func prepareImport(
        _ request: TransferImportRequest,
        descriptors: [OwnedDescriptor],
    ) throws -> PreparedImport {
        let input = try input(request.source, fileName: request.fileName, descriptors: descriptors)
        let manifest = try manifest(of: input, expecting: request.kind)
        var inspection = TransferInspection(summary: manifest.summary, fileSize: input.size, importable: true)
        switch manifest.kind {
        case .toolchain:
            inspectToolchain(manifest, into: &inspection)
        case .sdk:
            inspectSDK(manifest, into: &inspection)
        case .project:
            if let name = request.projectName {
                if let problem = ProjectName.validate(name) {
                    throw ApelinError(.badRequest, problem.reason)
                }
                if projects.exists(named: name) {
                    throw ApelinError(.conflict, "A project named \(name) already exists. Choose another name.")
                }
            }
        }
        if let problem = inspection.problems.first {
            throw ApelinError(inspection.existingID != nil ? .conflict : .badRequest, problem)
        }
        return PreparedImport(input: input, manifest: manifest, request: request)
    }

    /// Runs an accepted import in `staging`; answers its `result` payload.
    public func runImport(
        _ prepared: PreparedImport,
        staging: URL,
        taskID: TaskID,
        installer: any PackageInstaller,
        reporter: TaskReporter,
    ) async throws -> JSONValue {
        reporter.stage("reading")
        let tree = staging.appendingPathComponent("tree", isDirectory: true)
        guard mkdir(tree.path, 0o755) == 0 else { throw ArchiveExtractor.posix("make the staging tree") }
        let manifest = try TransferArchiveReader(limits: limits)
            .extract(prepared.input.archive, into: tree, reporter: reporter)
        // The file read again is the one the task accepted.
        guard manifest == prepared.manifest else {
            throw ApelinError(.conflict, "The file changed after it was checked. Open it again.")
        }
        try reporter.checkCancelled()
        switch manifest.kind {
        case .toolchain:
            let prepared = try toolchains.backend.importTree(tree)
            guard prepared.id == manifest.id,
                  manifest.toolchain?.record.contentDigest.map({ $0 == ToolchainService.contentDigest(prepared.files) }) ?? true
            else {
                throw ApelinError(
                    .badRequest,
                    "This file is damaged or was changed after it was exported. Export it again.",
                )
            }
            let record = try await toolchains.importPrepared(
                prepared,
                taskID: taskID,
                installer: installer,
                reporter: reporter,
            )
            return try .object(["toolchain": JSONValue(encoding: record)])
        case .sdk:
            let record = try importSDK(tree, manifest: manifest, fileName: prepared.input.fileName, reporter: reporter)
            return try .object(["sdk": JSONValue(encoding: record)])
        case .project:
            let result = try importProject(
                tree,
                manifest: manifest,
                name: prepared.request.projectName,
                reporter: reporter,
            )
            return try .object(["project": JSONValue(encoding: result)])
        }
    }

    private func importSDK(
        _ tree: URL,
        manifest: TransferManifest,
        fileName: String?,
        reporter: TaskReporter,
    ) throws -> SDKRecord {
        reporter.stage("inspecting")
        var metadata = stat()
        guard lstat(tree.appendingPathComponent("SDKSettings.json").path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG
        else {
            throw ApelinError(.badRequest, "This file does not contain an SDK. Export the SDK again.")
        }
        var inspection = try sdk.inspector.inspect(tree, reporter: reporter)
        let id = inspection.identity.canonicalName + "-" + inspection.digest.prefix(8)
        guard id == manifest.id, manifest.sdk?.record.digest.map({ $0 == inspection.digest }) ?? true else {
            throw ApelinError(
                .badRequest,
                "This file is damaged or was changed after it was exported. Export it again.",
            )
        }
        if let existing = sdk.store.record(id) {
            throw ApelinError(.conflict, "This SDK is already registered on this device (\(existing.id)).")
        }
        if inspection.identity.swiftCompilerVersion != nil, !toolchains.hasSwift {
            inspection.warnings.append(
                "No toolchain on this device has Swift. Swift projects cannot build against this SDK until one does.",
            )
        }
        inspection.warnings.forEach(reporter.warning)
        try reporter.checkCancelled()
        reporter.stage("registering")
        let from = manifest.sdk?.record.origin.map { ", first from \($0)" } ?? ""
        return try sdk.store.register(
            root: tree,
            inspection: inspection,
            origin: "transfer \(fileName ?? manifest.name)\(from)",
        )
    }
}

extension TransferService {
    /// An export cut off mid-write leaves `.<name>.partial`: removed when
    /// the worker starts, before anything runs.
    static func sweepPartialExports(_ layout: EnvironmentLayout) {
        guard let folders = try? FileManager.default.contentsOfDirectory(atPath: layout.exports.path) else { return }
        for folder in folders where !folder.hasPrefix(".") {
            let url = layout.exports.appendingPathComponent(folder, isDirectory: true)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                where name.hasSuffix(".partial")
            {
                try? FileManager.default.removeItem(at: url.appendingPathComponent(name))
            }
        }
    }
}

extension TransferKind {
    /// "a toolchain", "an SDK", "a project".
    var description: String {
        switch self {
        case .toolchain: "a toolchain"
        case .sdk: "an SDK"
        case .project: "a project"
        }
    }
}
