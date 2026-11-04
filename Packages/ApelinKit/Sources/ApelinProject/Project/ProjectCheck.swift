import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// `projectCheck` (Milestone 1 §5.4): structured diagnostics — a code, a
/// severity, the field or file, the fixes the UI or the agent may offer —
/// run after creation, before every build and after the environment
/// changes. An error blocks the build; a warning does not. Nothing here
/// writes anything.
public struct ProjectCheck: Sendable {
    public var store: ProjectStore
    public var catalog: ExtensionCatalog
    public var registry: EnvironmentRegistry
    /// The install root the session host assigned: whether the device runs
    /// what a toolchain builds at all (`HostSigning`) is decided under it.
    /// Nil checks the project alone.
    public var installRoot: String?

    /// Below this much free space a build fails; below `lowSpace` it warns.
    public var minimumSpace: UInt64 = 64 << 20
    public var lowSpace: UInt64 = 512 << 20

    public init(
        store: ProjectStore,
        catalog: ExtensionCatalog,
        registry: EnvironmentRegistry,
        installRoot: String? = nil,
    ) {
        self.store = store
        self.catalog = catalog
        self.registry = registry
        self.installRoot = installRoot
    }

    public struct Result: Sendable {
        public var diagnostics: [ProjectDiagnostic]
        public var digests: ApprovalDigests?
        /// The document the digests were cut from, once it parsed and validated.
        public var project: ProjectDocument?

        public var passed: Bool {
            !diagnostics.contains { $0.severity == .error }
        }
    }

    /// `environment`, when given, stands in for the binding the project file
    /// names: the check a switch to it would pass or fail, before anything is
    /// written. The description digests do not include the binding.
    public func run(projectID: String, environment: ProjectDocument.EnvironmentBinding? = nil) -> Result {
        do {
            let (_, root) = try store.root(of: projectID)
            return run(root: root, environment: environment)
        } catch {
            return Result(diagnostics: [
                ProjectDiagnostic(code: "project.notFound", severity: .error, message: String(describing: error)),
            ])
        }
    }

    /// The binding `choice` names, resolved in the registry: its digests are
    /// the registry's, and a component it names that is not registered is
    /// `notFound`. A nil component keeps the one `current` binds.
    public func binding(
        _ choice: ProjectEnvironmentChoice,
        replacing current: ProjectDocument.EnvironmentBinding,
    ) throws -> ProjectDocument.EnvironmentBinding {
        var binding = current
        if let id = choice.toolchainID {
            guard let toolchain = try registry.toolchain(id) else {
                throw ApelinError(.notFound, "toolchain \(id) is not registered on this device")
            }
            binding.toolchain = ProjectDocument.Binding(id: toolchain.id, digest: toolchain.digest)
        }
        if let id = choice.sdkID {
            guard let sdk = try registry.sdk(id) else {
                throw ApelinError(.notFound, "SDK \(id) is not registered on this device")
            }
            binding.sdk = ProjectDocument.Binding(id: sdk.id, digest: sdk.digest)
        }
        return binding
    }

