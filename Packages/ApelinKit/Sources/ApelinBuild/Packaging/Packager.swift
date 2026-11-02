import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinProject
import ApelinProtocol
import Foundation

/// The record of one build's package, written beside the other builds'
/// at `~/Documents/wiki.qaq.apelin/Builds/artifacts/<artifactID>.json`.
/// `installPackage{artifactID, digest}` resolves it there; the session host
/// copies `path` to its private staging and checks `digest` before anything
/// is installed, so a record or deb changed after the build is refused.
public struct ArtifactRecord: Codable, Sendable, Equatable {
    public static let version = 1

    public var version: Int
    public var artifactID: String
    public var buildID: String
    public var projectID: String
    public var configuration: String
    public var bootstrap: String
    /// The deb.
    public var path: String
    /// `sha256:` of the deb's bytes.
    public var digest: String
    public var byteCount: Int64
    public var packageID: String
    public var packageVersion: String
    public var architecture: String
    /// Both description digests as they were when this was built. A
    /// workspace's build has no build description; its packaging digest is
    /// cut from the package it made (`ExternalBuild`).
    public var buildDigest: String?
    public var packagingDigest: String
    /// `external` for a workspace's own build; nil for apelin-build's.
    public var buildSystem: BuildSystemKind?
    /// The project's binding and template; nil for a workspace's build.
    public var toolchain: ProjectDocument.Binding?
    public var sdk: ProjectDocument.Binding?
    public var template: ProjectDocument.TemplateSource?
    public var products: [BuildProducts.Product]
    public var dsyms: [BuildProducts.DSYM]
    public var log: String
    public var loadCheck: BuildLoadCheck?
    public var createdAt: Date
    /// What the deb installs (`BuildArtifact.packageFiles`); nil in a
    /// record written before it was kept.
    public var packageFiles: [String]?

    public var wireArtifact: BuildArtifact {
        BuildArtifact(
            artifactID: artifactID,
            digest: digest,
            packageID: packageID,
            version: packageVersion,
            dsymUUIDs: dsyms.flatMap { $0.uuids.sorted { $0.key < $1.key }.map(\.value) },
            buildID: buildID,
            bootstrap: bootstrap,
            packagingDigest: packagingDigest,
            path: path,
            projectID: projectID,
            packageFiles: packageFiles,
        )
    }

    /// The regular files and links a package installs, as dpkg lists them:
    /// fewest components first, so a capped list keeps an app's executable
    /// and a tweak's dylib before the resources under them.
    static func packageFiles(of contents: DebArchiveReader.Contents) -> [String] {
        let files = contents.entries.filter { $0.kind != .directory }.map(\.path)
        let sorted = files.map { (depth: $0.split(separator: "/").count, path: $0) }
            .sorted { ($0.depth, $0.path) < ($1.depth, $1.path) }
        return sorted.prefix(BuildArtifact.maximumPackageFiles).map(\.path)
    }
}

public struct ArtifactStore: Sendable {
    public let directory: URL

    public init(store: ProjectStore) {
        directory = store.buildsDirectory.appendingPathComponent("artifacts", isDirectory: true)
    }

    public func url(of artifactID: String) -> URL {
        directory.appendingPathComponent("\(artifactID).json")
    }

    public func save(_ record: ArtifactRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder(pretty: true).encode(record).write(to: url(of: record.artifactID), options: .atomic)
    }

    /// Every record that reads, in no particular order.
    public func all() -> [ArtifactRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.compactMap { try? load(String($0.dropLast(5))) }
    }

    public func load(_ artifactID: String) throws -> ArtifactRecord {
        guard !artifactID.contains("/"), !artifactID.hasPrefix("."), !artifactID.isEmpty else {
            throw ApelinError(.badRequest, "not an artifact ID")
        }
        var record = try JSONCoding.decode(ArtifactRecord.self, from: Data(contentsOf: url(of: artifactID)))
        // a build from before roothide renamed its root (issue #34)
        record.path = BootstrapRootPath.rebased(record.path, onto: directory.path)
        return record
    }
}

