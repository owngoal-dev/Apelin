import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

/// The device's toolchains and SDKs: apelin_toolchain_list → `toolchainStatus` and
/// `toolchainCatalog`; apelin_sdk_list → `sdkList` with its sources read, and
/// `toolchainStatus` for which toolchain reads each SDK; apelin_toolchain_setup →
/// `toolchainSetup` from Apple's catalog by product ID; apelin_toolchain_self_test
/// → `toolchainSelfTest`; apelin_sdk_import → `sdkImport` of a source's branch;
/// each task read to its end with `environmentAttach`, its progress left
/// out but for the stages it went through. apelin_project_set_environment's check
/// → `projectCheck` with the candidate binding, its `environment.*`
/// findings. The host checks each again (AgentEnvironmentRules).
public extension ChannelHostBackend {
    func toolchains(context _: HostCallContext) async throws -> ToolchainListToolResponse {
        let status = try await environment("apelin_toolchain_list") { try await service.toolchainStatus() }
        let bound = Self.binding(projectURL: projectURL)
        var available: [AvailableToolchain] = []
        var problem: String?
        do {
            available = try await service.toolchainCatalog().products.map { product in
                Self.available(product, installed: status.toolchains)
            }
        } catch let error as ApelinError {
            problem = error.message.isEmpty ? error.code.rawValue : error.message
        }
        return ToolchainListToolResponse(
            installed: status.toolchains.map { Self.installed($0, defaultID: status.defaultID, boundID: bound?.toolchainID) },
            available: available,
            catalogProblem: problem,
            runningTasks: status.activeTasks.count,
            project: bound,
        )
    }

