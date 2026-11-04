import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation

/// toolchainStatus, toolchainSetup, toolchainRemove.
public struct ToolchainService: Sendable {
    public let layout: EnvironmentLayout
    public let backend: any ToolchainBackend
    let projects: ProjectLocator
    let sdks: SDKStore
    /// Where an SDK comes from when no registered one fits the release.
    let supplier: any SDKSupplier

    public init(layout: EnvironmentLayout, backend: any ToolchainBackend, supplier: (any SDKSupplier)? = nil) {
        self.layout = layout
        self.backend = backend
        projects = ProjectLocator(layout: layout)
        sdks = SDKStore(layout: layout)
        self.supplier = supplier ?? SourceSDKSupplier(layout: layout)
    }

    /// Update only the registry default, never any project's environment.
    public func setDefault(id: String) throws {
        var registry = ToolchainRegistry.load(layout)
        guard registry.toolchains.contains(where: { $0.id == id }) else {
            throw ApelinError(.notFound, "The toolchain is no longer registered on this device.")
        }
        guard registry.defaultID != id else { return }
        registry.defaultID = id
        try registry.save(layout)
    }

    // MARK: Status

    public func status(activeTasks: [TaskHandle]) -> ToolchainStatusResponse {
        let registry = ToolchainRegistry.load(layout)
        let toolchains = registry.toolchains.map { record -> ToolchainRecord in
            var record = record
            if record.path != nil, !Self.exists(record.path) {
                record.components = record.components.map {
                    var component = $0
                    component.problem = "not found at its installed path"
                    return component
                }
            }
            return record
        }
        return ToolchainStatusResponse(toolchains: toolchains, defaultID: registry.defaultID, activeTasks: activeTasks)
    }

    /// The releases Apelin sets up, from Apple's catalog, newest first, for
    /// the app to pick from. A product Apelin has not reviewed (12.4, a
    /// release it dropped, one it never took) is left out: setup still
    /// refuses it by ID with its reason. A reviewed one this device cannot
    /// run stays, with that reason; on roothide Bootstrap, which runs none,
    /// every one carries that one reason.
    public func catalog() async throws -> ToolchainCatalogResponse {
        guard backend.isAvailable else {
            throw ApelinError(.unavailable, UnavailableToolchainBackend.setupUnavailable)
        }
        let signing = HostSigning.toolchainRefusal(installRoot: layout.installRoot)
        let products = try await backend.catalog()
            .filter { $0.reviewed != false }
            .sorted { Self.versionOrder($1.version, $0.version) }
            .map {
                ToolchainCatalogProduct(
                    productID: $0.productID,
                    version: $0.version,
                    size: $0.size,
                    unsupportedReason: signing
                        ?? $0.unsupportedReason
                        ?? $0.compatibility?.unavailableReason
                        ?? HostCPU.toolchainRefusal,
                    newestSDK: $0.newestSDK,
                    supportsSwift: $0.supportsSwift,
                    swiftRequirements: $0.swiftRequirements,
                    swiftUnavailableReason: $0.swiftUnavailableReason,
                    clangModuleCPUFeatures: $0.clangModuleCPUFeatures,
                    compatibility: $0.compatibility,
                )
            }
        return ToolchainCatalogResponse(products: products)
    }

    public var hasSwift: Bool {
        ToolchainRegistry.load(layout).toolchains.contains { record in
            record.components.contains { $0.kind == .swift && $0.selfCheckPassed == true }
        }
    }

    // MARK: Setup

    /// What an accepted setup will do.
    public struct PreparedSetup: Sendable {
        public var request: ToolchainSetupRequest
    }

    /// Checks a setup before the task is accepted.
    public func prepare(_ request: ToolchainSetupRequest) throws -> PreparedSetup {
        guard backend.isAvailable else {
            throw ApelinError(.unavailable, UnavailableToolchainBackend.setupUnavailable)
        }
        // nothing Apelin signs runs on roothide Bootstrap, and the tools'
        // machine code is the M1's, which some CPUs cannot run
        if let refusal = HostSigning.toolchainRefusal(installRoot: layout.installRoot) ?? HostCPU.toolchainRefusal {
            throw ApelinError(.unavailable, refusal)
        }
        guard case .appleCatalog = request.source else {
            throw ApelinError(
                .badRequest,
                "setting up a toolchain from a package file is not supported yet; use appleCatalog",
            )
        }
        guard !request.components.isEmpty, request.components.contains(.c) else {
            throw ApelinError(.badRequest, "the C component is required")
        }
        // The self-test compiles against a registered SDK: the newest one the
        // release's tools read, picked once the catalog names the release,
        // and fetched from an enabled source when none of them fits.
        guard !sdks.list().isEmpty || supplier.hasEnabledSource else {
            throw ApelinError(
                .badRequest,
                "Import an SDK first. Apelin tests each new toolchain against an SDK.",
            )
        }
        return PreparedSetup(request: request)
    }