/// The deb (Milestone 1 §8 打包): the project's logical layout mapped to the
/// bootstrap's package paths with `PackageLayout`, the control file from
/// `package`, the tweak filter beside its dylib, maintainer scripts with
/// `@PREFIX@` and `@ROOTFS@` filled and `sh -n` passing, written by
/// `DebPackageWriter`. No dpkg-deb.
public struct Packager: Sendable {
    public var inputs: BuildInputs
    public var products: BuildProducts
    /// The `sh` that checks maintainer scripts; nil skips nothing — a
    /// project with maintainer scripts and no shell to check them fails.
    public var shell: String?

    public init(inputs: BuildInputs, products: BuildProducts, shell: String? = nil) {
        self.inputs = inputs
        self.products = products
        self.shell = shell ?? Self.findShell(installRoot: inputs.installRoot)
    }

    static func findShell(installRoot: String) -> String? {
        let base = installRoot == "/" ? "" : installRoot
        return [base + "/bin/sh", base + "/usr/bin/sh", "/bin/sh"].first { access($0, X_OK) == 0 }
    }

    private var project: ProjectDocument {
        inputs.project
    }

    var layout: PackageLayout {
        inputs.bootstrap == .rootless ? .rootless : .roothide
    }

    public func control() throws -> DebianControlFile {
        let package = project.package
        let description = ([package.description] + (package.longDescription ?? []).map { $0.isEmpty ? "." : $0 })
            .joined(separator: "\n")
        var control = DebianControlFile(
            package: package.id,
            version: package.version,
            architecture: layout.architecture,
            description: description,
        )
        control["Name"] = package.name
        control["Icon"] = package.icon
        control["Author"] = package.author
        control["Maintainer"] = package.maintainer ?? package.author
        control["Section"] = package.section
        let depends = ["firmware (>= \(project.deploymentTarget))"]
            + (package.depends ?? [])
            + (package.dependsByBootstrap?[inputs.bootstrap] ?? [])
        control["Depends"] = depends.joined(separator: ", ")
        for (field, relations) in [
            ("Recommends", package.recommends),
            ("Suggests", package.suggests),
            ("Conflicts", package.conflicts),
            ("Breaks", package.breaks),
            ("Replaces", package.replaces),
            ("Provides", package.provides),
        ] {
            if let relations, !relations.isEmpty {
                control[field] = relations.joined(separator: ", ")
            }
        }
        return control
    }

    public struct Output: Sendable {
        public var path: String
        public var digest: String
        public var byteCount: Int64
        public var loadCheck: BuildLoadCheck?
    }

    public func write() throws -> Output {
        var writer = try DebPackageWriter(control: control())
        writer.modificationTime = inputs.timestamp
        // the session host reads control.tar before it installs; gzip it can open
        writer.controlCompression = .gzip
        var entries: [DebEntry] = []
        var dylibLayoutPath: String?
        for entry in project.package.layout {
            let packagePath = try layout.packagePath(for: entry.path)
            if let id = entry.product {
                guard let built = products.product(id) else {
                    throw BuildFailure("the layout installs \(id), which was not built")
                }
                if entry.product == project.package.tweakFilter?.dylib {
                    dylibLayoutPath = entry.path
                }
                if built.type == .app || built.type == .bundle {
                    entries += try DebEntry.tree(fromDirectory: built.path, at: packagePath).map { item in
                        var item = item
                        if item.path == packagePath + "/" + (built.executable as NSString).lastPathComponent {
                            item.mode = 0o755
                        }
                        return item
                    }
                } else {
                    entries.append(
                        .file(packagePath, copying: built.executable, mode: mode(entry.mode, default: 0o755)),
                    )
                }
            } else if let file = entry.file {
                var data = try inputs.readChecked(file)
                if entry.substitutePrefix == true {
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw BuildFailure("\(file) is not UTF-8 text; it cannot have its prefix substituted")
                    }
                    data = Data(layout.substitutingPlaceholders(in: text).utf8)
                }
                entries.append(.file(packagePath, contents: data, mode: mode(entry.mode, default: 0o644)))
            }
        }

