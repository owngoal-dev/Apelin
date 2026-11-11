import ApelinCore
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// The session host's install bridge (Milestone 1 §8): the one place a
/// package reaches irisind, and the one place a managed package leaves.
///
/// Install: resolve the artifact (a build's, as the build worker recorded
/// it, or a file the app picked), copy it into root's private staging while
/// hashing it, refuse it unless the copy's digest is the one asked for (and
/// the build's), read its control file, apply the managed-package rules and
/// the agent's Confirm-mode rule, write the installation record with a
/// transaction ID chosen here, hand irisind the staged copy by descriptor,
/// relay its events into the task and keep its receipt. When irisind refuses
/// it, name the installed packages in its way (`InstallConflicts`), read
/// from the package database only then.
///
/// Every step that changes something is on disk first, so a host that stops
/// mid-way resumes: a staged install is submitted again under the same
/// transaction ID (irisind answers `dup` and runs nothing twice), a submitted
/// one is followed again from the last event relayed.
actor InstallBridge {
    struct Paths: Sendable {
        var installRoot: String
        /// `~/Documents/wiki.qaq.apelin`, canonical: where artifacts may live.
        var dataFolder: String
        /// Root's, 0700.
        var staging: URL
    }

    static let maximumPackageBytes: Int64 = 4 << 30
    /// irisind is on demand: a miss is retried this long before it is an answer.
    static let serviceGrace: TimeInterval = 10

    private let paths: Paths
    private let service: InstallService
    private let registry: TaskRegistry
    private let artifacts: ArtifactRegistry
    private let installations: InstallationStore
    private let packages: InstalledPackageSource
    private let fileLists: PackageFileLists
    private let approvals: ApprovalLedger
    private let pollInterval: TimeInterval
    private var checkedService = false

    init(
        paths: Paths,
        service: InstallService,
        registry: TaskRegistry,
        artifacts: ArtifactRegistry,
        installations: InstallationStore,
        packages: InstalledPackageSource,
        fileLists: PackageFileLists,
        approvals: ApprovalLedger,
        pollInterval: TimeInterval = 0.25,
    ) {
        self.paths = paths
        self.service = service
        self.registry = registry
        self.artifacts = artifacts
        self.installations = installations
        self.packages = packages
        self.fileLists = fileLists
        self.approvals = approvals
        self.pollInterval = pollInterval
    }

    // MARK: Install

    func install(_ request: InstallPackageRequest, caller: Caller) async throws -> TaskHandle {
        guard let digest = InstallDigest.normalized(request.digest) else {
            throw ApelinError(.badRequest, "digest must be the package's SHA-256: 64 hex digits")
        }

        // What is being installed, and who says so.
        let origin: InstallationRecord.Origin
        let source: String
        var artifact: ArtifactRegistry.Artifact?
        // The package ID the source promises, when the control file cannot be read.
        var expectedPackage: String?
        if let toolchain = Self.toolchainID(request.artifactID) {
            // apelin-environment's local toolchain package (or the app
            // reinstalling it): `Environment/Artifacts/<artifactID>.deb`.
            guard caller == .app || caller.isEnvironment else {
                throw ApelinError(.denied, "a toolchain package is installed by the environment worker or the app")
            }
            origin = .environment
            source = paths.dataFolder + "/Environment/Artifacts/" + request.artifactID + ".deb"
            expectedPackage = ManagedPackagePolicy.toolchainPrefix + toolchain
        } else if request.artifactID.hasPrefix("file:") {
            guard caller == .app else {
                throw ApelinError(.denied, "only the app installs a file; the agent installs build artifacts")
            }
            let relative = String(request.artifactID.dropFirst(5))
            guard CanonicalPath.isPlainRelative(relative) else {
                throw ApelinError(.badRequest, "file: takes a path inside ~/Documents/wiki.qaq.apelin")
            }
            origin = .file
            source = paths.dataFolder + "/" + relative
        } else {
            guard let found = await artifacts.artifact(request.artifactID) else {
                throw ApelinError(.notFound, "no build produced artifact \(request.artifactID)")
            }
            guard found.digest == digest else {
                throw ApelinError(.conflict, "artifact \(request.artifactID) is \(found.digest), not \(digest)")
            }
            guard caller == .app || caller.isAgent else {
                throw ApelinError(.denied, "build artifacts are installed by the app or the agent")
            }
            origin = .build
            source = found.path
            artifact = found
            expectedPackage = found.packageID
        }

        // Confirm mode, decided here whatever the agent concluded.
        if case let .worker(.agent, session) = caller {
            try await checkAgentInstall(artifact: artifact, session: session)
        }

        try await requireService()

        let installationID = UUID().uuidString.lowercased()
        let staged = paths.staging.appendingPathComponent(installationID + ".deb")
        let control: DebControlPeek.Control?
        do {
            let stagedDigest = try stage(from: source, to: staged)
            guard stagedDigest == digest else {
                throw ApelinError(
                    .conflict,
                    "the package's SHA-256 is \(stagedDigest), not \(digest); it changed after it was approved",
                )
            }
            control = try readControl(staged)
        } catch {
            unlink(staged.path)
            throw error
        }

        let packageID: String
        let version: String
        switch (control, expectedPackage) {
        case let (control?, expected):
            if let expected, expected != control.packageID {
                unlink(staged.path)
                throw ApelinError(
                    .conflict,
                    "the package was expected to be \(expected); its control file says \(control.packageID)",
                )
            }
            packageID = control.packageID
            version = control.version
        case let (nil, expected?):
            // A control member compressed with something system code cannot
            // read (zstd): judged by the ID its source promised, and checked
            // against what irisind reports once it has read the package.
            packageID = expected
            version = artifact?.version ?? ""
        default:
            unlink(staged.path)
            throw ApelinError(
                .badRequest,
                "the package's control file could not be read (gzip, xz or uncompressed control members only)",
            )
        }

        do {
            try await ManagedPackagePolicy.checkInstall(
                packageID: packageID,
                origin: origin,
                installed: packages.installedPackages(),
                records: installations.all(),
            )
        } catch {
            unlink(staged.path)
            throw error
        }

        let handle = await registry.create(kind: .install, owner: nil)
        let now = Date()
        let record = InstallationRecord(
            installationID: installationID,
            origin: origin,
            artifactID: request.artifactID,
            artifactDigest: digest,
            projectID: artifact?.projectID,
            buildID: artifact?.buildID,
            packageID: packageID,
            version: version,
            packagingDigest: artifact?.packagingDigest,
            transactionID: UUID().uuidString.lowercased(),
            taskID: handle.taskID.rawValue,
            status: .staged,
            createdAt: now,
            updatedAt: now,
            followedSeq: 0,
            receipt: nil,
            removalTransactionID: nil,
            removalTaskID: nil,
            removalReceipt: nil,
        )
        do {
            try await installations.save(record)
        } catch {
            unlink(staged.path)
            await registry.finish(handle.taskID, .failed, message: Self.message(error))
            throw error
        }
        await registry.setResume(handle.taskID, .object(["installationID": .string(installationID)]))
        await registry.append(handle.taskID, kind: "stage", payload: .object([
            "stage": .string("staged"), "installationID": .string(installationID), "packageID": .string(packageID),
            "version": .string(version), "digest": .string(digest), "transactionID": .string(record.transactionID),
        ]))
        Task { await self.runInstall(installationID, taskID: handle.taskID) }
        return handle
    }

    /// Who is in the way of the install irisind just refused: the package's
    /// files as its build recorded them and its control's relations, against
    /// the package database as it is now.
    private func conflicts(
        blocking record: InstallationRecord,
        staged: URL,
    ) async -> (found: [InstallConflict], explanation: String?) {
        let files = await artifacts.artifact(record.artifactID)?.packageFiles ?? []
        let control = try? readControl(staged)
        guard let installed = try? packages.installedPackages() else { return ([], nil) }
        let found = await InstallConflicts.find(
            packageID: record.packageID,
            packageFiles: files,
            control: control,
            installed: installed,
            lists: fileLists,
            records: installations.all(),
        )
        return (found, InstallConflicts.explanation(found, installed: installed))
    }

    private func checkAgentInstall(artifact: ArtifactRegistry.Artifact?, session: String?) async throws {
        guard let artifact else { throw ApelinError(.denied, "the agent installs build artifacts only") }
        guard await approvals.mode(session: session).asks else { return }
        guard let project = artifact.projectID, let packaging = artifact.packagingDigest else {
            throw ApelinError(
                .denied,
                "approval required: the build recorded no packaging digest for \(artifact.artifactID), so the host cannot tell it matches the template",
            )
        }
        guard try await approvals.allows(packaging, kind: .packaging, project: project) else {
            throw ApelinError(
                .denied,
                "approval required: the packaging description \(packaging) of project \(project) changed since the template and was never approved",
            )
        }
    }

    private func runInstall(_ installationID: String, taskID: TaskID) async {
        guard var record = await installations.record(installationID) else {
            await registry.finish(taskID, .failed, message: "This installation could not be found. Try again.")
            return
        }
        guard let transaction = UUID(uuidString: record.transactionID) else {
            await registry.finish(taskID, .failed, message: "This installation's details are damaged. Install the package again.")
            return
        }
        let staged = paths.staging.appendingPathComponent(installationID + ".deb")
        // The package ID its source promised, before irisind names its own.
        let expected = record.packageID
        defer {
            if record.status != .staged {
                unlink(staged.path)
            }
        }

        do {
            if record.status == .staged {
                let descriptor = open(staged.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else {
                    throw ApelinError(.internal, "The package to install could not be found. Install it again.")
                }
                defer { close(descriptor) }
                let status = try await withServiceGrace {
                    try await self.service.submitInstall(
                        transaction: transaction,
                        descriptor: descriptor,
                        sha256: record.artifactDigest,
                    )
                }
                record = try await installations.update(installationID) { $0.status = .submitted }
                await registry.append(taskID, kind: "stage", payload: .object([
                    "stage": .string("submitted"),
                    "transactionID": .string(record.transactionID),
                    "duplicate": .bool(status.duplicate),
                ]))
            }
            let final = try await follow(
                transaction,
                after: record.followedSeq,
                taskID: taskID,
                installationID: installationID,
            )
            let receipt = Self.receipt(final)
            if final.state == .succeeded {
                record = try await installations.update(installationID) {
                    $0.status = .installed
                    $0.receipt = receipt
                    $0.packageID = final.packageID ?? $0.packageID
                    if let version = final.version, !version.isEmpty {
                        $0.version = version
                    }
                }
                await finishInstalled(record, expecting: expected, taskID: taskID)
            } else if landed(record) {
                // irisind lost track of an install that went through: the
                // package database has the last word.
                record = try await installations.update(installationID) {
                    $0.status = .installed
                    $0.receipt = receipt
                    $0.receipt?.confirmed = true
                }
                await noteLanded(record, after: Self.unfinished(final), taskID: taskID)
                await finishInstalled(record, expecting: expected, taskID: taskID)
            } else {
                record = try await installations.update(installationID) {
                    $0.status = .failed
                    $0.receipt = receipt
                }
                let inTheWay = await conflicts(blocking: record, staged: staged)
                for conflict in inTheWay.found {
                    await registry.append(taskID, kind: "conflict", payload: try? JSONValue(encoding: conflict))
                }
                var message = final.failureText ?? Self.unfinished(final)
                    + ", and \(record.packageID) \(record.version) is not installed. Try again."
                if let explanation = inTheWay.explanation {
                    message = final.failureText.map { "\(explanation) Irisin reported: \($0)" } ?? explanation
                }
                await registry.finish(taskID, .failed, message: message)
            }
        } catch {
            if record.status == .staged {
                record.status = .failed
                _ = try? await installations.update(installationID) { $0.status = .failed }
            }
            // Submitted, then irisind could no longer be followed: it may
            // have finished all the same.
            if record.status == .submitted, landed(record),
               let installed = try? await installations.update(installationID, {
                   $0.status = .installed
                   $0.receipt = InstallationRecord.Receipt(
                       state: "unknown",
                       failureText: Self.message(error),
                       finishedAt: Date(),
                       confirmed: true,
                   )
               })
            {
                record = installed
                await noteLanded(record, after: Self.message(error), taskID: taskID)
                await finishInstalled(record, expecting: expected, taskID: taskID)
                return
            }
            await registry.finish(taskID, .failed, message: Self.message(error))
        }
    }

    /// Whether the package database shows this install done, whatever
    /// irisind answered: the package installed at the version submitted,
    /// its file list written since the installation was recorded. A
    /// reinstall of the version already there writes the list again, so it
    /// counts; a package that was there all along does not.
    private func landed(_ record: InstallationRecord) -> Bool {
        guard let current = try? packages.installedPackages()[record.packageID], current.isInstalled,
              current.version == record.version,
              let written = fileLists.written(of: record.packageID)
        else { return false }
        // A file's time is kept to the second on some volumes.
        return written.timeIntervalSince(record.createdAt) > -1
    }

    private func noteLanded(_ record: InstallationRecord, after problem: String, taskID: TaskID) async {
        NSLog("apelind-session: %@ %@ is installed although: %@", record.packageID, record.version, problem)
        await registry.append(taskID, kind: "stage", payload: .object([
            "stage": .string("confirmed"),
            "note": .string(
                "\(problem). The package database shows \(record.packageID) \(record.version) installed, so the installation is recorded.",
            ),
        ]))
    }

    /// What irisind's last status says of an install it did not call a
    /// success and gave no text for.
    private static func unfinished(_ status: InstallTransactionStatus) -> String {
        let exit = status.exitStatus.map { ", exit status \($0)" } ?? ""
        return "Irisin ended the installation as \(status.state.rawValue)\(exit) without saying why"
    }

    /// The task's end for a record now installed.
    private func finishInstalled(_ record: InstallationRecord, expecting expected: String, taskID: TaskID) async {
        // irisind read a different package than its source promised:
        // installed (and recorded, so it can be removed), but loudly.
        guard record.packageID == expected else {
            await registry.finish(
                taskID,
                .failed,
                message: "Installed \(record.packageID) instead of \(expected). Details are saved in installation \(record.installationID).",
            )
            return
        }
        let result = InstallResult(
            installationID: record.installationID,
            transactionID: record.transactionID,
            packageID: record.packageID,
            version: record.version,
            artifactDigest: record.artifactDigest,
            projectID: record.projectID,
            buildID: record.buildID,
        )
        let resultValue = try? JSONValue(encoding: result)
        await registry.append(taskID, kind: "result", payload: resultValue)
        // The last event carries the result too, for a reader that only keeps the last.
        await registry.append(taskID, kind: TaskEvent.stateKind, payload: .object([
            "state": .string(TaskState.succeeded.rawValue), "result": resultValue ?? .null,
        ]))
    }

    // MARK: Remove

    func remove(_ request: RemovePackageRequest, caller: Caller) async throws -> TaskHandle {
        guard InstallationStore.validID(request.installationID) else {
            throw ApelinError(.badRequest, "an installation ID is the lowercase UUID returned by the install")
        }
        let record = await installations.record(request.installationID)
        try await ManagedPackagePolicy.checkRemoval(
            record,
            installed: packages.installedPackages(),
            records: installations.all(),
        )
        guard var record else { throw ApelinError(.notFound, "no installation \(request.installationID)") }
        try Self.checkRemover(caller, of: record)

        // Removal is confirmed every time under Confirm (§7), whatever was approved before.
        if case let .worker(.agent, session) = caller, await approvals.mode(session: session).asks {
            guard let session,
                  await approvals.takeRemoval(installationID: record.installationID, session: session)
            else {
                throw ApelinError(
                    .denied,
                    "approval required: removing \(record.packageID) needs the user's approval for this removal",
                )
            }
        }

        try await requireService()
        let handle = await registry.create(kind: .install, owner: nil)
        do {
            record = try await installations.update(record.installationID) {
                $0.status = .removing
                $0.removalTransactionID = UUID().uuidString.lowercased()
                $0.removalTaskID = handle.taskID.rawValue
                $0.followedSeq = 0
            }
        } catch {
            await registry.finish(handle.taskID, .failed, message: Self.message(error))
            throw error
        }
        await registry.setResume(
            handle.taskID,
            .object(["installationID": .string(record.installationID), "removal": .bool(true)]),
        )
        await registry.append(handle.taskID, kind: "stage", payload: .object([
            "stage": .string("removing"), "installationID": .string(record.installationID),
            "packageID": .string(record.packageID), "transactionID": .string(record.removalTransactionID ?? ""),
        ]))
        Task { await self.runRemoval(record.installationID, taskID: handle.taskID) }
        return handle
    }

    private func runRemoval(_ installationID: String, taskID: TaskID) async {
        guard let record = await installations.record(installationID),
              let transaction = record.removalTransactionID.flatMap(UUID.init(uuidString:))
        else {
            await registry.finish(taskID, .failed, message: "This installation could not be found. Try again.")
            return
        }
        do {
            // Submitting again under the same ID is safe: irisind answers `dup`.
            _ = try await withServiceGrace {
                try await self.service.removePackage(transaction: transaction, packageID: record.packageID)
            }
            let final = try await follow(
                transaction,
                after: record.followedSeq,
                taskID: taskID,
                installationID: installationID,
            )
            let receipt = Self.receipt(final)
            if final.state == .succeeded {
                try await installations.update(installationID) {
                    $0.status = .removed
                    $0.removalReceipt = receipt
                }
                if let line = pruneToolchainTree(of: record.packageID) {
                    await registry.append(taskID, kind: "log", payload: .object(["line": .string(line)]))
                }
                let removed: JSONValue = .object([
                    "installationID": .string(installationID), "packageID": .string(record.packageID),
                    "transactionID": .string(transaction.uuidString.lowercased()),
                ])
                await registry.append(taskID, kind: "removed", payload: removed)
                await registry.append(taskID, kind: TaskEvent.stateKind, payload: .object([
                    "state": .string(TaskState.succeeded.rawValue), "removed": removed,
                ]))
            } else {
                try await installations.update(installationID) {
                    $0.status = .installed
                    $0.removalReceipt = receipt
                }
                await registry.finish(
                    taskID,
                    .failed,
                    message: final.failureText ?? "Irisin could not remove the package. Try again.",
                )
            }
        } catch {
            await registry.finish(taskID, .failed, message: Self.message(error))
        }
    }

    /// Who removes what, beyond `ManagedPackagePolicy`: the app any record;
    /// the agent what a build installed, as it installs nothing else; the
    /// environment worker its toolchains only.
    private static func checkRemover(_ caller: Caller, of record: InstallationRecord) throws {
        switch caller {
        case .app:
            return
        case .worker(.agent, _):
            switch record.origin {
            case .build:
                return
            case .environment:
                throw ApelinError(.denied, "Apelin's toolchain packages are removed in Settings, not by the agent.")
            case .file:
                throw ApelinError(
                    .denied,
                    "This package was installed from a file, not by a project's build, so the agent cannot remove it. Remove it with your preferred package manager.",
                )
            }
        case .worker(.environment, _):
            guard record.origin == .environment else {
                throw ApelinError(
                    .denied,
                    "the environment worker removes the toolchain packages it installed, nothing else",
                )
            }
        case .worker:
            throw ApelinError(.denied, "removePackage is not available to this caller")
        }
    }

    // MARK: List

    /// Per package still on the device, the newest record this bridge
    /// installed it under, newest first, each with whether `remove` from
    /// this caller would act on it and, if not, the refusal it would give.
    func list(_ request: InstallationListRequest, caller: Caller) async throws -> InstallationListResponse {
        let installed = try packages.installedPackages()
        let records = await installations.all()
        var newest: [String: InstallationRecord] = [:]
        // Oldest first: a later install of a package supersedes an earlier
        // one, and a removal under way is listed as that, not as the
        // install before it.
        for record in records where record.status == .installed || record.status == .removing {
            newest[record.packageID] = record
        }
        let listed = newest.values.filter {
            installed[$0.packageID]?.isInstalled == true
                && (request.packageID == nil || $0.packageID == request.packageID)
                && (request.projectID == nil || $0.projectID == request.projectID)
        }
        return InstallationListResponse(installations: listed.sorted { $0.createdAt > $1.createdAt }.map { record in
            var refusal: String?
            do {
                try ManagedPackagePolicy.checkRemoval(record, installed: installed, records: records)
                try Self.checkRemover(caller, of: record)
            } catch {
                refusal = Self.message(error)
            }
            return InstallationSummary(
                installationID: record.installationID,
                packageID: record.packageID,
                version: record.version,
                projectID: record.projectID,
                buildID: record.buildID,
                installedAt: record.receipt?.finishedAt ?? record.createdAt,
                removable: refusal == nil,
                reason: refusal,
            )
        })
    }

    // MARK: Toolchain folders

    /// After a toolchain package's removal: the folders roothide's `.jbroot`
    /// links kept from going (`ToolchainTreePruner`). Answers the line for
    /// the removal's log; nil for another package, or nothing left behind.
    private func pruneToolchainTree(of packageID: String) -> String? {
        guard let id = ToolchainTreePruner.toolchainID(packageID: packageID) else { return nil }
        let folder = "usr/lib/apelin/toolchains/" + id
        switch ToolchainTreePruner.prune(installRoot: paths.installRoot, id: id) {
        case .pruned: return "Removed the empty folders the toolchain left in \(folder)."
        case .absent: return nil
        case let .kept(reason): return "Left \(folder) in place: \(reason)."
        }
    }

    /// At start, before anything can install: the folders left behind by
    /// every toolchain whose package is not on the device and that no
    /// install or removal still handles — after a removal nothing pruned (an
    /// earlier Apelin's, or one cut short), or files taken away outside
    /// Apelin. A tree whose package dpkg lists is dpkg's, and stays.
    func pruneLeftoverToolchains() async {
        // Without the package list, a tree in use cannot be told apart.
        guard let database = try? packages.installedPackages() else { return }
        let handled = await Set(installations.all().filter {
            [.staged, .submitted, .removing].contains($0.status)
        }.map(\.packageID))
        for id in ToolchainTreePruner.toolchainIDs(installRoot: paths.installRoot) {
            let packageID = ManagedPackagePolicy.toolchainPrefix + id
            // dpkg may keep a removed package's stanza, as `… not-installed`.
            if let entry = database[packageID], !entry.status.hasSuffix(" not-installed") {
                continue
            }
            guard !handled.contains(packageID) else { continue }
            if ToolchainTreePruner.prune(installRoot: paths.installRoot, id: id) == .pruned {
                NSLog("apelind-session: removed the empty folders toolchain %@ left", id)
            }
        }
    }

    // MARK: Respring

    func respring() async throws {
        try await requireService()
        _ = try await withServiceGrace { try await self.service.respring(transaction: UUID()) }
    }

    // MARK: Resume

    /// Picks up an install or removal task the previous host left running.
    func resume(_ record: TaskRegistry.Record) async -> Bool {
        guard let installationID = record.resume?["installationID"]?.stringValue,
              let installation = await installations.record(installationID) else { return false }
        await registry.append(record.id, kind: "stage", payload: .object(["stage": .string("resumed")]))
        if record.resume?["removal"]?.boolValue == true {
            guard installation.status == .removing else { return false }
            Task { await self.runRemoval(installationID, taskID: record.id) }
            return true
        }
        guard installation.status == .staged || installation.status == .submitted else { return false }
        Task { await self.runInstall(installationID, taskID: record.id) }
        return true
    }

    /// Records whose task ended before irisind did (the host lost contact):
    /// ask irisind how the transaction ended and keep the receipt.
    func reconcile() async {
        for record in await installations.all() where record.status == .submitted || record.status == .removing {
            let removing = record.status == .removing
            guard let transaction = (removing ? record.removalTransactionID : record.transactionID).flatMap(UUID.init(uuidString:)),
                  let task = (removing ? record.removalTaskID : record.taskID).map({ TaskID(rawValue: $0) }),
                  await registry.record(task)?.state.isTerminal ?? true,
                  let status = try? await service.status(of: transaction), status.state.isFinished else { continue }
            let receipt = Self.receipt(status)
            _ = try? await installations.update(record.installationID) {
                if removing {
                    $0.status = status.state == .succeeded ? .removed : .installed
                    $0.removalReceipt = receipt
                } else {
                    $0.status = status.state == .succeeded ? .installed : .failed
                    $0.receipt = receipt
                }
            }
        }
    }

    // MARK: Helpers

    /// Relays irisind's events into the task until the transaction ends.
    private func follow(
        _ transaction: UUID,
        after: UInt64,
        taskID: TaskID,
        installationID: String,
    ) async throws -> InstallTransactionStatus {
        var cursor = after
        var missingSince: Date?
        while true {
            do {
                let batch = try await service.events(of: transaction, after: cursor)
                missingSince = nil
                for event in batch.events where event.sequence > cursor {
                    await registry.append(taskID, kind: "irisin", payload: Self.payload(event))
                    cursor = event.sequence
                }
                if !batch.events.isEmpty {
                    _ = try? await installations.update(installationID) { $0.followedSeq = cursor }
                }
                if batch.status.state.isFinished, cursor + 1 >= batch.status.nextSequence {
                    return batch.status
                }
                if !batch.events.isEmpty, cursor + 1 < batch.status.nextSequence {
                    continue
                }
            } catch let error as InstallServiceError where error.isTransient {
                let since = missingSince ?? Date()
                missingSince = since
                if Date().timeIntervalSince(since) > 60 {
                    throw error
                }
            }
            if let record = await registry.record(taskID), record.state.isTerminal {
                throw ApelinError(.cancelled, "the task ended")
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    private func withServiceGrace<T>(_ body: () async throws -> T) async throws -> T {
        let start = Date()
        while true {
            do {
                return try await body()
            } catch let error as InstallServiceError
                where error.isTransient && Date().timeIntervalSince(start) < Self.serviceGrace
            {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func requireService() async throws {
        guard !checkedService else { return }
        let info: InstallServiceInfo
        do {
            info = try await withServiceGrace { try await self.service.serviceInfo() }
        } catch let error as InstallServiceError {
            switch error.code {
            case .unavailable, .interrupted:
                throw ApelinError(
                    .unavailable,
                    "Irisin is not responding. Make sure Irisin \(InstallServiceRequirement.minimumIrisin) or later is installed, then try again.",
                )
            default: throw ApelinError(.unavailable, Self.message(error))
            }
        }
        let missing = InstallServiceRequirement.capabilities.subtracting(info.capabilities)
        guard missing.isEmpty else {
            NSLog("apelind-session: irisind lacks %@", missing.sorted().joined(separator: ", "))
            throw ApelinError(
                .unavailable,
                "This version of Irisin cannot install packages for Apelin. Update Irisin, then try again.",
            )
        }
        guard Self.sameRoot(info.installRoot, paths.installRoot) else {
            throw ApelinError(
                .unavailable,
                "Irisin installs to \(info.installRoot), but Apelin is installed in \(paths.installRoot). Make sure Apelin and Irisin are installed in the same location, then try again.",
            )
        }
        checkedService = true
    }

    private static func sameRoot(_ a: String, _ b: String) -> Bool {
        (CanonicalPath.resolve(a) ?? a) == (CanonicalPath.resolve(b) ?? b)
    }

    /// Copies `source` into `staged` (a new file root owns), hashing as it
    /// goes; answers the copy's digest. The source must be a regular file
    /// whose open descriptor still lies inside the data folder.
    private func stage(from source: String, to staged: URL) throws -> String {
        guard !CanonicalPath.containsNUL(source) else { throw ApelinError(.badRequest, "the path contains a NUL byte") }
        let input = open(source, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw ApelinError(.notFound, "\(source): \(String(cString: strerror(errno)))") }
        defer { close(input) }
        // Where the descriptor actually is, after every link in the path was
        // followed: a mobile-writable folder swapped for a link cannot send
        // the host to read another file.
        guard let opened = FileScopes.descriptorPath(input), let folder = CanonicalPath.resolve(paths.dataFolder),
              CanonicalPath.isCanonical(opened, inside: folder)
        else {
            throw ApelinError(.denied, "an artifact lives inside ~/Documents/wiki.qaq.apelin")
        }
        var metadata = stat()
        guard fstat(input, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ApelinError(.badRequest, "\(source) is not a regular file")
        }
        guard metadata.st_size > 0, Int64(metadata.st_size) <= Self.maximumPackageBytes else {
            throw ApelinError(.badRequest, "a package must be 1 byte to \(Self.maximumPackageBytes >> 30) GiB")
        }
        try FileManager.default.createDirectory(
            at: paths.staging,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        let output = open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ApelinError(.internal, "staging: \(String(cString: strerror(errno)))") }
        defer { close(output) }
        var hash = SHA256()
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        var offset: off_t = 0
        while true {
            let count = pread(input, buffer, size, offset)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw ApelinError(.internal, "reading \(source): \(String(cString: strerror(errno)))")
            }
            if count == 0 {
                break
            }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            var written = 0
            while written < count {
                let result = write(output, buffer.advanced(by: written), count - written)
                if result < 0, errno == EINTR {
                    continue
                }
                guard result > 0 else { throw ApelinError(.internal, "staging: \(String(cString: strerror(errno)))") }
                written += result
            }
            offset += off_t(count)
            guard Int64(offset) <= Self.maximumPackageBytes else {
                throw ApelinError(.badRequest, "a package is at most \(Self.maximumPackageBytes >> 30) GiB")
            }
        }
        guard fsync(output) == 0 else { throw ApelinError(.internal, "staging: \(String(cString: strerror(errno)))") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readControl(_ staged: URL) throws -> DebControlPeek.Control? {
        let descriptor = open(staged.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApelinError(.internal, "The package to install could not be found. Install it again.")
        }
        defer { close(descriptor) }
        do {
            return try DebControlPeek.read(descriptor: descriptor)
        } catch DebControlPeek.Failure.notADebian {
            throw ApelinError(.badRequest, "the artifact is not a Debian package")
        } catch {
            return nil
        }
    }

    /// `toolchain-<id>` → `<id>` (lowercase letters, digits, `.` and `-`).
    static func toolchainID(_ artifactID: String) -> String? {
        guard artifactID.hasPrefix("toolchain-") else { return nil }
        let id = String(artifactID.dropFirst(10))
        guard !id.isEmpty,
              id.count <= 128,
              !id.hasPrefix("."),
              id.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 122).contains($0) || (65 ... 90).contains($0)
                      || $0 == 45 || $0 == 46
              })
        else { return nil }
        return id.lowercased()
    }

    private static func receipt(_ status: InstallTransactionStatus) -> InstallationRecord.Receipt {
        InstallationRecord.Receipt(
            state: status.state.rawValue,
            exitStatus: status.exitStatus,
            packageID: status.packageID,
            version: status.version,
            failure: status.failure,
            failureText: status.failureText,
            finishedAt: Date(),
        )
    }

    private static func payload(_ event: InstallTransactionEvent) -> JSONValue {
        var fields: [String: JSONValue] = [
            "seq": .number(Double(event.sequence)),
            "kind": .string(event.kind),
            "text": .string(event.text),
        ]
        if let value = event.phase {
            fields["phase"] = .string(value)
        }
        if let value = event.step {
            fields["step"] = .string(value)
        }
        if let value = event.packageID {
            fields["package"] = .string(value)
        }
        if let value = event.version {
            fields["version"] = .string(value)
        }
        if let value = event.completed {
            fields["done"] = .number(Double(value))
        }
        if let value = event.total {
            fields["total"] = .number(Double(value))
        }
        if let value = event.exitStatus {
            fields["exit"] = .number(Double(value))
        }
        if let value = event.problem {
            fields["problem"] = .string(value)
        }
        return .object(fields)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? ApelinError {
            return error.message.isEmpty ? error.code.rawValue : error.message
        }
        if let error = error as? InstallServiceError {
            return error.message.isEmpty ? error.description : error.message
        }
        return String(describing: error)
    }
}
