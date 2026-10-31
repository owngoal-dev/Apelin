import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinProject
import ApelinProtocol
import Foundation

/// A workspace's build (`ExternalBuildDeclaration`, owner 2026-10-23): its
/// own script, run as mobile in the project with the development
/// environment shell_run and the terminal get, then the one `.deb` it wrote
/// into `APELIN_PACKAGE_DIR` checked and registered as the build's artifact,
/// as `BuildService` registers its own. Apelin neither compiles, signs nor
/// packages here: the script does all of it, and the package is judged by
/// what it holds.
///
/// The script gets, beside the toolchain first on `PATH`, `SDKROOT` and
/// `IPHONEOS_DEPLOYMENT_TARGET`: `APELIN_BUILD_ID` (the marker
/// `apelin_package_confirm_loaded` matches, `ApelinLoaded <id>` under the package ID's
/// subsystem), `APELIN_BOOTSTRAP` and `APELIN_ARCHITECTURE` (the package's
/// `Architecture`), `APELIN_PREFIX` (what `@PREFIX@` is: `/var/jb` rootless,
/// empty roothide), `APELIN_CONFIGURATION` (`debug` or `release`),
/// `APELIN_PROJECT_ROOT` and `APELIN_PACKAGE_DIR`, a fresh folder in
/// `Builds/<projectID>/<buildID>/`, outside the project, so no package
/// already in the repository is taken for the build's.
///
/// A release build also reports, as `distribution.*` warnings, what the
/// package carries that one for other people should not
/// (`DistributionCheck.packageFindings`): a workspace has no description
/// for `projectCheck` to read before.
public enum ExternalBuild {
    public struct Inputs: Sendable {
        public var buildID: String
        public var projectID: String
        public var projectRoot: URL
        public var declaration: ExternalBuildDeclaration
        public var configuration: ConfigurationName
        public var bootstrap: Bootstrap
        /// `Builds/<projectID>/<buildID>/`.
        public var workDirectory: URL
        public var installRoot: String
        public var home: String
        public var timestamp: Int64
        /// The script is stopped past this, as a cancel stops it.
        public var timeout: TimeInterval

        public init(
            buildID: String,
            projectID: String,
            projectRoot: URL,
            declaration: ExternalBuildDeclaration,
            configuration: ConfigurationName,
            bootstrap: Bootstrap,
            workDirectory: URL,
            installRoot: String,
            home: String,
            timestamp: Int64 = Int64(Date().timeIntervalSince1970),
            timeout: TimeInterval = ExternalBuild.defaultTimeout,
        ) {
            self.buildID = buildID
            self.projectID = projectID
            self.projectRoot = projectRoot
            self.declaration = declaration
            self.configuration = configuration
            self.bootstrap = bootstrap
            self.workDirectory = workDirectory
            self.installRoot = installRoot
            self.home = home
            self.timestamp = timestamp
            self.timeout = timeout
        }

        var layout: PackageLayout {
            PackageLayout(flavor: bootstrap == .rootless ? .rootless : .roothide)
        }
    }

    public static let defaultTimeout: TimeInterval = 30 * 60
    /// A filter plist is read from the package up to this size.
    static let filterPlistLimit: Int64 = 64 * 1024

