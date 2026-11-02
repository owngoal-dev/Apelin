import ApelinCore
import ApelinProtocol
import Foundation

/// A toolchain apelin-environment registered: where its tools are on disk
/// (a physical path — the toolchain does not link libvroot and sees the real
/// root) and what it can compile.
public struct RegisteredToolchain: Codable, Sendable, Equatable {
    public var id: String
    /// `sha256:` digest a project binds to; a toolchain registered again with
    /// other contents gets another.
    public var digest: String
    /// The CLT product version, `27.0`.
    public var version: String
    /// The installed tree: `usr/bin/clang`, `usr/bin/lipo`, … below it, or
    /// below its `Library/Developer/CommandLineTools`, as the CLT lays it out.
    public var path: String
    /// `c-family`, `swift`: the names extension manifests use.
    public var components: [String]
    /// The newest iPhoneOS SDK (major.minor) its tools read; nil: any.
    public var newestSDK: String?
    public var swiftRequirements: SwiftToolchainRequirements?
    public var clangModuleCPUFeatures: [String]?
    public var compatibility: ToolchainCompatibility?

    public init(
        id: String,
        digest: String,
        version: String,
        path: String,
        components: [String],
        newestSDK: String? = nil,
        swiftRequirements: SwiftToolchainRequirements? = nil,
        clangModuleCPUFeatures: [String]? = nil,
        compatibility: ToolchainCompatibility? = nil,
    ) {
        self.id = id
        self.digest = digest
        self.version = version
        self.path = path
        self.components = components
        self.newestSDK = newestSDK
        self.swiftRequirements = swiftRequirements
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.compatibility = compatibility
    }

    /// Whether its tools read an SDK of `version` (`SDKVersionLimit`).
    public func reads(sdkVersion version: String) -> Bool {
        SDKVersionLimit.allows(sdkVersion: version, newestSDK: newestSDK)
    }

    /// A tool by name: `<path>/usr/bin/<name>`, or the CLT's own
    /// `<path>/Library/Developer/CommandLineTools/usr/bin/<name>` when the
    /// tree keeps that layout.
    public func tool(_ name: String) -> URL {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let flat = root.appendingPathComponent("usr/bin/\(name)")
        let commandLineTools = root.appendingPathComponent("Library/Developer/CommandLineTools/usr/bin/\(name)")
        if !FileManager.default.fileExists(atPath: flat.path),
           FileManager.default.fileExists(atPath: commandLineTools.path)
        {
            return commandLineTools
        }
        return flat
    }
}

/// An SDK apelin-environment registered, at its physical path (what
/// `-isysroot` is given).
public struct RegisteredSDK: Codable, Sendable, Equatable {
    public var id: String
    public var digest: String
    /// `SDKSettings.json`'s `Version`, `27.0`.
    public var version: String
    public var path: String
    /// From the `.tbd` targets, e.g. `arm64e-ios`.
    public var targets: [String]

    public init(id: String, digest: String, version: String, path: String, targets: [String] = []) {
        self.id = id
        self.digest = digest
        self.version = version
        self.path = path
        self.targets = targets
    }
}

/// What apelin-build reads about the registered environment. Writing it is
/// apelin-environment's; this side only reads (`EnvironmentStores`), by the
/// IDs a project binds.
public protocol EnvironmentRegistry: Sendable {
    func toolchains() throws -> [RegisteredToolchain]
    func sdks() throws -> [RegisteredSDK]
    /// What a new project binds to when the caller names none.
    func defaultToolchainID() throws -> String?
    func defaultSDKID() throws -> String?
}

public extension EnvironmentRegistry {
    func toolchain(_ id: String) throws -> RegisteredToolchain? {
        try toolchains().first { $0.id == id }
    }

    func sdk(_ id: String) throws -> RegisteredSDK? {
        try sdks().first { $0.id == id }
    }
}

