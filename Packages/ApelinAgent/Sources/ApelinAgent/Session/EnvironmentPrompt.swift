import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The device as the toolchains see it: its iOS version and model, whether
/// it is arm64e, and the CPU features the kernel reports that decide which
/// Apple compilers run here (`HostCPU`). Constant for a process.
public struct DeviceFacts: Sendable, Equatable {
    /// `17.3.1`.
    public var osVersion: String
    /// `iPhone16,1`, the kernel's `hw.machine`.
    public var machine: String
    public var arm64e: Bool
    /// Each feature a toolchain release can require, and whether the
    /// kernel reports it (`hw.optional.arm.<feature>`).
    public var cpuFeatures: [String: Bool]

    /// What the release table's requirements name.
    static let toolchainFeatures = ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"]

    public init(osVersion: String, machine: String, arm64e: Bool, cpuFeatures: [String: Bool]) {
        self.osVersion = osVersion
        self.machine = machine
        self.arm64e = arm64e
        self.cpuFeatures = cpuFeatures
    }

    public static let current: DeviceFacts = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var os = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 {
            os += ".\(version.patchVersion)"
        }
        var subtype: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // CPU_SUBTYPE_ARM64E, a macro Swift does not import.
        let arm64e = sysctlbyname("hw.cpusubtype", &subtype, &size, nil, 0) == 0 && subtype == 2
        return DeviceFacts(
            osVersion: os,
            machine: machine() ?? "unknown",
            arm64e: arm64e,
            cpuFeatures: Dictionary(uniqueKeysWithValues: toolchainFeatures.map { ($0, HostCPU.has($0)) }),
        )
    }()

    private static func machine() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// The system prompt's `# Environment`: the device, the bootstrap, every
/// registered toolchain and SDK, and what shell_run already has — the same
/// `DevelopmentEnvironment` the session host builds for it — so the model
/// neither probes for compilers nor asks for a toolchain that is installed.
///
/// It is part of every prompt, so it holds only what changes when the
/// environment does: no time, no sizes, no durations, everything sorted.
enum EnvironmentPrompt {
    struct Inputs {
        var registered: RegisteredEnvironment
        var binding: ProjectManifestBinding?
        var inProject: Bool
        var device: DeviceFacts
        var installRoot: String?
        var home: String
        /// Which of `probedCommands` shell_run finds on its search path; nil
        /// when nobody looked.
        var commandsFound: Set<String>?
        /// The folders the read tools reach besides the project.
        var readOnlyRoots: ReadOnlyRoots = .none
        /// The agent tool extensions whose tools the session offers.
        var toolExtensions: [OfferedToolExtension] = []

        var environment: DevelopmentEnvironment {
            DevelopmentEnvironment.resolve(registered, binding: binding)
        }
    }

    /// Commands a repository's build scripts reach for, which a model would
    /// otherwise probe for, or assume from a Mac.
    static let probedCommands = ["cmake", "dpkg-deb", "git", "ldid", "make", "ninja", "perl", "python3", "xcrun"]

    /// Which of `probedCommands` are executables on shell_run's search path.
    static func commandsFound(installRoot: String) -> Set<String> {
        let directories = DevelopmentEnvironment.searchPath(installRoot: installRoot)
        return Set(probedCommands.filter { name in
            directories.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
        })
    }

    /// Read from the registries in the data folder and, in a project, its
    /// `apelin-project.json`; the extensions are the session's offer.
    static func inputs(
        _ configuration: AgentSessionConfiguration,
        root: ScopedRoot,
        device: DeviceFacts,
        toolExtensions: [OfferedToolExtension] = [],
    ) -> Inputs {
        let inProject = !configuration.project.isTemporary
        return Inputs(
            registered: RegisteredEnvironment.read(DataFolder(root: configuration.dataRoot.url)),
            binding: inProject ? ProjectManifestBinding.read(projectDirectory: root.path) : nil,
            inProject: inProject,
            device: device,
            installRoot: configuration.installRoot,
            home: configuration.dataRoot.home.path,
            commandsFound: configuration.installRoot.map(commandsFound(installRoot:)),
            readOnlyRoots: ReadOnlyRoots(installRoot: configuration.installRoot, dataRoot: configuration.dataRoot),
            toolExtensions: toolExtensions,
        )
    }