    public static func run(
        inputs: Inputs,
        store: ProjectStore,
        reporter: BuildReporter,
        cancellation: BuildCancellation,
    ) throws -> ArtifactRecord {
        let work = inputs.workDirectory
        let packages = work.appendingPathComponent("package", isDirectory: true)
        let temporary = work.appendingPathComponent("tmp", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let logURL = work.appendingPathComponent("build.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        defer { try? logHandle?.close() }
        let log = { (line: String) in
            reporter.log(line)
            logHandle?.write(Data((line + "\n").utf8))
        }

        if let line = ManifestFormatting.run(projectRoot: inputs.projectRoot) {
            log(line)
        }
        reporter.stage("script", product: nil)
        let result = try runScript(inputs, packages: packages, temporary: temporary, cancellation: cancellation, log: log)
        let diagnostics = ToolDiagnostics.parse(result.output, tool: "script", projectRoot: inputs.projectRoot.path)
        diagnostics.forEach(reporter.diagnostic)
        guard result.succeeded else {
            throw BuildFailure("\(inputs.declaration.script) failed with status \(result.status)", diagnostics: diagnostics)
        }

        reporter.stage("verify", product: nil)
        let deb = try onePackage(in: packages)
        let contents: DebArchiveReader.Contents
        let control: DebianControlFile
        do {
            contents = try DebArchiveReader.contents(of: .path(deb.path), contentsLimit: filterPlistLimit)
            control = try contents.control()
        } catch {
            throw BuildFailure("\(deb.lastPathComponent) is not a package Apelin can read: \(error)")
        }
        let expected = inputs.layout.architecture
        guard let packageID = control.package, let version = control.version else {
            throw BuildFailure("\(deb.lastPathComponent) names no Package or Version in its control file")
        }
        guard control.architecture == expected else {
            throw BuildFailure(
                "\(deb.lastPathComponent) is for \(control.architecture ?? "no architecture"), not \(expected), the \(inputs.bootstrap.rawValue) package architecture (APELIN_ARCHITECTURE)",
            )
        }
        let bytes = try Data(contentsOf: deb)
        if cancellation.isCancelled {
            throw BuildCancelled()
        }
        let record = ArtifactRecord(
            version: ArtifactRecord.version,
            artifactID: inputs.buildID,
            buildID: inputs.buildID,
            projectID: inputs.projectID,
            configuration: inputs.configuration.rawValue,
            bootstrap: inputs.bootstrap.rawValue,
            path: deb.path,
            digest: CanonicalJSON.sha256Tag(bytes),
            byteCount: Int64(bytes.count),
            packageID: packageID,
            packageVersion: version,
            architecture: expected,
            buildDigest: nil,
            packagingDigest: packagingDigest(control: control, contents: contents),
            buildSystem: .external,
            toolchain: nil,
            sdk: nil,
            template: nil,
            products: [],
            dsyms: [],
            log: logURL.path,
            loadCheck: loadCheck(contents, packageID: packageID, inputs: inputs),
            createdAt: Date(timeIntervalSince1970: TimeInterval(inputs.timestamp)),
            packageFiles: ArtifactRecord.packageFiles(of: contents),
        )
        log("packaged \(packageID) \(version) (\(expected)), \(record.digest)")
        if inputs.configuration == .release {
            DistributionCheck.packageFindings(record, store: store).forEach(reporter.diagnostic)
        }
        try ArtifactStore(store: store).save(record)
        return record
    }

    /// The script, by the bootstrap's interpreter, stopped at the timeout as
    /// a cancel stops it.
    private static func runScript(
        _ inputs: Inputs,
        packages: URL,
        temporary: URL,
        cancellation: BuildCancellation,
        log: @escaping (String) -> Void,
    ) throws -> ToolResult {
        let declaration = inputs.declaration
        let base = inputs.installRoot == "/" ? "" : inputs.installRoot
        let interpreter = declaration.interpreter.rawValue
        let candidates: [String] = ["\(base)/usr/bin/\(interpreter)", "\(base)/bin/\(interpreter)"]
        guard let executable = candidates.first(where: { access($0, X_OK) == 0 }) else {
            throw BuildFailure("there is no \(interpreter) in the bootstrap to run \(declaration.script)")
        }
        let root = CanonicalPath.resolve(inputs.projectRoot.path) ?? inputs.projectRoot.path
        let invocation = ToolInvocation(
            executable: executable,
            arguments: [declaration.script] + declaration.arguments,
            workingDirectory: root,
            environment: environment(inputs, projectRoot: root, packages: packages, temporary: temporary),
        )
        log("$ " + invocation.displayLine)
        let limit: String = inputs.timeout >= 120 ? "\(Int(inputs.timeout / 60)) minutes" : "\(Int(inputs.timeout)) seconds"
        let overtime = BuildFailure("\(declaration.script) ran past \(limit) and was stopped")
        let timer = Timeout()
        let deadline = DispatchWorkItem {
            timer.fire()
            cancellation.cancel()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + inputs.timeout, execute: deadline)
        defer { deadline.cancel() }
        do {
            let result = try ToolRunner.run(invocation, cancellation: cancellation, onLine: log)
            if timer.fired {
                throw overtime
            }
            if cancellation.isCancelled {
                throw BuildCancelled()
            }
            return result
        } catch is BuildCancelled where timer.fired {
            throw overtime
        }
    }

    static func environment(_ inputs: Inputs, projectRoot: String, packages: URL, temporary: URL) -> [String: String] {
        let development = DevelopmentEnvironment.prepared(home: inputs.home, projectDirectory: projectRoot)
        var variables = development.variables(basePath: DevelopmentEnvironment.searchPath(installRoot: inputs.installRoot))
        variables["HOME"] = inputs.home
        variables["TMPDIR"] = temporary.path + "/"
        variables["LANG"] = "en_US.UTF-8"
        variables["TERM"] = "dumb"
        variables["APELIN_BUILD_ID"] = inputs.buildID
        variables["APELIN_BOOTSTRAP"] = inputs.bootstrap.rawValue
        variables["APELIN_ARCHITECTURE"] = inputs.layout.architecture
        variables["APELIN_PREFIX"] = inputs.layout.installPrefix
        variables["APELIN_CONFIGURATION"] = inputs.configuration == .debug ? "debug" : "release"
        variables["APELIN_PROJECT_ROOT"] = projectRoot
        variables["APELIN_PACKAGE_DIR"] = packages.path
        return variables
    }

    /// The one regular `.deb` the script left in the package folder.
    private static func onePackage(in folder: URL) throws -> URL {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let debs = names.filter { $0.hasSuffix(".deb") }.sorted()
        guard debs.count == 1 else {
            throw BuildFailure(
                debs.isEmpty
                    ? "the build script wrote no package: write one .deb into APELIN_PACKAGE_DIR"
                    : "the build script wrote \(debs.count) packages into APELIN_PACKAGE_DIR (\(debs.joined(separator: ", "))): write exactly one",
            )
        }
        let url = folder.appendingPathComponent(debs[0])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BuildFailure("\(debs[0]) in APELIN_PACKAGE_DIR is not a regular file")
        }
        return url
    }

    /// What an install of this package is approved by: the control file but
    /// its `Version`, every maintainer script and other control member, and
    /// where each data member goes, with its kind and mode — not the bytes a
    /// rebuild changes. A version bump never asks; a new script, field or
    /// path does.
    static func packagingDigest(control: DebianControlFile, contents: DebArchiveReader.Contents) -> String {
        let fields: [JSONDocument] = control.fields
            .filter { $0.name.caseInsensitiveCompare("Version") != .orderedSame }
            .map { field -> JSONDocument in .array([.string(field.name), .string(field.value)]) }
        let members: [(key: String, value: JSONDocument)] = contents.controlFiles
            .filter { $0.key != "control" }
            .sorted { $0.key < $1.key }
            .map { member -> (key: String, value: JSONDocument) in
                (key: member.key, value: .string(CanonicalJSON.sha256Tag(member.value)))
            }
        let files: [JSONDocument] = contents.entries.map { entry -> JSONDocument in
            .array([.string(entry.path), .string(kindName(entry.kind)), .integer(Int64(entry.mode))])
        }
        let description: [(key: String, value: JSONDocument)] = [
            (key: "description", value: .string("apelin.external-packaging")),
            (key: "version", value: .integer(1)),
            (key: "control", value: .array(fields)),
            (key: "members", value: .object(JSONObject(members))),
            (key: "files", value: .array(files)),
        ]
        return CanonicalJSON.digest(.object(JSONObject(description)))
    }

    private static func kindName(_ kind: DebArchiveReader.EntryKind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "directory"
        case let .symbolicLink(target): "link " + target
        case let .hardLink(target): "hardlink " + target
        case let .other(type): "other \(type)"
        }
    }