    public func setup(
        _ prepared: PreparedSetup,
        taskID: TaskID,
        installer: any PackageInstaller,
        reporter: TaskReporter,
    ) async throws -> ToolchainRecord {
        let request = prepared.request
        // Resolve the product before choosing the SDK it can self-test against.
        reporter.stage("downloading")
        let catalog = try await backend.catalog()
        let product: ToolchainProduct
        if case let .appleCatalog(productID?) = request.source {
            guard let match = catalog.first(where: { $0.productID == productID }) else {
                throw ApelinError(.notFound, "Apple's catalog has no product \(productID)")
            }
            product = match
        } else {
            let supported = catalog.filter { $0.unsupportedReason == nil }
            guard let newest = supported.sorted(by: { Self.versionOrder($0.version, $1.version) }).last else {
                throw ApelinError(.notFound, "Apple's catalog lists no Command Line Tools that Apelin can set up")
            }
            product = newest
        }
        if let reason = product.unsupportedReason ?? product.compatibility?.unavailableReason {
            throw ApelinError(.badRequest, reason)
        }
        let swift = request.components.contains(.swift)
        if swift, product.supportsSwift == false {
            throw ApelinError(
                .badRequest,
                product.swiftUnavailableReason
                    ?? "Swift is not available with Command Line Tools \(product.version). Choose a release marked for Swift, or set it up without Swift.",
            )
        }
        try reporter.checkCancelled()

        let components = Array(Set(request.components)).sorted { $0.rawValue < $1.rawValue }
        let key = Self.jobKey(product: product, components: components)
        guard RunningJobs.shared.claim(key) else {
            throw ApelinError(
                .conflict,
                "Command Line Tools \(product.version) is already being set up with these components. Wait for that setup to finish.",
            )
        }
        defer { RunningJobs.shared.release(key) }
        let directory = layout.toolchainJobs.appendingPathComponent(key, isDirectory: true)
        try layout.make(directory)
        let jobURL = directory.appendingPathComponent("job.json")
        var job = ((try? JSONFile.read(ToolchainJob.self, at: jobURL)) ?? nil)
            ?? ToolchainJob(
                key: key,
                productID: product.productID,
                components: components,
                stage: "downloading",
                taskID: taskID.rawValue,
                updated: Date(),
            )
        if job.taskID != taskID.rawValue {
            reporter.emit("resumed", .object(["stage": .string(job.stage), "previousTask": .string(job.taskID)]))
            job.taskID = taskID.rawValue
        }
        job.failure = nil
        let journal = JobJournal(job: job, url: jobURL)
        journal.save()

        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        let journalFolder = directory.appendingPathComponent("journal", isDirectory: true)
        for folder in [staging, scratch, journalFolder] {
            try layout.make(folder)
        }

        let throttle = ProgressThrottle()
        let progress: @Sendable (ToolchainBackendProgress) -> Void = { update in
            if journal.enter(update.stage) {
                reporter.stage(update.stage)
            }
            if throttle.shouldEmit() {
                reporter.progress(
                    update.stage,
                    completed: update.completed,
                    total: update.total,
                    detail: update.detail.isEmpty ? nil : update.detail,
                )
            }
        }

        let installs = InstallTracker()
        var previous: ToolchainRecord?
        var artifactPath: String?
        // irisind is handed the host's staged copy; this one is packaged
        // again, from the kept tree, by a later run that needs it.
        defer {
            if let artifactPath {
                try? FileManager.default.removeItem(atPath: artifactPath)
            }
        }
        do {
            let sdkRecord = try await resolveSDK(
                for: product,
                swift: swift,
                staging: directory.appendingPathComponent("sdk", isDirectory: true),
                journal: journal,
                reporter: reporter,
            )
            try reporter.checkCancelled()

            // Physical paths: the toolchain sees the real root, and the
            // self-test hands -isysroot the SDK as it is on disk.
            guard let installRoot = CanonicalPath.resolve(layout.installRoot) else {
                throw ApelinError(.unavailable, "the install root \(layout.installRoot) does not resolve")
            }
            guard let sdk = CanonicalPath.resolve(sdkRecord.path) else {
                throw ApelinError(
                    .notFound,
                    "The files for SDK \(sdkRecord.id) are missing. Remove the SDK and import it again.",
                )
            }

            let tree = try await backend.prepare(
                product: product,
                components: components,
                staging: staging,
                output: output,
                progress: progress,
            )
            try reporter.checkCancelled()
            journal.toolchainID = tree.id

            if journal.enter("packaging") {
                reporter.stage("packaging")
            }
            let artifact = try ToolchainPackager(layout: layout).package(tree)
            artifactPath = artifact.path
            reporter.emit("artifact", encoding: artifact)

            // An install is reused only when the bridge has a record of it:
            // this job's (a worker that stopped after irisind answered), or
            // the registered toolchain's when it is set up again. Bytes that
            // merely match — copied by hand, or left by an install whose
            // answer was lost — give removal nothing to act on, so they go
            // through the bridge again.
            previous = ToolchainRegistry.load(layout).toolchains.first { $0.id == tree.id }
            let remembered = journal.installationID ?? previous?.installationID
            let install: @Sendable () async throws -> Void = {
                if journal.enter("installing") {
                    reporter.stage("installing")
                }
                // Settled, never abandoned: a cancel waits for irisind's answer.
                let result = try await Self.settled {
                    // The host's install task is in job.json from the moment
                    // it answers: a setup resumed past that point — re-run,
                    // or re-sent by the host under the same task ID — follows
                    // it rather than handing the package over twice.
                    if let pending = journal.installTaskID {
                        reporter.emit("installResumed", .object(["installTask": .string(pending)]))
                        do {
                            let result = try await installer.finishInstall(
                                TaskHandle(taskID: TaskID(pending), kind: .install),
                                reporter: reporter,
                            )
                            journal.installationID = result.installationID
                            journal.installTaskID = nil
                            return result
                        } catch let error as ApelinError where error.code == .unavailable {
                            throw error // still the host's to finish; kept for the next run
                        } catch {
                            // Ended without installing, or gone: hand it over again.
                            journal.installTaskID = nil
                            reporter.warning(
                                "the earlier install task \(pending) did not install (\(error)); installing again",
                            )
                        }
                    }
                    let handle = try await installer.startInstall(artifact)
                    journal.installTaskID = handle.taskID.rawValue
                    do {
                        let result = try await installer.finishInstall(handle, reporter: reporter)
                        journal.installationID = result.installationID
                        journal.installTaskID = nil
                        return result
                    } catch let error as ApelinError where error.code == .unavailable {
                        throw error
                    } catch {
                        journal.installTaskID = nil
                        throw error
                    }
                }
                installs.add(result.installationID)
                guard result.packageID == artifact.packageID else {
                    throw ApelinError(.internal, "the bridge installed \(result.packageID), not \(artifact.packageID)")
                }
            }
            if remembered == nil || journal.installTaskID != nil {
                try await install()
            }

            let selfTests = try await backend.installAndValidate(
                tree,
                installRoot: URL(fileURLWithPath: installRoot, isDirectory: true),
                sdk: URL(fileURLWithPath: sdk, isDirectory: true),
                journal: journalFolder,
                scratch: scratch,
                install: { _ in
                    // The remembered install's bytes no longer match, so it
                    // is installed again; after this task's own install they
                    // have to.
                    guard installs.latest == nil else {
                        throw ApelinError(
                            .internal,
                            "irisind installed \(artifact.packageID), but the bytes under \(tree.installRelativePath) are not the package's",
                        )
                    }
                    try await install()
                },
                progress: progress,
            )
            try reporter.checkCancelled()

            let path = installRoot + "/" + tree.installRelativePath
            let record = try register(
                tree,
                artifact: artifact,
                path: CanonicalPath.resolve(path) ?? path,
                selfTests: selfTests,
                installationID: installs.latest ?? remembered,
                selfTestSDK: sdkRecord.version,
            )
            if journal.enter("ready") {
                reporter.stage("ready")
            }
            try? FileManager.default.removeItem(at: directory)
            return record
        } catch {
            let cancelled = reporter.isCancelled
                || error is CancellationError
                || (error as? ApelinError)?.code == .cancelled
            // Nothing this setup installed outlives it unregistered.
            let clean = await rollBack(
                installs,
                previous: previous,
                journal: journal,
                installer: installer,
                reporter: reporter,
            )
            if cancelled, clean, journal.installTaskID == nil {
                // A cancel cleans up only this setup's own work.
                try? FileManager.default.removeItem(at: directory)
            } else {
                journal.fail(String(describing: error))
            }
            throw error
        }
    }

