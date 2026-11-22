import Darwin
import Foundation

public struct ToolchainSetup: Sendable {
    /// 3: otool-classic and ranlib, which `otool` and `ar rcs` exec beside
    /// themselves, are in the tree (`DependencyClosure.entryTools`), and the
    /// self-test runs both. 2: the iOS builtins (libclang_rt.ios.a) are kept,
    /// so `@available` links; and the Swift component exists. The scheme is
    /// part of the ID, so a release set up again is a toolchain of its own
    /// beside the earlier one, which keeps its ID, its files and the
    /// projects bound to it.
    public static let schemeVersion = 3
    /// The schemes of trees Apelin still verifies, self-tests, exports and
    /// imports: a scheme 2 tree lacks only what scheme 3 added. No scheme 1
    /// tree was ever released.
    public static let readableSchemes = 2 ... schemeVersion
    /// The iOS version setup builds every tool for unless told otherwise, and so the
    /// oldest host each release's `compatibility` states.
    public static let defaultMinimumOS = "16.0"
    public let minimumOS: String
    public let limits: ToolchainArchiveLimits
    public init(minimumOS: String = Self.defaultMinimumOS, limits: ToolchainArchiveLimits = .init()) {
        self.minimumOS = minimumOS; self.limits = limits
    }

    /// Produces a signed installable tree. Returns at packaging; installation/validation belong to the host.
    /// Staging must be a private, task-owned directory. Reusing it with different parameters is refused.
    public func run(
        source: ToolchainSource,
        components: Set<ToolchainComponent> = [.base],
        staging: URL,
        output: URL,
        progress: @escaping ToolchainProgressHandler = { _ in },
    ) async throws -> ToolchainManifest {
        if let reason = CommandLineToolsSupport.refusal(for: source.version, productID: source.productID) {
            throw ToolchainFailure(reason)
        }
        let release = CommandLineToolsSupport.release(source.version)! // refusal(for:) answered nil
        if let reason = release.compatibility.hostRefusal {
            throw ToolchainFailure(reason)
        }
        guard components.contains(.base) else {
            throw ToolchainFailure("The base component is required. Add it to the selected components.")
        }
        // No ABI guesses: Swift is set up only for a release whose Swift tools passed the Swift
        // self-test, on a host satisfying that release’s system and CPU requirements.
        if components.contains(.swift) {
            guard release.swift else {
                throw ToolchainFailure(release.swiftUnavailable ??
                    "Swift is not available with Command Line Tools \(source.version) yet: only "
                    + CommandLineToolsSupport.releases.filter(\.swift).map(\.version).joined(separator: ", ")
                    + " passed the Swift self-test. Set this one up without Swift, or pick that release.")
            }
            if let reason = release.swiftSupport?.hostRefusal {
                throw ToolchainFailure(reason)
            }
        }
        let version = try Self.encodedVersion(minimumOS)
        try directory(staging)
        let staging = try canonical(staging)
        let lock = open(staging.appendingPathComponent("task.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ToolchainFailure("Unable to start the toolchain setup. Try again.") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw ToolchainFailure("This toolchain setup is already running. Wait for it to finish.")
        }
        let request = Request(source: source, components: components, minimumOS: minimumOS, scheme: Self.schemeVersion)
        let identity = staging.appendingPathComponent("request.json")
        if FileManager.default.fileExists(atPath: identity.path) {
            let staged = try JSONDecoder().decode(Request.self, from: Data(contentsOf: identity))
            // The same package an earlier scheme staged (a setup that failed
            // or stopped before Apelin was updated) keeps its verified
            // download; extraction and adaptation are done again anyway.
            guard staged == request || staged.scheme < request.scheme && staged.retargeted(request.scheme) == request
            else {
                throw ToolchainFailure("The staging folder belongs to another setup request.")
            }
            if staged != request {
                try writeJSON(request, to: identity)
            }
        } else {
            try writeJSON(request, to: identity)
        }
        func stage(_ value: ToolchainStage) throws {
            try Task.checkCancellation()
            try writeJSON(value, to: staging.appendingPathComponent("stage.json"))
            progress(.init(stage: value, completedBytes: 0, totalBytes: nil, detail: value.rawValue))
        }
        try stage(.downloading)
        let package = try await ResumableDownload.run(source, in: staging, progress: progress)
        let digest = try digestFile(package)
        guard release.sources[source.productID] == digest else {
            throw ToolchainFailure(
                "The downloaded Apple package differs from the reviewed source for Command Line Tools \(source.version).",
            )
        }
        let id = Self.identity(sourceSHA256: digest, minimumOS: minimumOS, components: components)
        let manifestPath = output.appendingPathComponent("manifest.json")
        if let old = try? JSONDecoder().decode(ToolchainManifest.self, from: Data(contentsOf: manifestPath)) {
            if old.id == id {
                try Self.verify(old, at: output)
                return old
            }
            // This request's tree as an earlier scheme made it, under its own
            // ID: superseded, and made again below.
            if old.retargetSchemeVersion < Self.schemeVersion, old.sourceSHA256 == digest,
               old.minimumOS == minimumOS, old.components == components
            {
                try FileManager.default.removeItem(at: output)
            }
        }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolchainFailure("The output folder already exists and does not match this toolchain.")
        }
        // Restart incomplete extraction/adaptation from the verified download. Never trust a stage marker alone.
        let extracted = staging.appendingPathComponent("extracted"), adapted = staging.appendingPathComponent("adapted")
        for path in [extracted, adapted] {
            if FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.removeItem(at: path)
            }
        }
        do {
            try stage(.extracting)
            try PackageArchive(limits: limits).extract(package, to: extracted)
            let clt = try Self.findCLT(extracted)
            try stage(.adapting)
            var closure = DependencyClosure(root: clt, components: components)
            let files = try closure.select()
            let links = try closure.links(selected: files)
            let renames = components.contains(.swift) ? release.swiftImportRenames : [:]
            try directory(adapted)
            for (relative, sourceFile) in files.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let target = adapted.appendingPathComponent(relative)
                    try directory(target.deletingLastPathComponent())
                    let data = try Data(contentsOf: sourceFile, options: .mappedIfSafe)
                    let magic = data.count >= 4 ? try data.number(0, as: UInt32.self) : 0
                    if !relative.hasPrefix("usr/lib/clang/"), magic == 0xFEED_FACF || magic == 0xBEBA_FECA {
                        var image = try MachOImage(data)
                        let rpaths = try image.rpaths
                        _ = try image.weakenLoads(of: release.weakSystemLibraries)
                        _ = try image.renameImports(renames)
                        try image.retarget(minimumOS: version) { name, kind in
                            if kind == 0xD {
                                return "@rpath/" + (relative as NSString).lastPathComponent
                            }
                            if kind == 0x8000_001C {
                                return "@loader_path"
                            }
                            if let dependency = try closure.resolve(name, loader: relative, rpaths: rpaths) {
                                guard files[dependency] != nil else {
                                    throw ToolchainFailure("The toolchain is missing a required file: \(dependency).")
                                }
                                return DependencyClosure.relativeReference(from: relative, to: dependency)
                            }
                            return MachOImage.flattened(name)
                        }
                        try image.signed(identifier: target.lastPathComponent).write(to: target, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                    } else {
                        try FileManager.default.copyItem(at: sourceFile, to: target)
                    }
                    progress(.init(stage: .adapting, completedBytes: 0, totalBytes: nil, detail: relative))
                }
            }
            for (relative, target) in links.sorted(by: { $0.key < $1.key }) {
                let link = adapted.appendingPathComponent(relative)
                try directory(link.deletingLastPathComponent())
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            }
            if components.contains(.swift) {
                // swiftc hands ld `-L usr/lib/swift/iphoneos`, where Xcode keeps iOS back-deployment
                // libraries. The CLT has none for iOS; the empty folder only keeps ld from warning.
                try directory(adapted.appendingPathComponent("usr/lib/swift/iphoneos"))
            }
            try stage(.packaging)
            // A root-owned installed tree must remain traversable by mobile.
            let directories = FileManager.default.enumerator(
                at: adapted,
                includingPropertiesForKeys: [.isDirectoryKey],
            )!
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adapted.path)
            while let path = directories.nextObject() as? URL {
                if try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
                }
            }
            let relatives = Array(files.keys)
            let values = try concurrentMap(relatives) { try digestFile(adapted.appendingPathComponent($0)) }
            let digests = Dictionary(uniqueKeysWithValues: zip(relatives, values))
            let manifest = ToolchainManifest(
                id: id,
                source: source,
                sourceSHA256: digest,
                retargetSchemeVersion: Self.schemeVersion,
                minimumOS: minimumOS,
                components: components,
                files: digests,
                links: links.isEmpty ? nil : links,
                stage: .packaging,
                selfTests: [],
                newestSDK: release.newestSDK,
                swiftSupport: release.swiftSupport,
                clangModuleCPUFeatures: release.clangModuleCPUFeatures,
                compatibility: release.compatibility,
            )
            try writeJSON(manifest, to: adapted.appendingPathComponent("manifest.json"))
            let parent = try canonical(output.deletingLastPathComponent())
            guard !contained(parent, in: extracted), !contained(parent, in: adapted) else {
                throw ToolchainFailure("Output is inside an intermediate tree")
            }
            try FileManager.default.moveItem(at: adapted, to: parent.appendingPathComponent(output.lastPathComponent))
            try FileManager.default.removeItem(at: extracted)
            return manifest
        } catch {
            try? writeJSON(String(describing: error), to: staging.appendingPathComponent("failure.json"))
            throw error
        }
    }

    /// Rechecks installed bytes before the host starts validation or resumes a completed install.
    public static func verify(_ manifest: ToolchainManifest, at root: URL) throws {
        try validateIdentity(manifest)
        let root = try canonical(root)
        func plain(_ relative: String) -> Bool {
            !relative.hasPrefix("/") && !relative.utf8.contains(0) && !relative.split(separator: "/").contains("..")
        }
        let files = manifest.files.sorted { $0.key < $1.key }
        guard files.allSatisfy({ plain($0.key) }) else {
            throw ToolchainFailure("The toolchain manifest lists an invalid file path. Set up the toolchain again.")
        }
        // Every file hashed again, on several cores: each check stands alone.
        _ = try concurrentMap(files) { relative, digest in
            let file = try canonical(root.appendingPathComponent(relative))
            guard contained(file, in: root), try matchesToolchainDigest(file, expected: digest) else {
                throw ToolchainFailure(
                    "The toolchain file failed its integrity check: \(relative). Set up the toolchain again.",
                )
            }
        }
        for (relative, target) in manifest.links ?? [:] {
            guard DependencyClosure.lexicallyResolved(target, from: relative) != nil, plain(relative) else {
                throw ToolchainFailure("The toolchain manifest lists an invalid link. Set up the toolchain again.")
            }
            let link = root.appendingPathComponent(relative)
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) == target,
                  try contained(canonical(link), in: root)
            else {
                throw ToolchainFailure("The toolchain link has changed: \(relative). Set up the toolchain again.")
            }
        }
    }

    /// The toolchain ID setup gives these sources and components under
    /// `scheme`, the current one unless a tree an earlier one made is checked.
    static func identity(
        sourceSHA256: String,
        scheme: Int = schemeVersion,
        minimumOS: String,
        components: Set<ToolchainComponent>,
    ) -> String {
        // The base-only ID keeps its original spelling, so a registered base toolchain keeps its ID.
        let componentKey = components.contains(.swift) ? "base+swift" : "base"
        return String(sha256(Data("\(sourceSHA256):\(scheme):\(minimumOS):\(componentKey)".utf8)).prefix(24))
    }

    static func validateIdentity(_ manifest: ToolchainManifest) throws {
        guard manifest.id.count == 24, manifest.id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              manifest.sourceSHA256.count == 64, !manifest.files.isEmpty,
              manifest.components.contains(.base), readableSchemes.contains(manifest.retargetSchemeVersion)
        else {
            throw ToolchainFailure(
                "The toolchain manifest is invalid or from another version of Apelin. Set up the toolchain again.",
            )
        }
    }

    static func encodedVersion(_ version: String) throws -> UInt32 {
        let parts = version.split(separator: ".").compactMap { UInt32($0) }
        guard
            (1 ... 3).contains(parts.count),
            parts[0] <= 0xFFFF,
            parts.dropFirst().allSatisfy({ $0 <= 255 }),
            parts.count == version.split(separator: ".").count
        else {
            throw ToolchainFailure("Invalid target OS version")
        }
        return (parts[0] << 16) | ((parts.count > 1 ? parts[1] : 0) << 8) | (parts.count > 2 ? parts[2] : 0)
    }

    private static func findCLT(_ root: URL) throws -> URL {
        for path in ["Library/Developer/CommandLineTools", "CommandLineTools", ""] {
            let candidate = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("usr/bin/clang").path) {
                return try canonical(candidate)
            }
        }
        throw ToolchainFailure("The package does not contain Command Line Tools.")
    }

    struct Request: Codable, Equatable {
        let source: ToolchainSource; let components: Set<ToolchainComponent>; let minimumOS: String; let scheme: Int

        /// The same request under another scheme.
        func retargeted(_ scheme: Int) -> Request {
            Request(source: source, components: components, minimumOS: minimumOS, scheme: scheme)
        }
    }
}