    /// What `apelin_package_confirm_loaded` checks, when the package installs exactly one
    /// tweak: a dylib in MobileSubstrate's folder with its filter plist
    /// beside it. The marker is the template's, under the package ID.
    static func loadCheck(_ contents: DebArchiveReader.Contents, packageID: String, inputs: Inputs) -> BuildLoadCheck? {
        let folder = inputs.layout.installPrefix + "/Library/MobileSubstrate/DynamicLibraries/"
        let dylibs: [DebArchiveReader.Entry] = contents.entries.filter { entry in
            entry.kind == .file && entry.path.hasPrefix(folder) && entry.path.hasSuffix(".dylib")
        }
        guard dylibs.count == 1 else { return nil }
        let dylib = dylibs[0].path
        let plistPath = String(dylib.dropLast(".dylib".count)) + ".plist"
        guard let plist = contents.entries.first(where: { $0.path == plistPath })?.contents,
              let filter = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let rules = filter["Filter"] as? [String: Any]
        else { return nil }
        let prefixLength = inputs.layout.installPrefix.count
        let root: String = inputs.installRoot == "/" ? "" : inputs.installRoot
        let logical = { (path: String) -> String in String(path.dropFirst(prefixLength)) }
        let installed = { (path: String) -> String in root + logical(path) }
        return BuildLoadCheck(
            buildID: inputs.buildID,
            marker: BuildLoadCheck.marker(buildID: inputs.buildID),
            markerSubsystem: packageID,
            dylibLogicalPath: logical(dylib),
            dylibInstalledPath: installed(dylib),
            filterPlistLogicalPath: logical(plistPath),
            filterPlistInstalledPath: installed(plistPath),
            bundles: rules["Bundles"] as? [String] ?? [],
            executables: rules["Executables"] as? [String] ?? [],
            classes: rules["Classes"] as? [String] ?? [],
        )
    }
}

/// Whether the timeout stopped the script, set from the timer's queue.
private final class Timeout: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var fired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func fire() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
