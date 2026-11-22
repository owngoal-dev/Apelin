import ApelinCore
import ApelinProtocol
import Foundation

/// A CLT product the backend can set up.
public struct ToolchainProduct: Codable, Sendable, Equatable {
    public var productID: String
    public var version: String
    public var url: String
    public var size: Int64
    public var upstreamDigest: String?
    public var upstreamDigestAlgorithm: String?
    /// Why setup does not take this release, in a sentence a user reads;
    /// nil when it does.
    public var unsupportedReason: String?
    /// The newest iPhoneOS SDK (major.minor) this release's tools read: the
    /// one its Xcode shipped with. Nil when any is taken.
    public var newestSDK: String?
    /// Whether setup takes the Swift component for this release on this
    /// device. Optional, so a record written before it decodes.
    public var supportsSwift: Bool?
    public var swiftRequirements: SwiftToolchainRequirements?
    public var swiftUnavailableReason: String?
    public var clangModuleCPUFeatures: [String]?
    public var compatibility: ToolchainCompatibility?
    /// False for a product Apelin has not reviewed (a release it never took
    /// or no longer takes, or an unknown product ID of a kept one): setup
    /// refuses it with `unsupportedReason`, and the picker does not list it.
    /// Nil reads as reviewed, for records written before it.
    public var reviewed: Bool?

    public init(
        productID: String,
        version: String,
        url: String,
        size: Int64,
        upstreamDigest: String? = nil,
        upstreamDigestAlgorithm: String? = nil,
        unsupportedReason: String? = nil,
        newestSDK: String? = nil,
        supportsSwift: Bool? = nil,
        swiftRequirements: SwiftToolchainRequirements? = nil,
        swiftUnavailableReason: String? = nil,
        clangModuleCPUFeatures: [String]? = nil,
        compatibility: ToolchainCompatibility? = nil,
        reviewed: Bool? = nil,
    ) {
        self.reviewed = reviewed
        self.productID = productID
        self.version = version
        self.url = url
        self.size = size
        self.upstreamDigest = upstreamDigest
        self.upstreamDigestAlgorithm = upstreamDigestAlgorithm
        self.unsupportedReason = unsupportedReason
        self.newestSDK = newestSDK
        self.supportsSwift = supportsSwift
        self.swiftRequirements = swiftRequirements
        self.swiftUnavailableReason = swiftUnavailableReason
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.compatibility = compatibility
    }

    /// Whether this release's tools read an SDK of `version`.
    public func reads(sdkVersion version: String) -> Bool {
        SDKVersionLimit.allows(sdkVersion: version, newestSDK: newestSDK)
    }
}

/// What the backend reports while it works. Stages are §3.4's:
/// downloading, extracting, adapting, packaging, installing, validating, ready.
public struct ToolchainBackendProgress: Sendable {
    public var stage: String
    public var completed: Int64
    public var total: Int64?
    public var detail: String

    public init(stage: String, completed: Int64 = 0, total: Int64? = nil, detail: String = "") {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.detail = detail
    }
}

/// A retargeted, signed tree ready to be packaged: its ID, its files'
/// digests (relative paths), and the opaque manifest the backend needs back.
public struct PreparedToolchain: Sendable {
    public var id: String
    public var product: ToolchainProduct
    public var components: [ToolchainComponentKind]
    public var tree: URL
    /// Relative path → SHA-256.
    public var files: [String: String]
    /// `usr/lib/apelin/toolchains/<id>`, relative to the install root.
    public var installRelativePath: String
    /// The backend's own manifest, encoded; handed back to `installAndValidate`.
    public var manifest: Data
    /// The retarget scheme that made the tree, which its record keeps
    /// (`ToolchainRecord.retargetScheme`).
    public var retargetScheme: Int?

    public init(
        id: String,
        product: ToolchainProduct,
        components: [ToolchainComponentKind],
        tree: URL,
        files: [String: String],
        installRelativePath: String,
        manifest: Data,
        retargetScheme: Int? = nil,
    ) {
        self.retargetScheme = retargetScheme
        self.id = id
        self.product = product
        self.components = components
        self.tree = tree
        self.files = files
        self.installRelativePath = installRelativePath
        self.manifest = manifest
    }
}

/// Installs a prepared tree at its final place; the environment worker's is
/// "package a local deb, hand it to the session host's install bridge".
/// Must be idempotent for the toolchain ID and settle before returning.
public typealias ToolchainInstallStep = @Sendable (PreparedToolchain) async throws -> Void

