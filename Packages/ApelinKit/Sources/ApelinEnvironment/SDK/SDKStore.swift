import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// The registered SDKs: each tree at `SDKs/<CanonicalName>-<sha8>/` and its
/// record at `SDKs/.registry/<id>.json`. Registering moves a checked staging
/// tree into place with one `rename` and then renames its record in — the
/// record is the commit point, so a tree without one is an interrupted
/// import and is never listed, and a record whose tree is gone is dropped.
public struct SDKStore: Sendable {
    public let layout: EnvironmentLayout

    public init(layout: EnvironmentLayout) {
        self.layout = layout
    }

    public func list() -> [SDKRecord] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: layout.sdkRegistry.path) else {
            return []
        }
        return names.sorted().compactMap { name -> SDKRecord? in
            guard name.hasSuffix(".json"), !name.hasPrefix("."),
                  let record = try? JSONFile.read(SDKRecord.self, at: layout.sdkRegistry.appendingPathComponent(name)) ?? nil,
                  record.id + ".json" == name
            else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: tree(record.id).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            var current = record
            current.path = BootstrapRootPath.rebased(record.path, onto: layout.sdks.path)
            return current
        }
    }

    public func record(_ id: String) -> SDKRecord? {
        list().first { $0.id == id }
    }

    func tree(_ id: String) -> URL {
        layout.sdks.appendingPathComponent(id, isDirectory: true)
    }

    /// Moves the inspected tree at `root` (inside this task's staging) into
    /// place and records it. An SDK with the same ID — the same name and
    /// content — is already registered: that record is answered and the
    /// staging copy left for the caller to remove.
    public func register(root: URL, inspection: SDKInspection, origin: String) throws -> SDKRecord {
        let identity = inspection.identity
        let id = identity.canonicalName + "-" + inspection.digest.prefix(8)
        guard SDKInspector.isPlainName(identity.canonicalName), ProjectName.validate(id) == nil else {
            throw ApelinError(.badRequest, "\(id) cannot name a folder")
        }
        if let existing = record(id) {
            return existing
        }

        try layout.make(layout.sdkRegistry)
        let destination = tree(id)
        var metadata = stat()
        if lstat(destination.path, &metadata) == 0 {
            // A tree with no record: an import that stopped between the two
            // renames. Its content is unverified; replace it.
            try FileManager.default.removeItem(at: destination)
        }
        guard rename(root.path, destination.path) == 0 else {
            throw ApelinError(.internal, "cannot move the SDK into place: \(String(cString: strerror(errno)))")
        }
        let record = SDKRecord(
            id: id,
            canonicalName: identity.canonicalName,
            version: identity.version,
            path: destination.path,
            targets: identity.targets,
            warnings: inspection.warnings,
            digest: inspection.digest,
            swiftCompilerVersion: identity.swiftCompilerVersion,
            origin: origin,
        )
        let pending = layout.sdkRegistry.appendingPathComponent(".\(id).json.pending")
        try JSONFile.write(record, to: pending)
        guard rename(pending.path, layout.sdkRegistry.appendingPathComponent(id + ".json").path) == 0 else {
            throw ApelinError(.internal, "cannot record the SDK: \(String(cString: strerror(errno)))")
        }
        return record
    }

    /// Unregisters and deletes an SDK no project binds.
    public func remove(_ id: String, projects: ProjectLocator) throws {
        guard ProjectName.validate(id) == nil, let record = record(id) else {
            throw ApelinError(.notFound, "no SDK \(id.debugDescription)")
        }
        let users = projects.projects(usingSDK: record.id)
        guard users.isEmpty else {
            throw ApelinError(
                .conflict,
                "\(record.id) is used by \(users.joined(separator: ", ")); move them to another SDK first",
            )
        }
        // Record first: from here on the SDK is not registered, whatever
        // happens to the tree.
        try FileManager.default.removeItem(at: layout.sdkRegistry.appendingPathComponent(id + ".json"))
        try layout.make(layout.staging)
        let doomed = layout.staging.appendingPathComponent("removed-\(id)-\(UUID().uuidString)", isDirectory: true)
        if rename(tree(id).path, doomed.path) == 0 {
            try? FileManager.default.removeItem(at: doomed)
        } else {
            try? FileManager.default.removeItem(at: tree(id))
        }
    }

    /// Trees left by an import that stopped before its record: removed.
    /// A tree is an orphan only when no file in the registry names it —
    /// readable or not: a record this version cannot read still holds its
    /// SDK, which is a large download. When the registry cannot be listed
    /// (it is there but does not read) nothing is swept.
    public func sweepOrphans() {
        let registry = layout.sdkRegistry.path
        let recordNames: [String]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: registry) {
            recordNames = names
        } else if FileManager.default.fileExists(atPath: registry) {
            return
        } else {
            recordNames = []
        }
        let registered = Set(recordNames.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.map { String($0.dropLast(5)) })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: layout.sdks.path) else { return }
        for name in names where !name.hasPrefix(".") && !registered.contains(name) {
            try? FileManager.default.removeItem(at: layout.sdks.appendingPathComponent(name))
        }
    }
}
