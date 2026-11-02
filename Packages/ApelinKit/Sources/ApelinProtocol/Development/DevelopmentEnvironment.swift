import ApelinCore
import Darwin
import Foundation

/// The toolchain and SDK a command on the device compiles with, and the
/// variables that hand them to it. The session host builds it for the
/// agent's shell_run (`agentRunCode`) and for the user's terminal
/// (`ptyOpen`); the agent's system prompt describes the same one, so what
/// the model is told is what its commands get.
///
/// The toolchain is the one the project binds when it is registered, else
/// the registry's default; the SDK is the one the project binds when it is
/// registered, else the newest registered one the toolchain reads — what
/// `projectCreate` would bind. Only paths, IDs and a version go into the
/// variables, never a credential.
public struct DevelopmentEnvironment: Sendable, Equatable {
    /// Why a toolchain or SDK was chosen.
    public enum Source: String, Sendable, Equatable {
        /// `apelin-project.json` binds it, and it is registered.
        case project
        /// The registry's default toolchain, or the newest SDK it reads.
        case fallback
    }

    public struct Toolchain: Sendable, Equatable {
        public var record: ToolchainRecord
        /// Canonical: where clang, ld and swiftc are.
        public var binDirectory: String
        public var source: Source
    }

    public struct SDK: Sendable, Equatable {
        public var record: SDKRecord
        /// Canonical: what `SDKROOT` names.
        public var path: String
        public var source: Source
    }

    /// What a project gets when it names no deployment target, and what a
    /// command outside a project builds for: `projectCreate`'s default and
    /// the oldest iOS Apelin runs on.
    public static let defaultDeploymentTarget = "16.0"

    public var toolchain: Toolchain?
    public var sdk: SDK?
    public var deploymentTarget: String

    public init(toolchain: Toolchain?, sdk: SDK?, deploymentTarget: String) {
        self.toolchain = toolchain
        self.sdk = sdk
        self.deploymentTarget = deploymentTarget
    }

    /// The environment a command in `projectDirectory` (or, with nil, in no
    /// project) gets, read from the registries in mobile's data folder.
    public static func prepared(home: String, projectDirectory: String?) -> DevelopmentEnvironment {
        resolve(
            RegisteredEnvironment.read(DataFolder(home: home)),
            binding: projectDirectory.flatMap(ProjectManifestBinding.read(projectDirectory:)),
        )
    }

    public static func resolve(
        _ registered: RegisteredEnvironment,
        binding: ProjectManifestBinding?,
    ) -> DevelopmentEnvironment {
        func usable(_ record: ToolchainRecord, _ source: Source) -> Toolchain? {
            guard let path = record.path, let bin = ToolchainLayout.binDirectory(installedAt: path) else { return nil }
            return Toolchain(record: record, binDirectory: bin, source: source)
        }
        func usable(_ record: SDKRecord, _ source: Source) -> SDK? {
            guard let path = Self.directory(record.path) else { return nil }
            return SDK(record: record, path: path, source: source)
        }

        let bound = binding?.toolchainID.flatMap { id in registered.toolchains.first { $0.id == id } }
        let fallbacks = registered.toolchains.filter { $0.id == registered.defaultToolchainID }
            + registered.toolchains.filter { $0.id != registered.defaultToolchainID }
        let toolchain = bound.flatMap { usable($0, .project) }
            ?? fallbacks.lazy.compactMap { usable($0, .fallback) }.first

        let boundSDK = binding?.sdkID.flatMap { id in registered.sdks.first { $0.id == id } }
        let readable = registered.sdks
            .filter { SDKVersionLimit.allows(sdkVersion: $0.version, newestSDK: toolchain?.record.newestSDK) }
            .sorted { RegisteredEnvironment.newerFirst($0, $1) }
        let sdk = boundSDK.flatMap { usable($0, .project) }
            ?? readable.lazy.compactMap { usable($0, .fallback) }.first

        let target = binding?.deploymentTarget.flatMap { Self.isVersion($0) ? $0 : nil }
        return DevelopmentEnvironment(
            toolchain: toolchain,
            sdk: sdk,
            deploymentTarget: target ?? defaultDeploymentTarget,
        )
    }