    static func section(_ inputs: Inputs) -> String {
        let environment = inputs.environment
        var lines = ["# Environment"]
        lines.append(deviceLine(inputs.device))
        let bootstrap = inputs.installRoot.map { BuildBootstrap.resolve(installRoot: $0, home: inputs.home) }
        if let installRoot = inputs.installRoot, let bootstrap {
            lines.append("- Bootstrap: \(bootstrap.rawValue), install root \(installRoot).")
        }
        lines += toolchainLines(inputs, environment: environment)
        lines += sdkLines(inputs, environment: environment)
        lines += bindingLines(inputs, environment: environment)
        lines.append(preparedLine(inputs, environment: environment))
        lines.append(
            "- shell_run's environment is already set: run a command directly or with `bash -c`, never through a login shell (`bash -l`, `sh -l`), whose profile builds PATH again.",
        )
        if bootstrap == .roothide {
            // The bootstrap's own tools see the bootstrap as / and the real
            // root as /rootfs; the toolchain's compilers are Apple's and see
            // the real filesystem. On a roothide vphone, `pwd -P` in the data
            // folder printed /var/mobile/Documents/…, the system's folder to
            // clang.
            lines.append(
                "- On roothide the bootstrap's shell and tools see the bootstrap as `/` and the real root as `/rootfs`, so `pwd -P`, `realpath` and the like print `/var/mobile/…` or `/rootfs/…` for a path the toolchain's compilers know by another name: give the compilers paths relative to the working directory, or under `$APELIN_PROJECT_ROOT`, the project's real path.",
            )
            // The jbroot was renamed on a device between two runs of one
            // chat, which trusted the paths it had written down.
            lines.append(
                "- roothide can rename the install root when the device is rebooted or jailbroken again, and everything under it moves: Apelin's data folder (in the jbroot's own `var/mobile`), the project's real path, `$APELIN_PROJECT_ROOT`, `$APELIN_TOOLCHAIN_BIN`, `SDKROOT`, every toolchain and SDK path above. Never write such a path into anything that outlives this run (project files, build scripts, Makefiles, AGENTS.md or CLAUDE.md, memory, skills, package scripts, code): code finds it at run time as roothide's `jbroot()` does (the apelin-bootstrap-paths skill's `ApelinBootstrapPath()`), plists and maintainer scripts use `@PREFIX@` and `@ROOTFS@`, and a script uses the variables Apelin sets when it runs or paths relative to the project.",
            )
        }
        if let found = inputs.commandsFound {
            lines.append(commandsLine(found))
        }
        if let line = readOnlyLine(inputs.readOnlyRoots) {
            lines.append(line)
        }
        lines += ToolExtensionOffer.environmentLines(inputs.toolExtensions)
        // The records are files mobile can write: whatever they hold stays
        // on its line.
        return lines.map(ProjectTree.printable).joined(separator: "\n")
    }

    private static func deviceLine(_ device: DeviceFacts) -> String {
        let present = device.cpuFeatures.filter(\.value).keys.sorted()
        let missing = device.cpuFeatures.filter { !$0.value }.keys.sorted()
        let has = present.isEmpty ? "none" : present.joined(separator: ", ")
        let lacks = missing.isEmpty ? "none missing" : "missing " + missing.joined(separator: ", ")
        return "- Device: \(device.machine)\(device.arm64e ? " (arm64e)" : ""), iOS \(device.osVersion); CPU features: \(has); \(lacks)."
    }