/// The device-side retargeting the environment worker drives: list Apple's
/// CLT products, fetch and retarget one into a signed tree, then — after the
/// worker installs it — verify the installed bytes and self-test them.
///
/// The real one is `Packages/ApelinToolchain` (`ToolchainCatalog`,
/// `ToolchainSetup`, `ToolchainSelfTest`), adapted by
/// `RetargetToolchainBackend` when that package is linked. Without it the
/// worker answers toolchain setup with `unavailable`, and status and removal
/// still work from the registry.
public protocol ToolchainBackend: Sendable {
    /// Whether this build can set a toolchain up at all.
    var isAvailable: Bool { get }

    func catalog() async throws -> [ToolchainProduct]

    /// Fetches and retargets `product` in `staging` (kept across runs for
    /// resume: a verified download or tree is reused) into `output`.
    func prepare(
        product: ToolchainProduct,
        components: [ToolchainComponentKind],
        staging: URL,
        output: URL,
        progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> PreparedToolchain

    /// Runs `install` unless the installed bytes already match, verifies them
    /// at `<installRoot>/<installRelativePath>`, self-tests against `sdk`,
    /// and answers the results. Throws when a C-family case fails.
    func installAndValidate(
        _ prepared: PreparedToolchain,
        installRoot: URL,
        sdk: URL,
        journal: URL,
        scratch: URL,
        install: @escaping ToolchainInstallStep,
        progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> [ToolchainSelfTestResult]

    /// Self-tests the toolchain installed at `installed` against `sdk`, as
    /// setup does after installing; answers every case, passed or not.
    func selfTest(
        installed: URL,
        sdk: URL,
        scratch: URL,
        progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> [ToolchainSelfTestResult]

    // Transfer files; defaults below.
    func exportTree(installed: URL, into destination: URL) throws -> PreparedToolchain
    func importTree(_ tree: URL) throws -> PreparedToolchain
    func importRefusal(_ toolchain: TransferToolchain) -> String?
}

public extension ToolchainBackend {
    func selfTest(
        installed _: URL,
        sdk _: URL,
        scratch _: URL,
        progress _: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> [ToolchainSelfTestResult] {
        throw ApelinError(.unavailable, UnavailableToolchainBackend.selfTestUnavailable)
    }
}

/// Moving a toolchain between devices (`.apetc`, ApelinEnvironment ▸
/// Transfer). Each has a default that answers `unavailable`, which a build
/// without `Packages/ApelinToolchain` keeps.
public extension ToolchainBackend {
    /// Copies the toolchain installed at `installed` into `destination`
    /// (which must not exist) exactly as setup packaged it, every file
    /// checked against its digest and RootHide's runtime brand undone, and
    /// answers it as prepared, `tree` being `destination`.
    func exportTree(installed _: URL, into _: URL) throws -> PreparedToolchain {
        throw ApelinError(.unavailable, UnavailableToolchainBackend.transferUnavailable)
    }

    /// Checks a toolchain tree another device exported: its own manifest's
    /// identity, a release and source Apelin still supports, the files and
    /// links it lists and nothing else. Answers it as prepared.
    func importTree(_: URL) throws -> PreparedToolchain {
        throw ApelinError(.unavailable, UnavailableToolchainBackend.transferUnavailable)
    }

    /// Why this device would not take the toolchain a transfer file
    /// describes, in a sentence a user reads; nil when it would.
    func importRefusal(_: TransferToolchain) -> String? {
        UnavailableToolchainBackend.transferUnavailable
    }
}

/// The backend of a build without `Packages/ApelinToolchain`.
public struct UnavailableToolchainBackend: ToolchainBackend {
    static let setupUnavailable = "Toolchain setup is not available in this version of Apelin."
    static let transferUnavailable = "Toolchain import and export are not available in this version of Apelin."
    static let selfTestUnavailable = "Toolchain self-tests are not available in this version of Apelin."

    public init() {}

    public var isAvailable: Bool {
        false
    }

    private var failure: ApelinError {
        ApelinError(.unavailable, Self.setupUnavailable)
    }

    public func catalog() async throws -> [ToolchainProduct] {
        throw failure
    }

    public func prepare(
        product _: ToolchainProduct,
        components _: [ToolchainComponentKind],
        staging _: URL,
        output _: URL,
        progress _: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> PreparedToolchain {
        throw failure
    }

    public func installAndValidate(
        _: PreparedToolchain,
        installRoot _: URL,
        sdk _: URL,
        journal _: URL,
        scratch _: URL,
        install _: @escaping ToolchainInstallStep,
        progress _: @escaping @Sendable (ToolchainBackendProgress) -> Void,
    ) async throws -> [ToolchainSelfTestResult] {
        throw failure
    }
}

/// The backend this build links.
public enum ToolchainBackends {
    public static var linked: any ToolchainBackend {
        #if canImport(ApelinToolchain)
            return RetargetToolchainBackend()
        #else
            return UnavailableToolchainBackend()
        #endif
    }
}
