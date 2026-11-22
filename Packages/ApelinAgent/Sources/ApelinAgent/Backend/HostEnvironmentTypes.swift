import Foundation

// MARK: - toolchains and SDKs

/// A registered component a project binds, by id and the registry's digest.
public struct ComponentBinding: Sendable, Hashable, Codable {
    public var id: String
    public var digest: String
    public init(id: String, digest: String) {
        self.id = id
        self.digest = digest
    }
}

/// The toolchain and SDK the session's project binds, by id.
public struct ProjectEnvironmentSummary: Sendable, Hashable, Codable {
    public var toolchainID: String?
    public var sdkID: String?
    public init(toolchainID: String?, sdkID: String?) {
        self.toolchainID = toolchainID
        self.sdkID = sdkID
    }
}

/// A toolchain set up on this device.
public struct InstalledToolchain: Sendable, Hashable, Codable {
    public var id: String
    /// The Command Line Tools version, `16.4`.
    public var version: String
    /// The components whose self-check passed: `c`, `swift`.
    public var components: [String]
    /// The newest iPhoneOS SDK its tools read; nil for any.
    public var newestSDK: String?
    /// `12 of 12 passed against iPhoneOS 18.5`.
    public var selfTests: String?
    public var isDefault: Bool
    /// Why it cannot be used as it is (files missing, this device lacks a
    /// CPU feature it needs).
    public var problem: String?
    /// Set for a toolchain an earlier retarget scheme made
    /// (`ToolchainRecord.predatesCurrentRetarget`): it builds, but tools it
    /// lacks fail, and setting its release up again is not refused.
    public var outdated: String?
    public var boundByThisProject: Bool

    /// What `outdated` says.
    public static let earlierRetargetNote = "Set up by an earlier version of Apelin: " + earlierRetargetFacts

    /// What a toolchain an earlier retarget scheme made lacks, what does the
    /// same, and how to get the tools (scheme 3 added otool-classic and
    /// ranlib); the environment section says it once, after the list.
    public static let earlierRetargetFacts = "it builds as before, but it lacks otool-classic and ranlib, so "
        + "otool and llvm-otool fail whatever the flags, and so does ar with the s modifier (ar rcs); "
        + "libtool -static -o <name>.a <objects> makes the same indexed archive. Setting its release up again "
        + "with apelin_toolchain_setup (or a newer one when apelin_toolchain_list no longer offers it, as for "
        + "27.0) adds a toolchain that has them, under another ID, beside it; then bind the project to it with "
        + "apelin_project_set_environment."

    public init(
        id: String,
        version: String,
        components: [String],
        newestSDK: String? = nil,
        selfTests: String? = nil,
        isDefault: Bool = false,
        problem: String? = nil,
        outdated: String? = nil,
        boundByThisProject: Bool = false,
    ) {
        self.outdated = outdated
        self.id = id
        self.version = version
        self.components = components
        self.newestSDK = newestSDK
        self.selfTests = selfTests
        self.isDefault = isDefault
        self.problem = problem
        self.boundByThisProject = boundByThisProject
    }
}

/// A Command Line Tools release Apelin sets up, from Apple's catalog, with
/// what it needs of this device: the fields the app's picker shows.
public struct AvailableToolchain: Sendable, Hashable, Codable {
    public var productID: String
    public var version: String
    /// What the download fetches.
    public var sizeBytes: Int64
    /// The newest iPhoneOS SDK its tools read; nil for any.
    public var newestSDK: String?
    /// The SDK setup prefers to test it against.
    public var recommendedSDK: String?
    public var minimumIOS: String?
    public var cpuFeatures: [String]
    /// `Swift 5.10` when setup takes the Swift component on this device.
    public var swift: String?
    public var swiftUnavailable: String?
    /// Why setup does not take it on this device; nil when it does.
    public var unavailable: String?
    /// Registered toolchains already set up from it.
    public var installedAs: [String]
    public init(
        productID: String,
        version: String,
        sizeBytes: Int64,
        newestSDK: String? = nil,
        recommendedSDK: String? = nil,
        minimumIOS: String? = nil,
        cpuFeatures: [String] = [],
        swift: String? = nil,
        swiftUnavailable: String? = nil,
        unavailable: String? = nil,
        installedAs: [String] = [],
    ) {
        self.productID = productID
        self.version = version
        self.sizeBytes = sizeBytes
        self.newestSDK = newestSDK
        self.recommendedSDK = recommendedSDK
        self.minimumIOS = minimumIOS
        self.cpuFeatures = cpuFeatures
        self.swift = swift
        self.swiftUnavailable = swiftUnavailable
        self.unavailable = unavailable
        self.installedAs = installedAs
    }
}

public struct ToolchainListToolResponse: Sendable, Hashable, Codable {
    public var installed: [InstalledToolchain]
    public var available: [AvailableToolchain]
    /// Why Apple's catalog could not be read (offline, no backend).
    public var catalogProblem: String?
    /// Setups and removals still running.
    public var runningTasks: Int
    public var project: ProjectEnvironmentSummary?
    public init(
        installed: [InstalledToolchain],
        available: [AvailableToolchain] = [],
        catalogProblem: String? = nil,
        runningTasks: Int = 0,
        project: ProjectEnvironmentSummary? = nil,
    ) {
        self.installed = installed
        self.available = available
        self.catalogProblem = catalogProblem
        self.runningTasks = runningTasks
        self.project = project
    }
}