        var loadCheck: BuildLoadCheck?
        if let filter = project.package.tweakFilter {
            guard let dylibPath = dylibLayoutPath else {
                throw BuildFailure("the tweak filter's dylib is not in the layout")
            }
            let directory = (dylibPath as NSString).deletingLastPathComponent
            let base = ((dylibPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let filterPath = directory + "/" + base + ".plist"
            var inner: [String: Any] = [:]
            if let bundles = filter.bundles {
                inner["Bundles"] = bundles
            }
            if let executables = filter.executables {
                inner["Executables"] = executables
            }
            if let classes = filter.classes {
                inner["Classes"] = classes
            }
            let plist = try PropertyListSerialization.data(
                fromPropertyList: ["Filter": inner],
                format: .xml,
                options: 0,
            )
            try entries.append(.file(layout.packagePath(for: filterPath), contents: plist, mode: 0o644))
            let root = inputs.installRoot == "/" ? "" : inputs.installRoot
            loadCheck = BuildLoadCheck(
                buildID: inputs.buildID,
                marker: BuildLoadCheck.marker(buildID: inputs.buildID),
                markerSubsystem: project.package.id,
                dylibLogicalPath: dylibPath,
                dylibInstalledPath: root + dylibPath,
                filterPlistLogicalPath: filterPath,
                filterPlistInstalledPath: root + filterPath,
                bundles: filter.bundles ?? [],
                executables: filter.executables ?? [],
                classes: filter.classes ?? [],
            )
        }
        writer.entries = entries

        for (name, path) in project.package.maintainerScripts?.all ?? [] {
            guard let script = MaintainerScript(rawValue: name) else { continue }
            guard let text = try String(data: inputs.readChecked(path), encoding: .utf8) else {
                throw BuildFailure("\(path) is not UTF-8 text")
            }
            let substituted = layout.substitutingPlaceholders(in: text)
            try checkShellSyntax(substituted, name: path)
            writer.maintainerScripts[script] = Data(substituted.utf8)
        }

        let destination = inputs.workDirectory
            .appendingPathComponent("\(project.package.id)_\(project.package.version)_\(layout.architecture).deb")
            .path
        try writer.write(toPath: destination)
        let data = try Data(contentsOf: URL(fileURLWithPath: destination))
        return Output(
            path: destination,
            digest: CanonicalJSON.sha256Tag(data),
            byteCount: Int64(data.count),
            loadCheck: loadCheck,
        )
    }

    private func mode(_ text: String?, default fallback: UInt16) -> UInt16 {
        text.flatMap { UInt16($0, radix: 8) } ?? fallback
    }

    private func checkShellSyntax(_ text: String, name: String) throws {
        guard let shell else { throw BuildFailure("cannot check the syntax of \(name): no sh was found") }
        let scratch = inputs.workDirectory.appendingPathComponent("tmp/\(UUID().uuidString).sh")
        try Data(text.utf8).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try ToolRunner.run(
            ToolInvocation(
                executable: shell,
                arguments: ["-n", scratch.path],
                workingDirectory: inputs.workDirectory.path,
                environment: ["PATH": "/usr/bin:/bin"],
            ),
            cancellation: BuildCancellation(),
        )
        guard result.succeeded else {
            throw BuildFailure(
                "\(name) does not parse: \(result.output.replacingOccurrences(of: scratch.path, with: name))",
                diagnostics: [
                    ProjectDiagnostic(
                        code: "package.script.syntax",
                        severity: .error,
                        message: result.output.replacingOccurrences(of: scratch.path, with: name),
                        file: name,
                    ),
                ],
            )
        }
    }
}
