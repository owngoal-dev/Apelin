import ApelinCore
import ApelinProtocol
import Foundation

/// One package the install bridge put on the device, from the moment it chose
/// the transaction ID to the removal. Written before the package is handed to
/// irisind, so a host that stops mid-install finds the transaction again;
/// `removePackage` resolves the package ID from here, never from the request.
struct InstallationRecord: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable {
        /// A build's artifact, recorded from the build worker.
        case build
        /// A `.deb` the user picked inside the data folder (app only).
        case file
        /// apelin-environment's local toolchain package, `toolchain-<id>`.
        case environment
    }

    enum Status: String, Codable, Sendable {
        /// Copied to staging and checked; not handed over yet.
        case staged
        /// Handed to irisind under `transactionID`.
        case submitted
        case installed
        case failed
        /// Handed to irisind for removal under `removalTransactionID`.
        case removing
        case removed
    }

    /// irisind's answer once the transaction ended: what makes this record
    /// the proof of ownership.
    struct Receipt: Codable, Equatable, Sendable {
        var state: String
        var exitStatus: Int64?
        var packageID: String?
        var version: String?
        var failure: String?
        var failureText: String?
        var finishedAt: Date
        /// True when irisind did not call it a success and the package
        /// database showed the package installed all the same (#45).
        var confirmed: Bool?

        /// The install went through: irisind said so, or the database did.
        var isInstalled: Bool {
            state == "succeeded" || confirmed == true
        }
    }

    var installationID: String
    var origin: Origin
    var artifactID: String
    /// Lowercase hex SHA-256 of the staged copy.
    var artifactDigest: String
    var projectID: String?
    var buildID: String?
    var packageID: String
    var version: String
    var packagingDigest: String?
    /// Lowercase UUID.
    var transactionID: String
    var taskID: String?
    var status: Status
    var createdAt: Date
    var updatedAt: Date
    /// The last irisind event the host relayed into the task.
    var followedSeq: UInt64
    var receipt: Receipt?
    var removalTransactionID: String?
    var removalTaskID: String?
    var removalReceipt: Receipt?
}

/// `<state>/installations/<installationID>.json`, root's and 0700.
actor InstallationStore {
    private let directory: URL
    private var records: [String: InstallationRecord] = [:]
    private var loaded = false

    init(directory: URL) {
        self.directory = directory
    }

    func record(_ id: String) -> InstallationRecord? {
        loadIfNeeded()
        return records[id]
    }

    func all() -> [InstallationRecord] {
        loadIfNeeded()
        return records.values.sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ record: InstallationRecord) throws {
        loadIfNeeded()
        guard Self.validID(record.installationID) else { throw ApelinError(.internal, "bad installation ID") }
        var record = record
        record.updatedAt = Date()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        try JSONCoding.encode(record).write(
            to: directory.appendingPathComponent(record.installationID + ".json"),
            options: .atomic,
        )
        records[record.installationID] = record
    }

    @discardableResult
    func update(_ id: String, _ change: (inout InstallationRecord) -> Void) throws -> InstallationRecord {
        guard var record = record(id) else { throw ApelinError(.notFound, "no installation \(id)") }
        change(&record)
        try save(record)
        return record
    }

    /// Installation IDs are lowercase UUIDs the host made.
    static func validID(_ id: String) -> Bool {
        id.count == 36 && UUID(uuidString: id) != nil && id == id.lowercased()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONCoding.decode(InstallationRecord.self, from: data),
                  record.installationID + ".json" == file.lastPathComponent else { continue }
            records[record.installationID] = record
        }
    }
}
