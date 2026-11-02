import ApelinCore
import ApelinGit
import ApelinProtocol
import Foundation
import Security

/// Where the git service keeps its HTTPS credentials: one per host, keyed by
/// the host as `GitCredentialHost.key` spells it (lowercased, `:port` when
/// there is one). The host and user name may be listed; the token is read
/// only to hand it to libgit2.
public protocol GitCredentialStore: Sendable {
    /// Every saved host with its user name, sorted by host.
    func summaries() throws -> [GitCredentialSummary]
    func credential(forHost host: String) throws -> GitCredential?
    /// Saves, or replaces, the credential for `host`.
    func save(_ credential: GitCredential, forHost host: String) throws
    /// Removes the credential for `host`; one that is not there is no error.
    func remove(host: String) throws
}

/// The credentials in the keychain: generic-password items under service
/// `wiki.qaq.apelin.git` in access group `wiki.qaq.apelin.git`, which only
/// apelin-environment carries (Packaging/Workers/apelin-environment.entitlements),
/// account the host, data the JSON `{"username", "token"}`. Readable after
/// the first unlock, so a push runs with the screen locked; this device
/// only, never synchronised.
public struct KeychainGitCredentialStore: GitCredentialStore {
    public static let service = "wiki.qaq.apelin.git"
    public static let accessGroup = "wiki.qaq.apelin.git"

    public init() {}

    public func summaries() throws -> [GitCredentialSummary] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw Self.failure(status) }
        let hosts = items.compactMap { $0[kSecAttrAccount as String] as? String }
        // An item whose contents do not read leaves it out alone: the list,
        // and the whole Settings ▸ Git page with it, never fails for it. The
        // keychain itself failing (locked, say) is still the list's failure,
        // never read as "not signed in".
        return try hosts.sorted().compactMap { host in
            do {
                // persisted-read: caught per item below; only the keychain's own failure goes on
                return try credential(forHost: host).map { GitCredentialSummary(host: host, username: $0.username) }
            } catch let error as ApelinError where error.code != .unavailable {
                return nil
            }
        }
    }

    public func credential(forHost host: String) throws -> GitCredential? {
        var query = itemQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure(status) }
        guard let item = try? JSONDecoder().decode(Item.self, from: data) else {
            throw ApelinError(.internal, "The saved credential for \(host) could not be read. Save it again.")
        }
        return GitCredential(username: item.username, token: item.token)
    }

    public func save(_ credential: GitCredential, forHost host: String) throws {
        let data = try JSONEncoder().encode(Item(username: credential.username, token: credential.token))
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(itemQuery(host) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else { throw Self.failure(status) }
        var add = itemQuery(host)
        add.merge(update) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.failure(added) }
    }

    public func remove(host: String) throws {
        let status = SecItemDelete(itemQuery(host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    // MARK: Queries

    private struct Item: Codable {
        var username: String
        var token: String
    }

    /// Every query names the service and the group and refuses synchronised
    /// items; on macOS it asks for the data-protection keychain, so the iOS
    /// semantics hold there too.
    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func itemQuery(_ host: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = host
        return query
    }

    private static func failure(_ status: OSStatus) -> ApelinError {
        ApelinError(.unavailable, "Unable to access the keychain (error \(status)). Try again.")
    }
}

/// Credentials in memory, gone with the process: for tests and the harness.
public final class MemoryGitCredentialStore: GitCredentialStore, @unchecked Sendable {
    private let lock = PthreadLock()
    private var items: [String: GitCredential] = [:]

    public init() {}

    public func summaries() throws -> [GitCredentialSummary] {
        lock.withLock {
            items.keys.sorted().map { GitCredentialSummary(host: $0, username: items[$0]!.username) }
        }
    }

    public func credential(forHost host: String) throws -> GitCredential? {
        lock.withLock { items[host] }
    }

    public func save(_ credential: GitCredential, forHost host: String) throws {
        lock.withLock { items[host] = credential }
    }

    public func remove(host: String) throws {
        lock.withLock { items[host] = nil }
    }
}