    public func run(root: URL, environment: ProjectDocument.EnvironmentBinding? = nil) -> Result {
        var out: [ProjectDiagnostic] = []
        func add(
            _ code: String,
            _ severity: DiagnosticSeverity,
            _ message: String,
            file: String? = nil,
            field: String? = nil,
            fixes: [String] = [],
        ) {
            out.append(ProjectDiagnostic(
                code: code,
                severity: severity,
                message: message,
                file: file,
                field: field,
                fixes: fixes,
            ))
        }

        // 1. The format and every input path.
        let data: Data
        do {
            data = try ProjectFiles.read(ProjectStore.projectFileName, in: root)
        } catch {
            add("project.unreadable", .error, String(describing: error), file: ProjectStore.projectFileName)
            return Result(diagnostics: out)
        }
        let document: JSONDocument
        do {
            document = try StrictJSON.parse(data)
        } catch {
            add("project.json", .error, String(describing: error), file: ProjectStore.projectFileName)
            return Result(diagnostics: out)
        }
        let problems = ProjectValidation.errors(document)
        guard problems.isEmpty, var project = try? ProjectDocument(document: document) else {
            for problem in problems {
                let (field, message) = Self.split(problem)
                add("project.invalid", .error, message, file: ProjectStore.projectFileName, field: field)
            }
            return Result(diagnostics: out)
        }
        if let environment {
            project.environment = environment
        }
        var digests: ApprovalDigests?
        do {
            digests = try ApprovalDigests.compute(document, root: root)
        } catch {
            add(
                "project.description.uncomputable",
                .error,
                "the build or packaging description cannot be computed: \(error)",
                file: ProjectStore.projectFileName,
                fixes: ["openProjectFile"],
            )
        }

        for (index, product) in project.products.enumerated() {
            let field = "/products/\(index)"
            for pattern in product.sources {
                checkGlob(pattern, root: root, field: "\(field)/sources", add: add)
            }
            for pattern in product.resources ?? [] {
                checkGlob(pattern, root: root, field: "\(field)/resources", add: add)
            }
            for path in product.headerSearchPaths ?? [] {
                checkDirectory(path, root: root, field: "\(field)/headerSearchPaths", add: add)
            }
            for path in (product.frameworkSearchPaths ?? []) + (product.librarySearchPaths ?? []) {
                checkDirectory(path, root: root, field: "\(field)/searchPaths", add: add)
            }
            for (key, path) in [("infoPlist", product.infoPlist), ("entitlements", product.entitlements)] {
                guard let path else { continue }
                do {
                    let contents = try ProjectFiles.read(path, in: root)
                    if (try? PropertyListSerialization.propertyList(from: contents, format: nil)) == nil {
                        add(
                            "project.plist.invalid",
                            .error,
                            "\(path) is not a property list",
                            file: path,
                            field: "\(field)/\(key)",
                        )
                    }
                } catch {
                    add(
                        "project.file.missing",
                        .error,
                        String(describing: error),
                        file: path,
                        field: "\(field)/\(key)",
                        fixes: ["openProjectFile"],
                    )
                }
            }
        }
        for (index, entry) in project.package.layout.enumerated() {
            if let file = entry.file, (try? ProjectFiles.read(file, in: root)) == nil {
                add(
                    "package.file.missing",
                    .error,
                    "\(file) is not a regular file inside the project",
                    file: file,
                    field: "/package/layout/\(index)/file",
                )
            }
        }
        for (script, path) in project.package.maintainerScripts?.all ?? [] {
            guard let contents = try? ProjectFiles.read(path, in: root) else {
                add(
                    "package.script.missing",
                    .error,
                    "\(path) is not a regular file inside the project",
                    file: path,
                    field: "/package/maintainerScripts/\(script)",
                )
                continue
            }
            if String(data: contents, encoding: .utf8) == nil {
                add(
                    "package.script.encoding",
                    .error,
                    "\(path) is not UTF-8 text",
                    file: path,
                    field: "/package/maintainerScripts/\(script)",
                )
            }
        }
        for (index, step) in project.build.steps.enumerated() {
            if case let .script(id, _, file, _, _, _) = step {
                if (try? ProjectFiles.read(file, in: root)) == nil {
                    add(
                        "build.script.missing",
                        .error,
                        "script \(id): \(file) is not a regular file inside the project",
                        file: file,
                        field: "/build/steps/\(index)/file",
                    )
                }
                add(
                    "build.script.reviewed",
                    .note,
                    "script \(id) runs project code as the mobile user in the project folder; in Strict mode, its contents are reviewed with the build description",
                    file: file,
                    field: "/build/steps/\(index)",
                )
            }
        }

        // 2. The toolchain and the SDK, and what the project asks of them.
        let toolchain = (try? registry.toolchain(project.environment.toolchain.id)) ?? nil
        if let reason = installRoot.flatMap({ HostSigning.toolchainRefusal(installRoot: $0) })
            ?? toolchain?.compatibility?.unavailableReason
            ?? HostCPU.toolchainRefusal
        {
            add("environment.device.toolchain", .error, reason, field: "/environment/toolchain")
        }
        if let toolchain {
            if toolchain.digest != project.environment.toolchain.digest {
                add(
                    "environment.toolchain.changed",
                    .error,
                    "toolchain \(toolchain.id) was registered again with other contents; rebind the project to use it",
                    field: "/environment/toolchain",
                    fixes: ["rebindToolchain"],
                )
            }
            let tools = ["clang", "lipo", "dsymutil", "strip"] + (project.language == .swift ? ["swiftc"] : [])
            for tool in tools where access(toolchain.tool(tool).path, X_OK) != 0 {
                add(
                    "environment.toolchain.incomplete",
                    .error,
                    "toolchain \(toolchain.id) has no runnable \(tool)",
                    field: "/environment/toolchain",
                    fixes: ["repairToolchain"],
                )
            }
            if project.language == .swift, !toolchain.components.contains("swift") {
                add(
                    "environment.toolchain.noSwift",
                    .error,
                    "toolchain \(toolchain.id) was set up without the Swift component",
                    field: "/language",
                    fixes: ["addSwiftComponent"],
                )
            }
        } else {
            add(
                "environment.toolchain.missing",
                .error,
                "toolchain \(project.environment.toolchain.id) is not registered",
                field: "/environment/toolchain",
                fixes: ["setUpToolchain", "rebindToolchain"],
            )
        }
        // The tools' machine code is the M1's (`HostCPU`): on an older CPU
        // Swift, and clang building a module, stop on an illegal instruction.
        if project.language == .swift {
            let refusal: String? = if let requirements = toolchain?.swiftRequirements {
                requirements.unavailableReason
            } else {
                HostCPU.swiftRefusal
            }
            if let refusal {
                add("environment.device.swift", .error, refusal, field: "/language")
            }
        }
        let modules = [project.configurations.Debug, project.configurations.Release].contains { configuration in
            (configuration.cFlags ?? []).contains { $0.hasPrefix("-fmodules") || $0.hasPrefix("-fcxx-modules") }
        }
        if modules, !(toolchain?.clangModuleCPUFeatures ?? ["FEAT_SHA3"]).allSatisfy(HostCPU.has) {
            add(
                "environment.device.clangModules",
                .error,
                "clang modules (-fmodules, @import) cannot be built on this device: Apple's clang uses an "
                    + "instruction its CPU lacks (FEAT_SHA3, from the A13 on); drop the flag and #import headers",
                field: "/configurations",
            )
        }
        let sdk = (try? registry.sdk(project.environment.sdk.id)) ?? nil
        if let sdk {
            if sdk.digest != project.environment.sdk.digest {
                add(
                    "environment.sdk.changed",
                    .error,
                    "SDK \(sdk.id) was registered again with other contents; rebind the project to use it",
                    field: "/environment/sdk",
                    fixes: ["rebindSDK"],
                )
            }
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: sdk.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                add(
                    "environment.sdk.gone",
                    .error,
                    "SDK \(sdk.id) is registered at \(sdk.path), which no longer exists; import the SDK again",
                    field: "/environment/sdk",
                    fixes: ["importSDK"],
                )
            }
            if sdk.version.compare(project.deploymentTarget, options: .numeric) == .orderedAscending {
                add(
                    "environment.sdk.tooOld",
                    .warning,
                    "SDK \(sdk.version) is older than the deployment target \(project.deploymentTarget); only APIs declared by that SDK are available",
                    field: "/deploymentTarget",
                    fixes: ["rebindSDK", "rebindToolchain"],
                )
            }
            if let toolchain, !toolchain.reads(sdkVersion: sdk.version) {
                add(
                    "environment.sdk.tooNewForToolchain",
                    .error,
                    "toolchain \(toolchain.id) (Command Line Tools \(toolchain.version)) supports iPhoneOS SDKs up to "
                        + "\(toolchain.newestSDK ?? sdk.version); SDK \(sdk.version) is outside that supported range",
                    field: "/environment/sdk",
                    fixes: ["rebindSDK", "rebindToolchain"],
                )
            }
            if project.language == .swift, let toolchain, let newest = toolchain.newestSDK,
               newest.split(separator: ".").first != sdk.version.split(separator: ".").first
            {
                add(
                    "environment.sdk.swiftMacros",
                    .warning,
                    "toolchain \(toolchain.id)'s Swift macros are those of the iPhoneOS \(newest) SDK; with SDK "
                        + "\(sdk.version) a macro such as @Observable can expand to code that SDK does not declare",
                    field: "/environment/sdk",
                    fixes: ["rebindSDK"],
                )
            }
            if project.language == .swift {
                // The iOS 27 SDK carries Swift interfaces for arm64e only.
                let module = sdk.path + "/usr/lib/swift/Swift.swiftmodule/"
                for bootstrap in project.architectures.bootstraps {
                    for arch in project.architectures[bootstrap] ?? [] where !FileManager.default.fileExists(
                        atPath: module + "\(arch.rawValue)-apple-ios.swiftinterface",
                    ) {
                        add(
                            "environment.sdk.noSwiftArchitecture",
                            .warning,
                            "SDK \(sdk.id) has no Swift interface for \(arch.rawValue), so the \(bootstrap.rawValue) "
                                + "build cannot compile Swift for it; drop \(arch.rawValue) there or bind an SDK that has one",
                            field: "/architectures/\(bootstrap.rawValue)",
                            fixes: ["rebindSDK"],
                        )
                    }
                }
            }
            let frameworks = Set(project.products.flatMap { ($0.frameworks ?? []) + ($0.weakFrameworks ?? []) })
            for framework in frameworks.sorted() {
                let public_ = sdk.path + "/System/Library/Frameworks/\(framework).framework"
                let supported = catalog.usable.contains { item in
                    (item.manifest?.support ?? [:]).values.contains { ($0.frameworks ?? []).contains(framework) }
                }
                if !FileManager.default.fileExists(atPath: public_), !supported {
                    add(
                        "environment.sdk.framework",
                        .warning,
                        "\(framework).framework is not in SDK \(sdk.id)",
                        field: "/products",
                    )
                }
            }
        } else {
            add(
                "environment.sdk.missing",
                .error,
                "SDK \(project.environment.sdk.id) is not registered",
                field: "/environment/sdk",
                fixes: ["importSDK", "rebindSDK"],
            )
        }

