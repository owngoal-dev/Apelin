import ApelinCore
import Foundation

// Toolchain: Apple's Command Line Tools fetched, unpacked and retargeted on
// the device, installed through Irisin, self-checked, registered.
// Served by apelin-environment (Workers/Environment; Packages/ApelinToolchain).
//
// Setup and removal are tasks of kind `environment`, read with
// `environmentAttach`. Setup's events: `stage` {stage} through downloading,
// extracting, adapting, packaging, installing, validating, ready (§3.4);
// `progress` {stage, completed, total?, detail?}; `resumed` {stage,
// previousTask} when a setup of the same source and components picks up an
// earlier one's staging; `artifact` (the local deb: artifactID, digest,
// packageID, version); `install.<kind>` for each event of the host's install
// or removal task it follows (`install.irisin`, `install.stage`, …);
// `warning` {message}; `result` {toolchain: ToolchainRecord} before the
// final `state`. Removal: `stage` {removing}, the `install.*` events,
// `result` {removed}.

public enum ToolchainComponentKind: String, Codable, Sendable {
    /// clang, ld, lipo, dsymutil, strip and their resources.
    case c
    case swift
    case auxiliary
}

public struct ToolchainComponent: Codable, Sendable, Equatable {
    public var kind: ToolchainComponentKind
    public var selfCheckPassed: Bool?
    public var problem: String?

    public init(kind: ToolchainComponentKind, selfCheckPassed: Bool? = nil, problem: String? = nil) {
        self.kind = kind
        self.selfCheckPassed = selfCheckPassed
        self.problem = problem
    }
}

/// One case of the self-test run after installation: a language compiled,
/// linked, signed and run for one architecture.
public struct ToolchainSelfTestResult: Codable, Sendable, Equatable {
    public var language: String
    public var architecture: String
    public var passed: Bool
    public var detail: String
    public var seconds: Double

    public init(language: String, architecture: String, passed: Bool, detail: String = "", seconds: Double = 0) {
        self.language = language
        self.architecture = architecture
        self.passed = passed
        self.detail = detail
        self.seconds = seconds
    }
}

/// Requirements of a reviewed Swift component, carried with its toolchain.
public struct SwiftToolchainRequirements: Codable, Sendable, Equatable {
    public var version: String
    public var minimumHost: String
    public var cpuFeatures: [String]
    public var minimumHostBasis: String?
    public var verifiedHosts: [String]?

    public init(
        version: String,
        minimumHost: String,
        cpuFeatures: [String],
        minimumHostBasis: String? = nil,
        verifiedHosts: [String]? = nil,
    ) {
        self.version = version
        self.minimumHost = minimumHost
        self.cpuFeatures = cpuFeatures
        self.minimumHostBasis = minimumHostBasis
        self.verifiedHosts = verifiedHosts
    }

    public var unavailableReason: String? {
        #if os(iOS)
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            if current.compare(minimumHost, options: .numeric) == .orderedAscending {
                return minimumHostBasis == "verified-policy"
                    ? "Swift \(version) is supported on iOS \(minimumHost) or later; earlier hosts have not been verified."
                    : "Swift \(version) requires iOS \(minimumHost) or later on this device."
            }
        #endif
        let missing = cpuFeatures.filter { !HostCPU.has($0) }
        return missing.isEmpty
            ? nil
            : "Swift \(version) requires CPU features this device lacks: " + missing.joined(separator: ", ") + "."
    }
}

public struct ToolchainRecord: Codable, Sendable, Equatable {
    public var id: String
    /// The CLT product version, `27.0`.
    public var version: String
    public var components: [ToolchainComponent]
    /// Physical path under the install root `hello` answered.
    public var path: String?
    public var packageID: String?
    /// SHA-256 over the manifest's per-file digests, and how many files.
    public var contentDigest: String?
    public var fileCount: Int?
    public var selfTests: [ToolchainSelfTestResult]?
    /// The session host's record of the install, for removal.
    public var installationID: String?
    /// Where it came from: `<productID> <url>`.
    public var origin: String?
    /// The newest iPhoneOS SDK (major.minor, or a major alone for all of its
    /// point releases) its tools read; a newer SDK can use stub
    /// architectures or headers they do not know. Absent: any. Written at
    /// setup into the toolchain's own `manifest.json` and this record, which
    /// project checks read.
    public var newestSDK: String?
    /// The SDK version the self-test compiled against.
    public var selfTestSDK: String?
    public var swiftRequirements: SwiftToolchainRequirements?
    public var clangModuleCPUFeatures: [String]?
    public var compatibility: ToolchainCompatibility?
    /// The retarget scheme its tree was made with (ApelinToolchain's
    /// `ToolchainSetup.schemeVersion`). Absent on a record registered before
    /// scheme 3, whose tree is scheme 2.
    public var retargetScheme: Int?