    /// Undoes what a failed or cancelled setup installed: removed through
    /// the bridge or, when a registered toolchain of the same ID was there
    /// before, handed to that record, whose install the new one superseded.
    /// An install an earlier run of the job made and never registered, kept
    /// in job.json, is the setup's own as much as this run's.
    /// Answers whether nothing is left behind.
    func rollBack(
        _ installs: InstallTracker,
        previous: ToolchainRecord?,
        journal: JobJournal,
        installer: any PackageInstaller,
        reporter: TaskReporter,
    ) async -> Bool {
        guard let installationID = installs.latest ?? journal.installationID else { return true }
        // A run that failed before it looked the registry up still knows the
        // toolchain's ID from an earlier run's job.json: an install of that
        // package belongs to the registered toolchain all the same.
        let previous = previous ?? journal.toolchainID.flatMap { id in
            ToolchainRegistry.load(layout).toolchains.first { $0.id == id }
        }
        if let previous {
            var registry = ToolchainRegistry.load(layout)
            if let index = registry.toolchains.firstIndex(where: { $0.id == previous.id }) {
                registry.toolchains[index].installationID = installationID
                try? registry.save(layout)
            }
            journal.installationID = nil
            return true
        }
        do {
            try await Self.settled { try await installer.remove(installationID: installationID, reporter: reporter) }
            journal.installationID = nil
            return true
        } catch {
            reporter.warning("the toolchain package this setup installed could not be removed (\(error)); setting it up again picks it up")
            return false
        }
    }

