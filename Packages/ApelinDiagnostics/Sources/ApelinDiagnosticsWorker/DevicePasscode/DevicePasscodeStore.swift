import ApelinProtocol
import Foundation
import Security

/// The saved passcode, and how far its last use got.
struct SavedPasscode: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// Its test passed, and no attempt with it is under way: usable.
        case verified
        /// Written before each attempt and taken back after one that
        /// unlocked or was not made. Found on a read, it means an attempt
        /// whose end nobody saw (a crash, a kill): the passcode is dropped,
        /// as if that attempt had failed.
        case attempting
    }

    var passcode: String
    var stage: Stage
}

/// Where apelin-diagnostics keeps the device passcode. A read or a write
/// that fails throws `ApelinError` (`unavailable`), and nothing is tried
/// with a passcode whose stage could not be written first.
protocol DevicePasscodeStore: Sendable {
    func read() throws -> SavedPasscode?
    func write(_ saved: SavedPasscode) throws
    /// None saved is no error.
    func remove() throws
}

/// The keychain: one generic-password item, service and access group
/// `wiki.qaq.apelin.device-passcode`, which only apelin-diagnostics carries
/// (Packaging/Workers/apelin-diagnostics.entitlements), account `device`,
/// data the JSON `{"passcode", "stage"}`. Readable after the first unlock,
/// so an unlock reads it while the device is locked; this device only,
/// never synchronised.
struct KeychainDevicePasscodeStore: DevicePasscodeStore {
    static let service = "wiki.qaq.apelin.device-passcode"
    static let accessGroup = "wiki.qaq.apelin.device-passcode"
    static let account = "device"

    func read() throws -> SavedPasscode? {
        var query = Self.query()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw Self.failure(status) }
        // persisted-read: an item that does not decode is no usable passcode; the caller removes it
        return try? JSONDecoder().decode(SavedPasscode.self, from: data)
    }

    func write(_ saved: SavedPasscode) throws {
        let data = try JSONEncoder().encode(saved)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(Self.query() as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return
        }
        guard status == errSecItemNotFound else { throw Self.failure(status) }
        var add = Self.query()
        add.merge(update) { _, new in new }
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.failure(added) }
    }

    func remove() throws {
        let status = SecItemDelete(Self.query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    /// Names the service, the group and the account, and refuses
    /// synchronised items; on macOS it asks for the data-protection
    /// keychain, so the iOS semantics hold there too.
    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func failure(_ status: OSStatus) -> ApelinError {
        ApelinError(.unavailable, "Unable to access the keychain (error \(status)). Try again.")
    }
}