    /// The scheme setup makes a tree with now, ApelinToolchain's
    /// `ToolchainSetup.schemeVersion`, which a test holds this to.
    public static let currentRetargetScheme = 3

    /// Made by an earlier scheme: it builds as it did, but lacks what later
    /// schemes added (scheme 3: otool-classic and ranlib, so `otool` and
    /// `ar rcs` fail). Its release set up again is a toolchain of its own,
    /// under another ID, beside it.
    public var predatesCurrentRetarget: Bool {
        (retargetScheme ?? 2) < Self.currentRetargetScheme
    }

    /// Releases Apple no longer serves, so a toolchain of one cannot be set
    /// up again, each with the reviewed release to set up in its place
    /// (ApelinToolchain's withdrawn packages, which a test holds this to).
    public static let replacedReleases = ["27.0": "27.2"]

    /// Whether this record, set up under a later scheme, takes the place of
    /// `other`: the same release, made by an earlier scheme, with no
    /// component this one lacks.
    public func supersedes(_ other: ToolchainRecord) -> Bool {
        other.id != id && other.version == version
            && (other.retargetScheme ?? 2) < (retargetScheme ?? 2)
            && Set(other.components.map(\.kind)).isSubset(of: Set(components.map(\.kind)))
    }

    public init(
        id: String,
        version: String,
        components: [ToolchainComponent],
        path: String? = nil,
        packageID: String? = nil,
        contentDigest: String? = nil,
        fileCount: Int? = nil,
        selfTests: [ToolchainSelfTestResult]? = nil,
        installationID: String? = nil,
        origin: String? = nil,
        newestSDK: String? = nil,
        selfTestSDK: String? = nil,
        swiftRequirements: SwiftToolchainRequirements? = nil,
        clangModuleCPUFeatures: [String]? = nil,
        compatibility: ToolchainCompatibility? = nil,
        retargetScheme: Int? = nil,
    ) {
        self.retargetScheme = retargetScheme
        self.newestSDK = newestSDK
        self.selfTestSDK = selfTestSDK
        self.swiftRequirements = swiftRequirements
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.compatibility = compatibility
        self.id = id
        self.version = version
        self.components = components
        self.path = path
        self.packageID = packageID
        self.contentDigest = contentDigest
        self.fileCount = fileCount
        self.selfTests = selfTests
        self.installationID = installationID
        self.origin = origin
    }
}

/// Which SDKs a toolchain reads: those whose major.minor is no newer than its
/// `newestSDK` (`18.2.1` passes for `18.2`, `18.5` does not). A `newestSDK`
/// that is a major alone (`27`) takes every SDK of that major and older:
/// what a release was checked against reading point releases of its own.
public enum SDKVersionLimit {
    public static func allows(sdkVersion: String, newestSDK: String?) -> Bool {
        guard let newestSDK else { return true }
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0) ?? 0 }
        }
        let sdk = parts(sdkVersion), newest = parts(newestSDK)
        guard newest.count > 1 else { return (sdk.first ?? 0) <= (newest.first ?? 0) }
        let sdkPair = [sdk.first ?? 0, sdk.count > 1 ? sdk[1] : 0], newestPair = [newest[0], newest[1]]
        return sdkPair == newestPair || sdkPair.lexicographicallyPrecedes(newestPair)
    }
}

public struct ToolchainStatusRequest: OperationRequest {
    public typealias Response = ToolchainStatusResponse
    public static let operation = AppOperation.toolchainStatus
    public init() {}
}

public struct ToolchainStatusResponse: Codable, Sendable, Equatable {
    public var toolchains: [ToolchainRecord]
    public var defaultID: String?
    /// Setup and removal tasks still running, to reattach after a relaunch.
    public var activeTasks: [TaskHandle]

    public init(toolchains: [ToolchainRecord] = [], defaultID: String? = nil, activeTasks: [TaskHandle] = []) {
        self.toolchains = toolchains
        self.defaultID = defaultID
        self.activeTasks = activeTasks
    }
}