        // 3. Extensions the project uses.
        if catalog.usableExtension(project.template.extensionID) == nil {
            add(
                "extension.template.missing",
                .note,
                "the extension \(project.template.extensionID) that made this project is not installed; the project still edits and builds",
                field: "/template",
            )
        }
        var runtimeDependencies: Set<String> = []
        for (index, product) in project.products.enumerated() {
            for (supportIndex, support) in (product.extensionSupport ?? []).enumerated() {
                let field = "/products/\(index)/extensionSupport/\(supportIndex)"
                guard let found = catalog.usableExtension(support.extension),
                      let component = found.manifest?.support?[support.component]
                else {
                    add(
                        "extension.support.missing",
                        .error,
                        "\(support.extension) (\(support.component)) is not installed; install it with your preferred package manager to build",
                        field: field,
                        fixes: ["installExtension"],
                    )
                    continue
                }
                for bootstrap in project.architectures.bootstraps {
                    if component.linkStubDirectories != nil, component.linkStubDirectories?[bootstrap] == nil {
                        add(
                            "extension.support.bootstrap",
                            .error,
                            "\(support.extension) (\(support.component)) has no link stubs for \(bootstrap.rawValue)",
                            field: field,
                        )
                    }
                    for dependency in component.runtimeDependencies?[bootstrap] ?? [] {
                        runtimeDependencies.insert(dependency)
                    }
                }
            }
        }