/// apelin-environment's own stores, read as they are (ApelinEnvironment ▸
/// EnvironmentLayout): `Environment/Toolchains/registry.json`
/// (`{toolchains: [ToolchainRecord], defaultID}`, a toolchain recorded only
/// once its installed bytes passed the C self-test) and
/// `SDKs/.registry/<id>.json` (one `SDKRecord` each, written last when an
/// SDK is registered). Their digests are bare hex; a project binds them as
/// `sha256:<hex>`. A component counts only when its self-check passed.
/// Paths are taken to the bootstrap root the data folder is under now
/// (`BootstrapRootPath`), since roothide renames it on a reboot.
public struct EnvironmentStores: EnvironmentRegistry {
    public let dataFolder: DataFolder

    public init(dataFolder: DataFolder) {
        self.dataFolder = dataFolder
    }

    public var toolchainRegistry: URL {
        dataFolder.toolchainRegistry
    }

    public var sdkRegistry: URL {
        dataFolder.sdkRegistry
    }

    /// Read one record at a time (`PreservedList`): one this version cannot
    /// read leaves the others usable.
    private struct ToolchainFile: Decodable {
        var toolchains: PreservedList<ToolchainRecord>?
        var defaultID: String?
    }

    private func toolchainFile() throws -> ToolchainFile {
        guard let data = FileManager.default.contents(atPath: toolchainRegistry.path) else { return ToolchainFile() }
        return try JSONCoding.decode(ToolchainFile.self, from: data)
    }

    static func tagged(_ digest: String) -> String {
        digest.hasPrefix("sha256:") ? digest : "sha256:" + digest
    }

    public func toolchains() throws -> [RegisteredToolchain] {
        try (toolchainFile().toolchains?.items ?? []).compactMap { record in
            guard let path = record.path, let digest = record.contentDigest else { return nil }
            var components: [String] = []
            for component in record.components where component.selfCheckPassed == true {
                switch component.kind {
                case .c: components.append("c-family")
                case .swift: components.append("swift")
                case .auxiliary: break
                }
            }
            return RegisteredToolchain(
                id: record.id,
                digest: Self.tagged(digest),
                version: record.version,
                path: BootstrapRootPath.rebased(path, onto: dataFolder.root.path),
                components: components,
                newestSDK: record.newestSDK,
                swiftRequirements: record.swiftRequirements,
                clangModuleCPUFeatures: record.clangModuleCPUFeatures,
                compatibility: record.compatibility,
            )
        }
    }

    public func sdks() throws -> [RegisteredSDK] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sdkRegistry.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        return names.compactMap { name in
            guard let data = FileManager.default.contents(atPath: sdkRegistry.appendingPathComponent(name).path),
                  let record = try? JSONCoding.decode(SDKRecord.self, from: data),
                  let digest = record.digest else { return nil }
            return RegisteredSDK(
                id: record.id,
                digest: Self.tagged(digest),
                version: record.version,
                path: BootstrapRootPath.rebased(record.path, onto: dataFolder.root.path),
                targets: record.targets,
            )
        }
    }

    public func defaultToolchainID() throws -> String? {
        let file = try toolchainFile()
        return file.defaultID ?? file.toolchains?.items.first?.id
    }

    /// The newest registered SDK.
    public func defaultSDKID() throws -> String? {
        try sdks().max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }?.id
    }
}

/// A fixed registry, for tests and for the Mac pipeline test.
public struct StaticEnvironmentRegistry: EnvironmentRegistry {
    public var toolchainList: [RegisteredToolchain]
    public var sdkList: [RegisteredSDK]

    public init(toolchains: [RegisteredToolchain], sdks: [RegisteredSDK]) {
        toolchainList = toolchains
        sdkList = sdks
    }

    public func toolchains() throws -> [RegisteredToolchain] {
        toolchainList
    }

    public func sdks() throws -> [RegisteredSDK] {
        sdkList
    }

    public func defaultToolchainID() throws -> String? {
        toolchainList.first?.id
    }

    public func defaultSDKID() throws -> String? {
        sdkList.first?.id
    }
}