/// One Command Line Tools release Apple's software update catalog offers,
/// for the app to pick before a setup.
public struct ToolchainCatalogProduct: Codable, Sendable, Equatable {
    /// What `ToolchainSource.appleCatalog` takes: `082-83364`.
    public var productID: String
    /// The CLT version, `27.0`, or `unknown`.
    public var version: String
    /// The package's size in bytes, what the download fetches.
    public var size: Int64
    /// Why setup does not take this release, in a sentence a user reads;
    /// nil when it does.
    public var unsupportedReason: String?
    /// The newest iPhoneOS SDK (major.minor) its tools read; nil for any.
    public var newestSDK: String?
    /// Whether setup takes the Swift component for it on this device.
    public var supportsSwift: Bool?
    public var swiftRequirements: SwiftToolchainRequirements?
    public var swiftUnavailableReason: String?
    public var clangModuleCPUFeatures: [String]?
    public var compatibility: ToolchainCompatibility?

    public init(
        productID: String,
        version: String,
        size: Int64,
        unsupportedReason: String? = nil,
        newestSDK: String? = nil,
        supportsSwift: Bool? = nil,
        swiftRequirements: SwiftToolchainRequirements? = nil,
        swiftUnavailableReason: String? = nil,
        clangModuleCPUFeatures: [String]? = nil,
        compatibility: ToolchainCompatibility? = nil,
    ) {
        self.productID = productID
        self.version = version
        self.size = size
        self.unsupportedReason = unsupportedReason
        self.newestSDK = newestSDK
        self.supportsSwift = supportsSwift
        self.swiftRequirements = swiftRequirements
        self.swiftUnavailableReason = swiftUnavailableReason
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.compatibility = compatibility
    }
}

/// Reads Apple's catalog (network): the releases newest first.
public struct ToolchainCatalogRequest: OperationRequest {
    public typealias Response = ToolchainCatalogResponse
    public static let operation = AppOperation.toolchainCatalog
    public init() {}
}

public struct ToolchainCatalogResponse: Codable, Sendable, Equatable {
    public var products: [ToolchainCatalogProduct]

    public init(products: [ToolchainCatalogProduct] = []) {
        self.products = products
    }
}

public enum ToolchainSource: Codable, Sendable, Equatable {
    /// Apple's software update catalog; nil picks the newest adapted product.
    case appleCatalog(productID: String?)
    /// A `CLTools_Executables.pkg` passed as a descriptor.
    case package(DescriptorSlot)
}

public struct ToolchainSetupRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.toolchainSetup
    public var source: ToolchainSource
    public var components: [ToolchainComponentKind]

    public init(source: ToolchainSource = .appleCatalog(productID: nil), components: [ToolchainComponentKind] = [.c]) {
        self.source = source
        self.components = components
    }
}

/// Runs an installed toolchain's self-test again, against the SDK its setup
/// tested with (or, gone, another its tools read): a task whose final
/// `state` carries the record with the new results as `result.toolchain`,
/// which the registry keeps. A failing case is reported, not a reason to
/// unregister.
public struct ToolchainSelfTestRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.toolchainSelfTest
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct ToolchainRemoveRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.toolchainRemove
    public var id: String
    public init(id: String) {
        self.id = id
    }
}

/// Changes the fallback for new projects; existing project bindings stay intact.
public struct ToolchainSetDefaultRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.toolchainSetDefault
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public extension ApelinService {
    func toolchainSetDefault(id: String) async throws {
        _ = try await send(ToolchainSetDefaultRequest(id: id))
    }

    func toolchainStatus() async throws -> ToolchainStatusResponse {
        try await send(ToolchainStatusRequest())
    }

    func toolchainCatalog() async throws -> ToolchainCatalogResponse {
        try await send(ToolchainCatalogRequest())
    }

    /// Starts setup; follow it with `events(of:)`.
    func toolchainSetup(
        _ request: ToolchainSetupRequest,
        descriptors: [OwnedDescriptor] = [],
    ) async throws -> TaskHandle {
        try await send(request, descriptors: descriptors)
    }

    func toolchainRemove(id: String) async throws -> TaskHandle {
        try await send(ToolchainRemoveRequest(id: id))
    }

    func toolchainSelfTest(id: String) async throws -> TaskHandle {
        try await send(ToolchainSelfTestRequest(id: id))
    }
}