    /// The variables to set: `PATH` with the toolchain's tools first, then
    /// `basePath`; `SDKROOT` and `IPHONEOS_DEPLOYMENT_TARGET` when there is
    /// an SDK (clang then targets iOS against it without `-isysroot` or
    /// `-target`, and swiftc takes the SDK from `SDKROOT`); and
    /// `APELIN_TOOLCHAIN_BIN`, which the package's login profile snippet puts
    /// back on a `PATH` the bootstrap's `/etc/profile` replaced.
    public func variables(basePath: [String]) -> [String: String] {
        var path = basePath
        var variables: [String: String] = [:]
        if let toolchain {
            path.removeAll { $0 == toolchain.binDirectory }
            path.insert(toolchain.binDirectory, at: 0)
            variables[Self.toolchainBinVariable] = toolchain.binDirectory
        }
        variables["PATH"] = path.joined(separator: ":")
        if let sdk {
            variables["SDKROOT"] = sdk.path
            variables["IPHONEOS_DEPLOYMENT_TARGET"] = deploymentTarget
        }
        return variables
    }

    /// The same, as `NAME=value` entries for `posix_spawn`, sorted.
    public func entries(basePath: [String]) -> [String] {
        variables(basePath: basePath).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    public static let toolchainBinVariable = "APELIN_TOOLCHAIN_BIN"

    /// The directories shell_run looks a bare command name up in, and its
    /// `PATH` behind the toolchain: the bootstrap's bin directories, then
    /// the system's. The agent's system prompt names what it finds there.
    public static func searchPath(installRoot: String) -> [String] {
        let prefix = installRoot == "/" ? "" : installRoot
        var directories = ["\(prefix)/usr/bin", "\(prefix)/bin", "\(prefix)/usr/local/bin"]
        if !prefix.isEmpty {
            directories += ["/usr/bin", "/bin"]
        }
        return directories
    }

    /// A canonical directory that can stand in `PATH` or a variable: no NUL,
    /// no line break, no `:` (which would split `PATH`).
    static func directory(_ path: String) -> String? {
        guard path.hasPrefix("/"), let real = CanonicalPath.resolve(path),
              !real.contains(":"), !real.contains("\n"), !real.contains("\r")
        else { return nil }
        var metadata = stat()
        guard stat(real, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return nil }
        return real
    }

    /// `16.0`, `17.3.1`: what clang takes as a deployment target.
    static func isVersion(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1 ... 3).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

public extension BuildBootstrap {
    /// Which layout this device's bootstrap is, from what the session host
    /// assigned: on roothide mobile's home is inside the jbroot (the install
    /// root), on rootless it is the system's `/var/mobile` beside `/var/jb`.
    /// The install root comes from apelind's `hello`; nothing here guesses it.
    static func resolve(installRoot: String, home: String) -> BuildBootstrap {
        let root = installRoot.hasSuffix("/") ? String(installRoot.dropLast()) : installRoot
        guard !root.isEmpty else { return .rootless }
        return CanonicalPath.isCanonical(home, inside: root) ? .roothide : .rootless
    }
}

/// Where an installed toolchain keeps its tools: `<path>/usr/bin`, or the
/// CLT's own `<path>/Library/Developer/CommandLineTools/usr/bin` when the
/// tree keeps that layout.
public enum ToolchainLayout {
    public static let flatBin = "usr/bin"
    public static let commandLineToolsBin = "Library/Developer/CommandLineTools/usr/bin"

    /// The canonical tool directory, or nil when neither exists.
    public static func binDirectory(installedAt path: String) -> String? {
        DevelopmentEnvironment.directory(path + "/" + flatBin)
            ?? DevelopmentEnvironment.directory(path + "/" + commandLineToolsBin)
    }
}

/// What apelin-environment registered, read as it wrote it:
/// `Environment/Toolchains/registry.json` (`{toolchains: [ToolchainRecord],
/// defaultID}`, a toolchain recorded only once its installed bytes passed
/// the C self-test) and `SDKs/.registry/<id>.json` (one `SDKRecord` each).
///
/// The session host reads these as root from a folder mobile owns, so every
/// file is opened only when its canonical path, and the opened descriptor's
/// own path, are inside the data folder, without following a link, regular
/// and bounded. A file that does not read is left out, never an error.
public struct RegisteredEnvironment: Sendable, Equatable {
    public var toolchains: [ToolchainRecord]
    public var defaultToolchainID: String?
    /// Newest version first, then by ID.
    public var sdks: [SDKRecord]

    static let maximumRegistryBytes = 4 << 20
    static let maximumRecordBytes = 1 << 20
    static let maximumSDKRecords = 256

    public init(toolchains: [ToolchainRecord] = [], defaultToolchainID: String? = nil, sdks: [SDKRecord] = []) {
        self.toolchains = toolchains
        self.defaultToolchainID = defaultToolchainID ?? toolchains.first?.id
        self.sdks = sdks.sorted(by: Self.newerFirst)
    }

    /// Read one record at a time (`PreservedList`): one this version cannot
    /// read leaves the others usable.
    private struct ToolchainFile: Decodable {
        var toolchains: PreservedList<ToolchainRecord>?
        var defaultID: String?
    }

    public static func read(_ folder: DataFolder) -> RegisteredEnvironment {
        guard let root = CanonicalPath.resolve(folder.root.path) else { return RegisteredEnvironment() }
        var toolchains: [ToolchainRecord] = []
        var defaultID: String?
        if let data = BoundedFile.read(folder.toolchainRegistry.path, inside: root, limit: maximumRegistryBytes),
           let file = try? JSONCoding.decode(ToolchainFile.self, from: data)
        {
            toolchains = (file.toolchains?.items ?? []).map { record in
                var current = record
                current.path = record.path.map { BootstrapRootPath.rebased($0, onto: root) }
                return current
            }
            defaultID = file.defaultID
        }
        var sdks: [SDKRecord] = []
        if let directory = CanonicalPath.resolve(folder.sdkRegistry.path),
           CanonicalPath.isCanonical(directory, inside: root)
        {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
                .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
                .sorted()
                .prefix(maximumSDKRecords)
            for name in names {
                guard let data = BoundedFile.read(directory + "/" + name, inside: root, limit: maximumRecordBytes),
                      var record = try? JSONCoding.decode(SDKRecord.self, from: data) else { continue }
                record.path = BootstrapRootPath.rebased(record.path, onto: root)
                sdks.append(record)
            }
        }
        return RegisteredEnvironment(toolchains: toolchains, defaultToolchainID: defaultID, sdks: sdks)
    }

    /// Newest version first; equal versions by ID, so the order is stable.
    static func newerFirst(_ lhs: SDKRecord, _ rhs: SDKRecord) -> Bool {
        switch lhs.version.compare(rhs.version, options: .numeric) {
        case .orderedDescending: true
        case .orderedAscending: false
        case .orderedSame: lhs.id < rhs.id
        }
    }
}

/// What `apelin-project.json` binds: the toolchain and SDK by ID, and the
/// deployment target. Read loosely, as the session host reads a manifest:
/// the project checks are apelin-build's.
public struct ProjectManifestBinding: Sendable, Equatable {
    public static let manifestFile = "apelin-project.json"
    static let maximumManifestBytes = 1 << 20

    public var toolchainID: String?
    public var sdkID: String?
    public var deploymentTarget: String?

    public init(toolchainID: String? = nil, sdkID: String? = nil, deploymentTarget: String? = nil) {
        self.toolchainID = toolchainID
        self.sdkID = sdkID
        self.deploymentTarget = deploymentTarget
    }

    public init(manifest: JSONValue) {
        toolchainID = manifest.value(at: "environment.toolchain.id")?.stringValue
        sdkID = manifest.value(at: "environment.sdk.id")?.stringValue
        deploymentTarget = manifest["deploymentTarget"]?.stringValue
    }

    /// Nil when the folder has no manifest that reads as JSON.
    public static func read(projectDirectory: String) -> ProjectManifestBinding? {
        guard let root = CanonicalPath.resolve(projectDirectory),
              let data = BoundedFile.read(root + "/" + manifestFile, inside: root, limit: maximumManifestBytes),
              let manifest = try? JSONCoding.decode(JSONValue.self, from: data)
        else { return nil }
        return ProjectManifestBinding(manifest: manifest)
    }
}

/// A regular file read whole, only from inside `root` (canonical): the path
/// is canonicalised and checked, opened without following a link, and the
/// descriptor's own path checked again, so a folder swapped for a link in
/// between leads nowhere.
public enum BoundedFile {
    public static func read(_ path: String, inside root: String, limit: Int) -> Data? {
        guard let real = CanonicalPath.resolve(path), CanonicalPath.isCanonical(real, inside: root) else { return nil }
        let descriptor = open(real, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var metadata = stat()
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0,
              let opened = CanonicalPath.resolve(String(cString: buffer)),
              CanonicalPath.isCanonical(opened, inside: root),
              fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= off_t(limit),
              let data = try? handle.read(upToCount: limit + 1), data.count <= limit
        else { return nil }
        return data
    }
}