    func sdks(context _: HostCallContext) async throws -> SDKListToolResponse {
        let list = try await environment("apelin_sdk_list") { try await service.sdkList(includeSources: true, readSources: true) }
        let toolchains = await (try? service.toolchainStatus().toolchains) ?? []
        let bound = Self.binding(projectURL: projectURL)
        func readers(_ version: String) -> [String] {
            toolchains.filter { SDKVersionLimit.allows(sdkVersion: version, newestSDK: $0.newestSDK) }.map(\.id)
        }
        let registered = Set(list.sdks.map(\.version))
        var available: [AvailableSDK] = []
        var problems: [String] = []
        for source in list.sources ?? [] where source.enabled {
            if let problem = source.problem {
                problems.append("\(source.name): \(problem)")
            }
            for branch in source.branches ?? [] {
                guard let version = Self.version(ofBranch: branch, prefix: source.branchPrefix),
                      !registered.contains(version) else { continue }
                available.append(AvailableSDK(
                    version: version,
                    branch: branch,
                    source: source.name,
                    sourceURL: source.url,
                    readBy: readers(version),
                ))
            }
        }
        available.sort { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
        return SDKListToolResponse(
            installed: list.sdks.map { Self.installed($0, readBy: readers($0.version), boundID: bound?.sdkID) },
            available: available,
            sourceProblems: problems,
            project: bound,
        )
    }

    func toolchainSetup(_ request: ToolchainSetupToolRequest) async throws -> ToolchainTaskToolResponse {
        let components = request.components.compactMap(ToolchainComponentKind.init(rawValue:))
        let handle = try await environment("apelin_toolchain_setup") {
            try await service.toolchainSetup(ToolchainSetupRequest(
                source: .appleCatalog(productID: request.productID),
                components: components,
            ))
        }
        return try await toolchainTask(handle, operation: "apelin_toolchain_setup")
    }

    func toolchainSelfTest(_ request: ToolchainSelfTestToolRequest) async throws -> ToolchainTaskToolResponse {
        let handle = try await environment("apelin_toolchain_self_test") {
            try await service.toolchainSelfTest(id: request.toolchainID)
        }
        return try await toolchainTask(handle, operation: "apelin_toolchain_self_test")
    }

    func sdkImport(_ request: SDKImportToolRequest) async throws -> SDKImportToolResponse {
        let handle = try await environment("apelin_sdk_import") {
            try await service.sdkImport(.repository(url: request.url, branch: request.branch))
        }
        var stages: [String] = []
        var warnings: [String] = []
        var record: SDKRecord?
        let end = try await read(handle) { event in
            Self.take(event, stages: &stages, warnings: &warnings)
            if event.kind == "result", let sdk = try? event.payload?["sdk"]?.decode(SDKRecord.self) {
                record = sdk
            }
        }
        return SDKImportToolResponse(
            succeeded: end.state == .succeeded,
            sdk: record.map { Self.installed($0, readBy: [], boundID: nil) },
            stages: stages,
            warnings: warnings,
            message: Self.endMessage(end, operation: "apelin_sdk_import"),
        )
    }

    func checkEnvironment(_ request: EnvironmentCheckToolRequest) async throws -> EnvironmentCheckToolResponse {
        let check = try await environment("apelin_project_set_environment") {
            try await service.projectCheck(
                projectID: project.id,
                environment: ProjectEnvironmentChoice(toolchainID: request.toolchainID, sdkID: request.sdkID),
            )
        }
        guard let binding = check.environment else {
            throw EnvironmentToolFailure(message: Self.unreadProjectFailure(check.diagnostics))
        }
        return EnvironmentCheckToolResponse(
            toolchain: ComponentBinding(id: binding.toolchain.id, digest: binding.toolchain.digest),
            sdk: ComponentBinding(id: binding.sdk.id, digest: binding.sdk.digest),
            diagnostics: check.diagnostics.filter { $0.code.hasPrefix("environment.") }.map {
                EnvironmentDiagnostic(code: $0.code, severity: $0.severity.rawValue, message: $0.message)
            },
        )
    }

    // MARK: Helpers

    /// Why a switch had no binding to replace: the project file did not
    /// read. Each error with its field; then, for a manifest without the
    /// members only apelin_project_create writes, why no switch can help,
    /// else where the schema is.
    private static func unreadProjectFailure(_ diagnostics: [ProjectDiagnostic]) -> String {
        let errors = diagnostics.filter { $0.severity == .error }
        let problems = errors.map(fieldAndMessage).joined(separator: "; ")
        var message = "apelin_project_set_environment failed: the project file did not read (\(problems))."
        if errors.contains(where: { $0.code == schemaErrorCode && $0.field == "/" && createdMembers.contains($0.message) }) {
            message += " This apelin-project.json lacks the template and environment only apelin_project_create writes, so it is not an Apelin build description and no toolchain or SDK can be bound to it. An imported or empty workspace keeps \"kind\": \"workspace\" and builds with a script of its own (the apelin-external-build skill); shell_run already has the device's toolchain and SDK."
        } else if errors.contains(where: { $0.code == schemaErrorCode }) {
            message += " " + schemaPointer
        }
        return message
    }

    /// The schema errors of a description apelin_project_create did not write.
    private static let createdMembers: Set = ["missing template", "missing environment"]

    /// A setup or a self-test, read to its end.
    private func toolchainTask(_ handle: TaskHandle, operation: String) async throws -> ToolchainTaskToolResponse {
        var stages: [String] = []
        var warnings: [String] = []
        var record: ToolchainRecord?
        let end = try await read(handle) { event in
            Self.take(event, stages: &stages, warnings: &warnings)
            if event.kind == "result", let toolchain = try? event.payload?["toolchain"]?.decode(ToolchainRecord.self) {
                record = toolchain
            }
        }
        let failed = (record?.selfTests ?? []).filter { !$0.passed }.map {
            let failure = "The \($0.language) self-test failed on \($0.architecture)."
            return $0.detail.isEmpty ? failure : failure + "\n" + String($0.detail.prefix(400))
        }
        return ToolchainTaskToolResponse(
            succeeded: end.state == .succeeded,
            toolchain: record.map { Self.installed($0, defaultID: nil, boundID: nil) },
            stages: stages,
            failedTests: failed,
            warnings: warnings,
            message: Self.endMessage(end, operation: operation),
        )
    }

    /// The stages a task entered, once each in order, and its first warnings.
    private static func take(_ event: TaskEvent, stages: inout [String], warnings: inout [String]) {
        switch event.kind {
        case "stage":
            if let stage = event.payload?["stage"]?.stringValue, stages.last != stage {
                stages.append(stage)
            }
        case "warning":
            if let message = event.payload?["message"]?.stringValue, warnings.count < 10 {
                warnings.append(message)
            }
        default:
            break
        }
    }

    private static func endMessage(_ end: TaskEnd, operation: String) -> String? {
        switch end.state {
        case .succeeded: nil
        case .interrupted:
            "\(operation) was cut off when the session host stopped. A toolchain setup keeps its progress: \(operation) for the same release goes on from it. \(end.message ?? "")"
        case .cancelled: "\(operation) was cancelled. \(end.message ?? "")"
        // The call stopped following the task before it ended: the task
        // goes on in the session host, and Settings shows it.
        case .queued, .running, .waitingForApproval:
            "Stopped following \(operation); the task goes on in the session host, and apelin_toolchain_list counts it among running tasks until it ends."
        case .failed: end.message ?? "\(operation) failed"
        }
    }

    /// One environment request; a refusal comes back in words.
    private func environment<T>(_ operation: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ApelinError {
            throw EnvironmentToolFailure(
                message: "\(operation) failed: \(error.message.isEmpty ? error.code.rawValue : error.message)",
            )
        }
    }

    static func installed(_ record: ToolchainRecord, defaultID: String?, boundID: String?) -> InstalledToolchain {
        let tests = record.selfTests.map { tests in
            "\(tests.count { $0.passed }) of \(tests.count) passed"
                + (record.selfTestSDK.map { " against iPhoneOS \($0)" } ?? "")
        }
        return InstalledToolchain(
            id: record.id,
            version: record.version,
            components: record.components.filter { $0.selfCheckPassed == true }.map(\.kind.rawValue),
            newestSDK: record.newestSDK,
            selfTests: tests,
            isDefault: record.id == defaultID,
            problem: record.components.compactMap(\.problem).first ?? record.compatibility?.unavailableReason,
            outdated: record.predatesCurrentRetarget ? InstalledToolchain.earlierRetargetNote : nil,
            boundByThisProject: record.id == boundID,
        )
    }

    static func installed(_ record: SDKRecord, readBy: [String], boundID: String?) -> InstalledSDK {
        InstalledSDK(
            id: record.id,
            version: record.version,
            targets: record.targets,
            swiftCompilerVersion: record.swiftCompilerVersion,
            readBy: readBy,
            boundByThisProject: record.id == boundID,
        )
    }

    static func available(_ product: ToolchainCatalogProduct, installed: [ToolchainRecord]) -> AvailableToolchain {
        let swift = product.supportsSwift == true ? product.swiftRequirements.map { "Swift \($0.version)" } ?? "Swift" : nil
        return AvailableToolchain(
            productID: product.productID,
            version: product.version,
            sizeBytes: product.size,
            newestSDK: product.newestSDK,
            recommendedSDK: product.compatibility?.recommendedSDK,
            minimumIOS: product.compatibility?.minimumHost,
            cpuFeatures: product.compatibility?.cpuFeatures ?? [],
            swift: swift,
            swiftUnavailable: swift == nil
                ? product.swiftUnavailableReason ?? product.swiftRequirements?.unavailableReason
                : nil,
            unavailable: product.unsupportedReason,
            installedAs: installed.filter { record in
                record.origin?.split(separator: " ").first.map(String.init) == product.productID
            }.map(\.id),
        )
    }

    /// `environment.toolchain.id` and `environment.sdk.id` in the project's
    /// `apelin-project.json`; nil without one (General Chat).
    static func binding(projectURL: URL) -> ProjectEnvironmentSummary? {
        let url = projectURL.appendingPathComponent("apelin-project.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              let json = try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data)
        else { return nil }
        return ProjectEnvironmentSummary(
            toolchainID: json.value(at: "environment.toolchain.id")?.stringValue,
            sdkID: json.value(at: "environment.sdk.id")?.stringValue,
        )
    }

    /// The version a source's branch names after its prefix:
    /// `sdk/iPhoneOS18.5` is 18.5; nil for any other branch.
    static func version(ofBranch branch: String, prefix: String) -> String? {
        guard branch.hasPrefix(prefix) else { return nil }
        let name = branch.dropFirst(prefix.count)
        guard name.lowercased().hasPrefix("iphoneos") else { return nil }
        let version = String(name.dropFirst("iphoneos".count))
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { return nil }
        return version
    }
}