    func register(
        _ tree: PreparedToolchain,
        artifact: LocalArtifact,
        path: String,
        selfTests: [ToolchainSelfTestResult],
        installationID: String?,
        selfTestSDK: String,
    ) throws -> ToolchainRecord {
        var registry = ToolchainRegistry.load(layout)
        // A case's language is its first word: `Swift dylib` and `Swift async` count as Swift.
        let passed = { (languages: Set<String>) -> Bool in
            let cases = selfTests.filter {
                languages.contains(String($0.language.lowercased().split(separator: " ").first ?? ""))
            }
            return !cases.isEmpty && cases.allSatisfy(\.passed)
        }
        let components = tree.components.map { kind -> ToolchainComponent in
            switch kind {
            case .c: ToolchainComponent(kind: .c, selfCheckPassed: passed(["c", "c++", "objc", "objective-c"]))
            case .swift:
                ToolchainComponent(
                    kind: .swift,
                    selfCheckPassed: passed(["swift"]),
                    problem: passed(["swift"]) ? nil : "Swift did not pass its self-test",
                )
            case .auxiliary: ToolchainComponent(kind: .auxiliary, selfCheckPassed: nil)
            }
        }
        guard components.first(where: { $0.kind == .c })?.selfCheckPassed == true else {
            throw ApelinError(.internal, "The toolchain did not pass its C self-test, so it was not added.")
        }
        guard let installationID else {
            throw ApelinError(
                .internal,
                "Apelin has no install record for this toolchain, so it was not added. Try again.",
            )
        }
        let record = ToolchainRecord(
            id: tree.id,
            version: tree.product.version,
            components: components,
            path: path,
            packageID: artifact.packageID,
            contentDigest: Self.contentDigest(tree.files),
            fileCount: tree.files.count,
            selfTests: selfTests,
            installationID: installationID,
            origin: "\(tree.product.productID) \(tree.product.url)",
            newestSDK: tree.product.newestSDK,
            selfTestSDK: selfTestSDK,
            swiftRequirements: tree.product.swiftRequirements,
            clangModuleCPUFeatures: tree.product.clangModuleCPUFeatures,
            compatibility: tree.product.compatibility,
        )
        registry.toolchains.removeAll { $0.id == record.id }
        registry.toolchains.append(record)
        if registry.defaultID == nil {
            registry.defaultID = record.id
        }
        try registry.save(layout)
        return record
    }

    // MARK: Helpers

    static func jobKey(product: ToolchainProduct, components: [ToolchainComponentKind]) -> String {
        let text = ([product.productID, product.url] + components.map(\.rawValue)).joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `body` to its end on a task of its own, so a cancel of the
    /// caller waits for the bridge's answer instead of abandoning it.
    static func settled<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await body() }.value
    }

    /// Whether a toolchain's tree is still installed: some regular file is
    /// left below `path`. A package removed from outside leaves its folders
    /// behind on roothide, each with the `.jbroot` link roothide adds, so a
    /// folder of folders and links is a tree that is gone. Links are not
    /// followed; the walk stops at the first file.
    static func exists(_ path: String?) -> Bool {
        guard let path else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard let walk = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { _, _ in true },
        ) else { return true }
        for case let url as URL in walk
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        {
            return true
        }
        return false
    }

    static func contentDigest(_ files: [String: String]) -> String {
        var hash = SHA256()
        for (path, digest) in files.sorted(by: { $0.key < $1.key }) {
            hash.update(data: Data("\(path) \(digest)\n".utf8))
        }
        return TransferDigest.hex(hash.finalize())
    }

    /// Numeric, component by component: 9.0 < 16.4 < 27.0.
    static func versionOrder(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b {
                return a < b
            }
        }
        return false
    }
}
