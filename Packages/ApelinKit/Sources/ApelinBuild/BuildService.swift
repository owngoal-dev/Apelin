import ApelinCore
import ApelinDebArchive
import ApelinDebian
import ApelinProject
import ApelinProtocol
import Foundation

/// One build from start to artifact: the project checked, the steps run,
/// the deb written and registered by ID and SHA-256. apelin-build's
/// `buildStart` is this, with its events turned into task events.
public enum BuildService {
    public struct Result: Sendable {
        public var record: ArtifactRecord
        public var products: BuildProducts
    }

    public static func build(
        inputs: BuildInputs,
        store: ProjectStore,
        reporter: BuildReporter,
        cancellation: BuildCancellation,
    ) throws -> Result {
        reporter.stage("check", product: nil)
        let check = ProjectCheck(
            store: store,
            catalog: inputs.catalog,
            registry: StaticEnvironmentRegistry(toolchains: [inputs.toolchain], sdks: [inputs.sdk]),
            installRoot: inputs.installRoot,
        )
        .run(root: inputs.projectRoot)
        for diagnostic in check.diagnostics where diagnostic.severity != .note {
            reporter.diagnostic(diagnostic)
        }
        guard check.passed, let digests = check.digests else {
            throw BuildFailure(
                "the project check failed",
                diagnostics: check.diagnostics.filter { $0.severity == .error },
            )
        }
        // The check read apelin-project.json again: the digests describe this
        // build only if that was the document the build was resolved from,
        // display name aside (no digest covers it).
        guard check.project.map(described) == described(inputs.project) else {
            throw BuildFailure("apelin-project.json changed while the build was starting; build again")
        }
        if let approved = inputs.approvedBuildDigest, approved != digests.build.digest {
            throw BuildFailure("the build description changed after it was approved; build again to review it")
        }
        var inputs = inputs
        // A file both descriptions name and the check read differently
        // matches nothing.
        inputs.checkedFiles = digests.build.files.merging(digests.packaging.files) { $0 == $1 ? $0 : "" }

        try? FileManager.default.removeItem(at: inputs.workDirectory)
        try FileManager.default.createDirectory(at: inputs.workDirectory, withIntermediateDirectories: true)
        let pipeline = BuildPipeline(inputs: inputs, reporter: reporter, cancellation: cancellation)
        let products = try pipeline.run()
        if cancellation.isCancelled {
            throw BuildCancelled()
        }

        reporter.stage("package", product: nil)
        let packager = Packager(inputs: inputs, products: products)
        let output = try packager.write()
        if cancellation.isCancelled {
            throw BuildCancelled()
        }
        reporter.stage("verify", product: nil)
        let contents = try DebArchiveReader.contents(of: .path(output.path))
        let control = try contents.control()
        guard control.package == inputs.project.package.id,
              control.version == inputs.project.package.version,
              control.architecture == packager.layout.architecture,
              try CanonicalJSON.sha256Tag(Data(contentsOf: URL(fileURLWithPath: output.path))) == output.digest
        else {
            throw BuildFailure("the packaged artifact does not match its build")
        }
        if cancellation.isCancelled {
            throw BuildCancelled()
        }
        let record = ArtifactRecord(
            version: ArtifactRecord.version,
            artifactID: inputs.buildID,
            buildID: inputs.buildID,
            projectID: inputs.project.projectID,
            configuration: inputs.configuration.rawValue,
            bootstrap: inputs.bootstrap.rawValue,
            path: output.path,
            digest: output.digest,
            byteCount: output.byteCount,
            packageID: inputs.project.package.id,
            packageVersion: inputs.project.package.version,
            architecture: packager.layout.architecture,
            buildDigest: digests.build.digest,
            packagingDigest: digests.packaging.digest,
            toolchain: inputs.project.environment.toolchain,
            sdk: inputs.project.environment.sdk,
            template: inputs.project.template,
            products: products.products,
            dsyms: products.dsyms,
            log: products.log,
            loadCheck: output.loadCheck,
            createdAt: Date(timeIntervalSince1970: TimeInterval(inputs.timestamp)),
            packageFiles: ArtifactRecord.packageFiles(of: contents),
        )
        try ArtifactStore(store: store).save(record)
        return Result(record: record, products: products)
    }

    private static func described(_ project: ProjectDocument) -> ProjectDocument {
        var project = project
        project.displayName = nil
        project.autoName = nil
        return project
    }
}