    private static func toolchainLines(_ inputs: Inputs, environment: DevelopmentEnvironment) -> [String] {
        let toolchains = inputs.registered.toolchains.sorted { $0.id < $1.id }
        guard !toolchains.isEmpty else {
            return ["- Toolchains: none installed. Building needs one: the user sets it up in Settings ▸ Toolchains."]
        }
        var lines = ["- Toolchains (each registered only after its installed tools passed the self-test; the user removes one in Settings ▸ Toolchains):"]
        for record in toolchains {
            var facts = ["Command Line Tools \(record.version)", languages(record)]
            if let host = record.compatibility?.minimumHost {
                var runs = "runs on iOS \(host)+"
                if let swift = record.swiftRequirements, swiftPassed(record), swift.minimumHost != host {
                    runs += " (Swift on \(swift.minimumHost)+)"
                }
                facts.append(runs)
            }
            facts.append("reads SDKs up to \(record.newestSDK ?? "any version")")
            if let selfTest = selfTestSummary(record) {
                facts.append(selfTest)
            }
            var marks: [String] = []
            if record.id == inputs.registered.defaultToolchainID {
                marks.append("default")
            }
            if inputs.inProject, record.id == inputs.binding?.toolchainID {
                marks.append("this project's")
            }
            if record.id == environment.toolchain?.record.id {
                marks.append("prepared")
            }
            if record.predatesCurrentRetarget {
                marks.append(earlierRetargetMark)
            }
            var line = "  - \(record.id): " + facts.joined(separator: "; ") + "."
            if !marks.isEmpty {
                line += " " + sentence(marks) + "."
            }
            let bin = record.path.flatMap(ToolchainLayout.binDirectory(installedAt:))
            line += bin.map { " Tools: \($0)" } ?? " Its folder is missing: reinstall it in Settings ▸ Toolchains."
            lines.append(line)
        }
        if toolchains.contains(where: \.predatesCurrentRetarget) {
            lines.append("  - A toolchain marked \(earlierRetargetMark): " + InstalledToolchain.earlierRetargetFacts)
        }
        return lines
    }

    /// The mark of a toolchain an earlier retarget scheme made, which the
    /// line after the list explains once.
    static let earlierRetargetMark = "set up by an earlier version of Apelin"

    private static func sdkLines(_ inputs: Inputs, environment: DevelopmentEnvironment) -> [String] {
        let sdks = inputs.registered.sdks
        guard !sdks.isEmpty else {
            return ["- SDKs: none registered. Building needs one: the user imports it in Settings ▸ SDKs."]
        }
        var lines = ["- iPhoneOS SDKs (registered; the user removes one in Settings ▸ SDKs):"]
        let prepared = environment.toolchain?.record
        for record in sdks {
            var marks: [String] = []
            if inputs.inProject, record.id == inputs.binding?.sdkID {
                marks.append("this project's")
            }
            if record.id == environment.sdk?.record.id {
                marks.append("prepared")
            }
            if let prepared, !SDKVersionLimit.allows(sdkVersion: record.version, newestSDK: prepared.newestSDK) {
                marks.append("too new for the prepared toolchain")
            }
            var line = "  - \(record.id): iOS \(record.version) at \(record.path)."
            if !marks.isEmpty {
                line += " " + sentence(marks) + "."
            }
            lines.append(line)
        }
        return lines
    }

    /// What the project binds and this device lacks: a build fails on it.
    private static func bindingLines(_ inputs: Inputs, environment: DevelopmentEnvironment) -> [String] {
        guard inputs.inProject, let binding = inputs.binding else { return [] }
        var lines: [String] = []
        if let id = binding.toolchainID.map({ String($0.prefix(200)) }), environment.toolchain?.source != .project {
            lines.append("- This project binds toolchain \(id), which is not installed here: its builds fail until it is set up or the project is bound to an installed one.")
        }
        if let id = binding.sdkID.map({ String($0.prefix(200)) }), environment.sdk?.source != .project {
            lines.append("- This project binds SDK \(id), which is not registered here: its builds fail until it is imported or the project is bound to a registered one.")
        }
        return lines
    }

    private static func commandsLine(_ found: Set<String>) -> String {
        let missing = probedCommands.filter { !found.contains($0) }
        let listed = found.isEmpty
            ? "none of " + probedCommands.joined(separator: ", ")
            : found.sorted().joined(separator: ", ")
        var line = "- Also on shell_run's PATH: \(listed)."
        if !found.isEmpty, !missing.isEmpty {
            line += " Not installed: " + missing.joined(separator: ", ") + "."
        }
        // A package is apelin_project_build's: dpkg-deb builds one only in
        // the script a workspace declares for it.
        if found.contains("dpkg-deb") {
            line += " dpkg-deb builds a package only inside a workspace's declared build script, which apelin_project_build runs; never build one with it yourself."
        }
        return line + " The bootstrap's other commands are not macOS's (GNU sed, a different plutil): read a Mac build script's commands before running it, and say what is missing rather than looking for it."
    }