        // 4. Package relations, filter, layout.
        let declared = Set((project.package.depends ?? []).map { Self.relationName($0) })
            .union(project.architectures.bootstraps.flatMap {
                (project.package.dependsByBootstrap?[$0] ?? []).map { Self.relationName($0) }
            })
        for dependency in runtimeDependencies.sorted() where !declared.contains(Self.relationName(dependency)) {
            add(
                "package.dependency.missing",
                .warning,
                "a support component needs \(dependency) at run time; add it to package.depends",
                field: "/package/depends",
                fixes: ["addDependency"],
            )
        }
        if let filter = project.package.tweakFilter, (filter.bundles ?? []).isEmpty,
           (filter.executables ?? []).isEmpty, (filter.classes ?? []).isEmpty
        {
            add("package.filter.empty", .error, "the tweak filter selects no process", field: "/package/tweakFilter")
        }

        // 5. Space, a writable work directory, signing and installing.
        for (label, directory) in [("project", root), ("build", store.buildsDirectory.deletingLastPathComponent())] {
            var info = statfs()
            if statfs(directory.path, &info) == 0 {
                let free = UInt64(info.f_bavail) * UInt64(info.f_bsize)
                let freeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: free), countStyle: .file)
                if free < minimumSpace {
                    add(
                        "space.exhausted",
                        .error,
                        "only \(freeText) free for the \(label) folder; free up space to build",
                        fixes: ["freeSpace"],
                    )
                } else if free < lowSpace {
                    add("space.low", .warning, "only \(freeText) free for the \(label) folder", fixes: ["freeSpace"])
                }
            }
            if access(directory.path, W_OK) != 0 {
                add("workdir.readOnly", .error, "the \(label) folder is not writable")
            }
        }
        add("install.service", .note, "installing needs Irisin; building does not")
        return Result(diagnostics: out, digests: digests, project: project)
    }

    private func checkGlob(
        _ pattern: String,
        root: URL,
        field: String,
        add: (String, DiagnosticSeverity, String, String?, String?, [String]) -> Void,
    ) {
        do {
            let matches = try ProjectGlob.expand(pattern, in: root)
            if matches.isEmpty {
                add("project.glob.empty", .error, "\(pattern) matches no file", nil, field, ["openProjectFolder"])
            }
        } catch {
            add("project.path.outside", .error, String(describing: error), nil, field, [])
        }
    }

    private func checkDirectory(
        _ path: String,
        root: URL,
        field: String,
        add: (String, DiagnosticSeverity, String, String?, String?, [String]) -> Void,
    ) {
        do {
            let real = try ProjectFiles.resolve(path, in: root)
            var info = stat()
            if stat(real, &info) != 0 || info.st_mode & S_IFMT != S_IFDIR {
                add("project.directory.missing", .error, "\(path) is not a folder", nil, field, [])
            }
        } catch {
            add("project.directory.missing", .error, String(describing: error), nil, field, [])
        }
    }

    /// `"/products/0/sources: …"` → (`/products/0/sources`, `…`).
    static func split(_ problem: String) -> (String?, String) {
        guard let range = problem.range(of: ": ") else { return (nil, problem) }
        return (String(problem[..<range.lowerBound]), String(problem[range.upperBound...]))
    }

    static func relationName(_ relation: String) -> String {
        String(relation.split(separator: " ").first ?? Substring(relation))
    }
}