public extension ToolchainSetup {
    /// The environment host supplies the authenticated Irisin transaction. The closure must be
    /// idempotent for this manifest ID and return only after the transaction is settled.
    /// Task cancellation is checked after installation, never used to claim a transaction rolled back.
    func installAndValidate(
        manifest: ToolchainManifest,
        tree: URL,
        installRoot: URL,
        sdk: URL,
        journal: URL,
        scratch: URL,
        install: @Sendable (URL, ToolchainManifest, URL) async throws -> Void,
        progress: @escaping ToolchainProgressHandler = { _ in },
    ) async throws -> ToolchainManifest {
        try Self.validateIdentity(manifest)
        let installRoot = try canonical(installRoot)
        let destination = installRoot.appendingPathComponent(manifest.installRelativePath)
        try directory(journal)
        let record = journal.appendingPathComponent(manifest.id + ".json")
        var result = manifest
        // Revalidate against the supplied SDK on every call. A prior ready journal
        // cannot prove that the SDK bytes/identity are still the same.
        result.stage = .installing; try writeJSON(result, to: record)
        progress(.init(stage: .installing, completedBytes: 0, totalBytes: nil, detail: manifest.id))
        if (try? Self.verify(manifest, at: destination)) == nil {
            try Self.verify(manifest, at: tree)
            try await install(tree, manifest, destination)
        }
        try Task.checkCancellation()
        try Self.verify(manifest, at: destination)
        result.stage = .validating; try writeJSON(result, to: record)
        result.selfTests = try await ToolchainSelfTest().run(
            toolchain: destination,
            sdk: sdk,
            scratch: scratch,
            progress: progress,
        )
        guard !result.selfTests.isEmpty, result.selfTests.allSatisfy(\.passed) else {
            try writeJSON(result, to: record)
            throw ToolchainFailure(
                "The installed toolchain failed its self-test. The test results are saved with this task.",
            )
        }
        result.stage = .ready; try writeJSON(result, to: record)
        progress(.init(stage: .ready, completedBytes: 0, totalBytes: nil, detail: manifest.id))
        return result
    }
}