    /// Where a header the project does not hold is read: a template's
    /// support headers (the Preferences framework's among them) are in its
    /// extension's folder, an SDK's under the SDK's path.
    private static func readOnlyLine(_ roots: ReadOnlyRoots) -> String? {
        guard let described = roots.described else { return nil }
        var line = "- file_read, file_list, file_grep and file_find also read, never write, an absolute path inside \(described)."
        if roots.developmentExtensions != nil {
            line += " The headers a template's support component adds, such as the Preferences framework's, are in `<extension id>/support/include` there."
        }
        return line
    }

    private static func preparedLine(_ inputs: Inputs, environment: DevelopmentEnvironment) -> String {
        guard let toolchain = environment.toolchain else {
            return "- shell_run has no Apelin compiler until a toolchain is installed. Do not search the device for one; ask the user to set one up."
        }
        guard environment.sdk != nil else {
            return "- shell_run has the prepared toolchain's tools first on PATH, but no SDK it reads is registered. Do not search for one; ask the user to import one."
        }
        let target = environment.deploymentTarget
        let whose = inputs.binding?.deploymentTarget == target ? "this project's deployment target"
            : inputs.inProject ? "Apelin's default" : "Apelin's default; this chat has no project"
        var line = "- shell_run and the user's terminal already have the toolchain and SDK marked prepared: "
            + "the toolchain's tools first on PATH, SDKROOT set to the SDK, IPHONEOS_DEPLOYMENT_TARGET=\(target) (\(whose)). "
            + "clang, clang++, ld, lipo and the other tools are found by name and build for iOS against that SDK "
            + "without -isysroot or -target (pass -arch arm64 or arm64e)"
        line += swiftPassed(toolchain.record)
            ? "; swiftc takes the SDK too but needs -target arm64-apple-ios\(target). "
            : ". "
        line += "So do not look for compilers, SDKs or paths, and never set up or import again a toolchain or SDK listed here"
        line += inputs.registered.toolchains.contains(where: \.predatesCurrentRetarget)
            ? ", but for a toolchain an earlier version of Apelin set up when the tools it lacks are needed. "
            : ". "
        line += "A project with an Apelin build description builds with apelin_project_build."
        return line
    }

    private static func languages(_ record: ToolchainRecord) -> String {
        var names: [String] = []
        for component in record.components.sorted(by: { $0.kind.rawValue < $1.kind.rawValue }) {
            switch component.kind {
            case .c:
                names.append(component.selfCheckPassed == true ? "C, C++, Objective-C" : "C (failed its self-check)")
            case .swift:
                let version = record.swiftRequirements.map { " \($0.version)" } ?? ""
                names.append(component.selfCheckPassed == true ? "Swift\(version)" : "Swift\(version) (failed its self-check)")
            case .auxiliary:
                break
            }
        }
        return names.isEmpty ? "no components" : names.joined(separator: ", ")
    }

    private static func swiftPassed(_ record: ToolchainRecord) -> Bool {
        record.components.contains { $0.kind == .swift && $0.selfCheckPassed == true }
    }

    /// `self-test 18/18 passed against SDK 27.0`, naming up to three failed cases.
    private static func selfTestSummary(_ record: ToolchainRecord) -> String? {
        guard let results = record.selfTests, !results.isEmpty else { return nil }
        let passed = results.filter(\.passed).count
        var summary = "self-test \(passed)/\(results.count) passed"
        if let sdk = record.selfTestSDK {
            summary += " against SDK \(sdk)"
        }
        let failed = results.filter { !$0.passed }.map { "\($0.language) \($0.architecture)" }
        if !failed.isEmpty {
            summary += " (failed: " + failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? ", …" : "") + ")"
        }
        return summary
    }

    /// `default, this project's, prepared` with its first letter capital.
    private static func sentence(_ marks: [String]) -> String {
        let text = marks.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
