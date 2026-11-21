import Foundation

/// `InstallService` over the vendored IrisinExternalClient: irisind's Mach
/// service, as a client admitted by its entitlement (`wiki.qaq.irisin.client`
/// on apelind) and its root-owned executable inside the bootstrap.
final class IrisinInstallService: InstallService, @unchecked Sendable {
    private let client = IrisinExternalClient()

    /// Cancelling the connection answers every reply still pending with an
    /// error; the next call makes a new one.
    @objc dynamic func reset() {
        client.invalidate()
    }

    func serviceInfo() async throws -> InstallServiceInfo {
        let info = try await map { try await self.client.serviceInfo() }
        return InstallServiceInfo(
            externalVersion: info.externalVersion,
            capabilities: info.capabilities,
            installRoot: info.installRoot,
        )
    }

    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus {
        try await Self.status(map {
            try await self.client.submitInstall(transaction: transaction, packageDescriptor: descriptor, sha256: sha256)
        })
    }

    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus {
        try await Self.status(map {
            try await self.client.removePackage(transaction: transaction, packageIdentity: packageID)
        })
    }

    func respring(transaction: UUID) async throws -> InstallTransactionStatus {
        try await Self.status(map { try await self.client.respring(transaction: transaction) })
    }

    func status(of transaction: UUID) async throws -> InstallTransactionStatus {
        try await Self.status(map { try await self.client.status(of: transaction) })
    }

    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent]) {
        let batch = try await map { try await self.client.events(of: transaction, after: after) }
        return (Self.status(batch.status), batch.events.map {
            InstallTransactionEvent(
                sequence: $0.sequence,
                kind: $0.kind,
                text: $0.text,
                phase: $0.phase,
                step: $0.step,
                packageID: $0.packageIdentity,
                version: $0.packageVersion,
                completed: $0.completed,
                total: $0.total,
                exitStatus: $0.exitStatus,
                problem: $0.problem,
            )
        })
    }

    private static func status(_ status: IrisinTransactionStatus) -> InstallTransactionStatus {
        InstallTransactionStatus(
            transaction: status.transaction,
            kind: status.kind,
            state: InstallTransactionState(rawValue: status.state.rawValue) ?? .failed,
            nextSequence: status.nextSequence,
            exitStatus: status.exitStatus,
            packageID: status.packageIdentity,
            version: status.packageVersion,
            failure: status.failure,
            failureText: status.failureText,
            duplicate: status.duplicate,
        )
    }

    private func map<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as IrisinClientError {
            switch error.code {
            case .serviceUnavailable:
                throw InstallServiceError(.unavailable, "Irisin's service is not running, or it did not allow Apelin to connect. Try again.")
            case .connectionInterrupted:
                throw InstallServiceError(.interrupted, "The connection to Irisin was lost. Try again.")
            case .serviceTooOld:
                throw InstallServiceError(
                    .tooOld,
                    "Installing requires Irisin \(InstallServiceRequirement.minimumIrisin) or later. Update Irisin, then try again.",
                )
            case .notFound: throw InstallServiceError(.notFound, "Irisin could not find this request. Try again.")
            case .conflict:
                throw InstallServiceError(.conflict, "Irisin is already handling a conflicting request. Try again.")
            default:
                NSLog("apelind-session: irisind refused the call: %@", error.description)
                throw InstallServiceError(.refused, "Irisin could not complete this request. Try again.")
            }
        }
    }
}
