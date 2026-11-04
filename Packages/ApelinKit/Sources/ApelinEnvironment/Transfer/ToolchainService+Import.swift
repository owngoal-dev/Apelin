import ApelinCore
import ApelinProtocol
import Foundation

extension ToolchainService {
    /// Installs a toolchain tree a transfer file brought, checked already by
    /// `backend.importTree`, the way setup installs one it retargeted: an
    /// SDK for the self-test (fetched from an enabled source when none
    /// registered fits), a local deb from `ToolchainPackager` for this
    /// bootstrap, the install bridge, the self-test on this device, and the
    /// registry only when it passed — otherwise what it installed is removed
    /// through the bridge. Its job record is `Toolchains/jobs/import-<id>/`,
    /// so an install a stopped import made is picked up when it is run again.
    func importPrepared(
        _ tree: PreparedToolchain,
        taskID: TaskID,
        installer: any PackageInstaller,
        reporter: TaskReporter,
    ) async throws -> ToolchainRecord {
        let product = tree.product
        if let refusal = HostSigning.toolchainRefusal(installRoot: layout.installRoot) ?? HostCPU.toolchainRefusal {
            throw ApelinError(.unavailable, refusal)
        }
        if let reason = product.unsupportedReason ?? product.compatibility?.unavailableReason {
            throw ApelinError(.badRequest, reason)
        }
        let swift = tree.components.contains(.swift)
        if swift, product.supportsSwift == false {
            throw ApelinError(
                .badRequest,
                product.swiftUnavailableReason
                    ?? "Swift from Command Line Tools \(product.version) is not available on this device.",
            )
        }
        if ToolchainRegistry.load(layout).toolchains.contains(where: { $0.id == tree.id }) {
            throw ApelinError(.conflict, "This toolchain is already set up on this device.")
        }
        guard !sdks.list().isEmpty || supplier.hasEnabledSource else {
            throw ApelinError(
                .badRequest,
                "Import an SDK first. Apelin tests each new toolchain against an SDK.",
            )
        }

        let key = "import-" + tree.id
        guard RunningJobs.shared.claim(key) else {
            throw ApelinError(.conflict, "This toolchain is already being imported. Wait for that import to finish.")
        }
        defer { RunningJobs.shared.release(key) }
        let directory = layout.toolchainJobs.appendingPathComponent(key, isDirectory: true)
        try layout.make(directory)
        let jobURL = directory.appendingPathComponent("job.json")
        var job = ((try? JSONFile.read(ToolchainJob.self, at: jobURL)) ?? nil)
            ?? ToolchainJob(
                key: key,
                productID: product.productID,
                components: tree.components,
                stage: "reading",
                taskID: taskID.rawValue,
                updated: Date(),
            )
        if job.taskID != taskID.rawValue {
            reporter.emit("resumed", .object(["stage": .string(job.stage), "previousTask": .string(job.taskID)]))
            job.taskID = taskID.rawValue
        }
        job.failure = nil
        job.toolchainID = tree.id
        let journal = JobJournal(job: job, url: jobURL)
        journal.save()
        let journalFolder = directory.appendingPathComponent("journal", isDirectory: true)
        let scratch = directory.appendingPathComponent("scratch", isDirectory: true)
        for folder in [journalFolder, scratch] {
            try layout.make(folder)
        }

        let throttle = ProgressThrottle()
        let progress: @Sendable (ToolchainBackendProgress) -> Void = { update in
            // `ready` is the record's, said once it is registered
            guard update.stage != "ready" else { return }
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
        var artifactPath: String?
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
                resumeStage: "packaging",
            )
            try reporter.checkCancelled()
            guard let installRoot = CanonicalPath.resolve(layout.installRoot) else {
                throw ApelinError(.unavailable, "the install root \(layout.installRoot) does not resolve")
            }
            guard let sdk = CanonicalPath.resolve(sdkRecord.path) else {
                throw ApelinError(
                    .notFound,
                    "The files for SDK \(sdkRecord.id) are missing. Remove the SDK and import it again.",
                )
            }

            if journal.enter("packaging") {
                reporter.stage("packaging")
            }
            let artifact = try ToolchainPackager(layout: layout).package(tree)
            artifactPath = artifact.path
            reporter.emit("artifact", encoding: artifact)

            let remembered = journal.installationID
            let install: @Sendable () async throws -> Void = {
                if journal.enter("installing") {
                    reporter.stage("installing")
                }
                // Settled, never abandoned: a cancel waits for irisind's answer.
                let result = try await Self.settled {
                    let handle = try await installer.startInstall(artifact)
                    journal.installTaskID = handle.taskID.rawValue
                    defer { journal.installTaskID = nil }
                    let result = try await installer.finishInstall(handle, reporter: reporter)
                    journal.installationID = result.installationID
                    return result
                }
                installs.add(result.installationID)
                guard result.packageID == artifact.packageID else {
                    throw ApelinError(.internal, "the bridge installed \(result.packageID), not \(artifact.packageID)")
                }
            }
            if remembered == nil {
                try await install()
            }

            let selfTests = try await backend.installAndValidate(
                tree,
                installRoot: URL(fileURLWithPath: installRoot, isDirectory: true),
                sdk: URL(fileURLWithPath: sdk, isDirectory: true),
                journal: journalFolder,
                scratch: scratch,
                install: { _ in
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
            try? FileManager.default.removeItem(at: directory)
            return record
        } catch {
            // Nothing this import installed outlives it unregistered; a
            // removal that did not go through keeps the job record, so the
            // same import run again removes or reuses it.
            let clean = await rollBack(
                installs,
                previous: nil,
                journal: journal,
                installer: installer,
                reporter: reporter,
            )
            if clean {
                try? FileManager.default.removeItem(at: directory)
            } else {
                journal.fail(String(describing: error))
            }
            throw error
        }
    }
}
