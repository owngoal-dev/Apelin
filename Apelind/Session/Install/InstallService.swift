import Foundation

/// The install service as the bridge sees it: irisind's external operations
/// (Irisin's Documentation/ExternalClients.md). `IrisinInstallService` is the
/// real one, over the vendored IrisinExternalClient; the harness drives the
/// bridge with a fake.
protocol InstallService: Sendable {
    func serviceInfo() async throws -> InstallServiceInfo
    /// `sha256` is 64 lowercase hex digits. The descriptor stays the caller's.
    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus
    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus
    func respring(transaction: UUID) async throws -> InstallTransactionStatus
    func status(of transaction: UUID) async throws -> InstallTransactionStatus
    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent])
    /// Gives up the calls still waiting for an answer: each fails, and the
    /// next call connects afresh.
    func reset()
}

extension InstallService {
    func reset() {}
}

struct InstallServiceInfo: Equatable, Sendable {
    var externalVersion: UInt64
    var capabilities: Set<String>
    var installRoot: String
}

enum InstallTransactionState: String, Codable, Sendable {
    case running, succeeded, failed, interrupted

    var isFinished: Bool {
        self != .running
    }
}

struct InstallTransactionStatus: Equatable, Sendable {
    var transaction: UUID
    var kind: String
    var state: InstallTransactionState
    var nextSequence: UInt64
    var exitStatus: Int64?
    var packageID: String?
    var version: String?
    var failure: String?
    var failureText: String?
    var duplicate: Bool
}

struct InstallTransactionEvent: Equatable, Sendable {
    var sequence: UInt64
    var kind: String
    var text: String
    var phase: String?
    var step: String?
    var packageID: String?
    var version: String?
    var completed: Int64?
    var total: Int64?
    var exitStatus: Int64?
    var problem: String?
}

struct InstallServiceError: Error, Equatable, CustomStringConvertible {
    enum Code: Equatable, Sendable {
        /// Not installed, not started yet, or refused this program.
        case unavailable
        /// The connection dropped; ask again.
        case interrupted
        /// The handshake was sent and nothing came back within the bridge's
        /// limit: a job launchd holds whose program never answers.
        case noAnswer
        /// An Irisin before 4.7: no external operations.
        case tooOld
        case notFound
        /// The transaction ID is taken by a different request.
        case conflict
        case refused
    }

    var code: Code
    var message: String

    init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }

    var isTransient: Bool {
        code == .unavailable || code == .interrupted
    }

    var description: String {
        message.isEmpty ? "\(code)" : "\(code): \(message)"
    }
}

/// What the bridge needs of the installed service.
enum InstallServiceRequirement {
    static let minimumIrisin = "4.7.3"
    static let capabilities: Set<String> = [
        "submitInstall",
        "transactionStatus",
        "transactionEvents",
        "removePackage",
        "respring",
    ]

    /// Irisin's package, as the package database names it.
    static let irisinPackage = "wiki.qaq.irisin"
    /// irisind and its launchd job, relative to the install root, where
    /// Irisin's package puts them (Irisin's `IrisinWire.daemonPath`).
    static let daemonFiles = [
        "/usr/libexec/irisind",
        "/Library/LaunchDaemons/wiki.qaq.irisind.plist",
    ]
    /// What irisind requires a client to carry, each strictly `true`
    /// (Irisin's `IrisinWire.requiredClientEntitlements`).
    static let clientEntitlements = [
        "wiki.qaq.irisin.client",
        "platform-application",
        "com.apple.private.security.no-sandbox",
    ]

    /// Whether a package version is `minimumIrisin` or later: true or false
    /// for a version of digits and dots (an epoch above 0 is later, a
    /// revision does not count), nil for any other spelling, which is not
    /// judged.
    static func meetsMinimum(_ version: String) -> Bool? {
        var upstream = Substring(version.trimmingCharacters(in: .whitespaces))
        if let colon = upstream.firstIndex(of: ":") {
            guard let epoch = Int(upstream[..<colon]) else { return nil }
            if epoch > 0 {
                return true
            }
            upstream = upstream[upstream.index(after: colon)...]
        }
        if let dash = upstream.lastIndex(of: "-") {
            upstream = upstream[..<dash]
        }
        func numbers(_ text: Substring) -> [Int]? {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var result: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.utf8.allSatisfy({ (48 ... 57).contains($0) }), let value = Int(part) else {
                    return nil
                }
                result.append(value)
            }
            return result
        }
        guard let installed = numbers(upstream), let minimum = numbers(Substring(minimumIrisin)) else { return nil }
        for index in 0 ..< max(installed.count, minimum.count) {
            let a = index < installed.count ? installed[index] : 0
            let b = index < minimum.count ? minimum[index] : 0
            if a != b {
                return a > b
            }
        }
        return true
    }
}