/// An SDK registered on this device.
public struct InstalledSDK: Sendable, Hashable, Codable {
    public var id: String
    public var version: String
    public var targets: [String]
    public var swiftCompilerVersion: String?
    /// Registered toolchains whose tools read it.
    public var readBy: [String]
    public var boundByThisProject: Bool
    public init(
        id: String,
        version: String,
        targets: [String] = [],
        swiftCompilerVersion: String? = nil,
        readBy: [String] = [],
        boundByThisProject: Bool = false,
    ) {
        self.id = id
        self.version = version
        self.targets = targets
        self.swiftCompilerVersion = swiftCompilerVersion
        self.readBy = readBy
        self.boundByThisProject = boundByThisProject
    }
}

/// An SDK an enabled source offers and this device has not registered.
public struct AvailableSDK: Sendable, Hashable, Codable {
    public var version: String
    public var branch: String
    /// The source's name, as apelin_sdk_import takes it.
    public var source: String
    /// The source repository, which apelin_sdk_import fetches; never a credential.
    public var sourceURL: String
    /// Registered toolchains whose tools would read it.
    public var readBy: [String]
    public init(version: String, branch: String, source: String, sourceURL: String, readBy: [String] = []) {
        self.version = version
        self.branch = branch
        self.source = source
        self.sourceURL = sourceURL
        self.readBy = readBy
    }
}

public struct SDKListToolResponse: Sendable, Hashable, Codable {
    public var installed: [InstalledSDK]
    public var available: [AvailableSDK]
    /// A source that could not be read, and why.
    public var sourceProblems: [String]
    public var project: ProjectEnvironmentSummary?
    public init(
        installed: [InstalledSDK],
        available: [AvailableSDK] = [],
        sourceProblems: [String] = [],
        project: ProjectEnvironmentSummary? = nil,
    ) {
        self.installed = installed
        self.available = available
        self.sourceProblems = sourceProblems
        self.project = project
    }
}

public struct ToolchainSetupToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// The catalog product the user approved, always named.
    public var productID: String
    /// `c`, and `swift` when asked for.
    public var components: [String]
    public init(context: HostCallContext, productID: String, components: [String]) {
        self.context = context
        self.productID = productID
        self.components = components
    }
}

public struct ToolchainSelfTestToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var toolchainID: String
    public init(context: HostCallContext, toolchainID: String) {
        self.context = context
        self.toolchainID = toolchainID
    }
}

/// How a setup or a self-test ended, its progress left out but for the
/// stages it went through.
public struct ToolchainTaskToolResponse: Sendable, Hashable, Codable {
    public var succeeded: Bool
    public var toolchain: InstalledToolchain?
    public var stages: [String]
    /// A sentence naming each failed self-test, followed by its diagnostic on a new line.
    public var failedTests: [String]
    public var warnings: [String]
    public var message: String?
    public init(
        succeeded: Bool,
        toolchain: InstalledToolchain? = nil,
        stages: [String] = [],
        failedTests: [String] = [],
        warnings: [String] = [],
        message: String? = nil,
    ) {
        self.succeeded = succeeded
        self.toolchain = toolchain
        self.stages = stages
        self.failedTests = failedTests
        self.warnings = warnings
        self.message = message
    }
}

public struct SDKImportToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// An enabled source's repository, as apelin_sdk_list named it.
    public var url: String
    public var branch: String
    public init(context: HostCallContext, url: String, branch: String) {
        self.context = context
        self.url = url
        self.branch = branch
    }
}

public struct SDKImportToolResponse: Sendable, Hashable, Codable {
    public var succeeded: Bool
    public var sdk: InstalledSDK?
    public var stages: [String]
    public var warnings: [String]
    public var message: String?
    public init(
        succeeded: Bool,
        sdk: InstalledSDK? = nil,
        stages: [String] = [],
        warnings: [String] = [],
        message: String? = nil,
    ) {
        self.succeeded = succeeded
        self.sdk = sdk
        self.stages = stages
        self.warnings = warnings
        self.message = message
    }
}

/// The project check a switch to these registered components would get;
/// a nil one keeps the project's.
public struct EnvironmentCheckToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var toolchainID: String?
    public var sdkID: String?
    public init(context: HostCallContext, toolchainID: String?, sdkID: String?) {
        self.context = context
        self.toolchainID = toolchainID
        self.sdkID = sdkID
    }
}

public struct EnvironmentDiagnostic: Sendable, Hashable, Codable {
    public var code: String
    /// `error`, `warning` or `note`.
    public var severity: String
    public var message: String
    public init(code: String, severity: String, message: String) {
        self.code = code
        self.severity = severity
        self.message = message
    }
}

public struct EnvironmentCheckToolResponse: Sendable, Hashable, Codable {
    /// The binding checked, digests the registry's.
    public var toolchain: ComponentBinding
    public var sdk: ComponentBinding
    /// The check's `environment.*` findings for that binding.
    public var diagnostics: [EnvironmentDiagnostic]
    public init(toolchain: ComponentBinding, sdk: ComponentBinding, diagnostics: [EnvironmentDiagnostic] = []) {
        self.toolchain = toolchain
        self.sdk = sdk
        self.diagnostics = diagnostics
    }
}

/// A toolchain or SDK call that did not happen, in words the model can act on.
public struct EnvironmentToolFailure: Error, LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? {
        message
    }

    public init(message: String) {
        self.message = message
    }
}

/// What apelin_project_set_environment wrote.
public struct ProjectEnvironmentSetToolResponse: Sendable, Hashable, Codable {
    public var toolchain: ComponentBinding
    public var sdk: ComponentBinding
    /// `toolchain`, `sdk`, or nothing when it was bound so already.
    public var changed: [String]
    public var warnings: [String]
    public init(toolchain: ComponentBinding, sdk: ComponentBinding, changed: [String], warnings: [String] = []) {
        self.toolchain = toolchain
        self.sdk = sdk
        self.changed = changed
        self.warnings = warnings
    }
}
