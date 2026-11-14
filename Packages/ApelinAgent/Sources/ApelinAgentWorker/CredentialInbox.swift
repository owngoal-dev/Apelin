import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import KWWKAI

/// `~/Documents/wiki.qaq.apelin/console/inbox/credentials/`: where the
/// device's owner drops a provider credential so a session can sign in with
/// no UI. Each file is read once, stored in the keychain and deleted —
/// deleted even when it cannot be used, so a secret never lingers on disk.
/// Nothing a file holds is logged, answered or kept anywhere but the store.
///
/// A file is either `<store-id>.json` holding kwwk's credential shape
/// (`{"access", "refresh", "expires", …}`), or any `*.json` holding a kwwk
/// `auth.json` map of store id to that shape. Store ids are kwwk's, one per
/// provider Settings signs in to (`AgentProvider.storeID`): `github-copilot`,
/// `anthropic`, `anthropic-api-key`, `openai-compatible`, `openai-codex`,
/// `kimi-coding` and the rest.
public struct CredentialInbox: Sendable {
    public static let maximumFileBytes = 64 * 1024
    public static let knownProviders = Set(AgentProvider.allCases.map(\.storeID))

    /// A provider's store id, or a further OpenAI-compatible endpoint's.
    static func isKnown(_ storeID: String) -> Bool {
        knownProviders.contains(storeID) || CredentialProviderID.endpointNumber(storeID) != nil
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `<home>/Documents/wiki.qaq.apelin/console/inbox/credentials`.
    public init(home: String) {
        self.init(
            directory: ApelinCore.DataFolder(home: home).consoleInbox
                .appendingPathComponent("credentials", isDirectory: true),
        )
    }

    /// Imports every file in the inbox. A missing inbox is an empty one.
    public func importAll(into store: any CredentialSource) async -> AgentCredentialImportResponse {
        var stored: [String] = []
        var rejected: [String] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names {
            let path = directory.appendingPathComponent(name).path
            let contents: Data
            do {
                contents = try Self.readOnce(path)
            } catch {
                rejected.append("\(name): \(error)")
                continue
            }
            do {
                for (providerID, credentials) in try Self.parse(contents, fileName: name) {
                    try await store.store(credentials, for: providerID)
                    stored.append(providerID)
                }
            } catch let error as InboxError {
                rejected.append("\(name): \(error)")
            } catch {
                // A store error names a status, never the secret.
                rejected.append("\(name): the keychain refused it (\(error.localizedDescription))")
            }
        }
        let available = await store.providerIds()
        return AgentCredentialImportResponse(stored: stored, rejected: rejected, available: available)
    }

    enum InboxError: Error, CustomStringConvertible, Equatable {
        case notARegularFile
        case tooLarge
        case unreadable(Int32)
        case notCredentials
        case unknownProvider(String)

        var description: String {
            switch self {
            case .notARegularFile: "not a regular file (links are not followed); removed"
            case .tooLarge: "larger than 64 KiB; removed"
            case let .unreadable(code): "could not be read (\(String(cString: strerror(code))))"
            case .notCredentials: "not a kwwk credential or auth.json map; removed"
            case let .unknownProvider(id): "\(id) is not a provider Apelin offers; removed"
            }
        }
    }

    /// Opens without following a link, reads a bounded regular file and
    /// unlinks it, whatever it turned out to hold.
    static func readOnce(_ path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            // A link is removed without being read.
            if code == ELOOP {
                unlink(path); throw InboxError.notARegularFile
            }
            throw InboxError.unreadable(code)
        }
        defer { close(descriptor) }
        defer { unlink(path) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw InboxError.notARegularFile
        }
        guard metadata.st_size <= maximumFileBytes else { throw InboxError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while data.count <= maximumFileBytes {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR {
                continue
            }
            if count <= 0 {
                break
            }
            data.append(contentsOf: buffer[0 ..< count])
        }
        guard data.count <= maximumFileBytes else { throw InboxError.tooLarge }
        return data
    }

    /// One credential named by the file, or an auth.json map.
    static func parse(_ data: Data, fileName: String) throws -> [(String, OAuthCredentials)] {
        let decoder = JSONDecoder()
        let stem = (fileName as NSString).deletingPathExtension
        if isKnown(stem), let single = try? decoder.decode(OAuthCredentials.self, from: data) {
            return [(stem, single)]
        }
        guard let map = try? decoder.decode([String: OAuthCredentials].self, from: data), !map.isEmpty else {
            throw InboxError.notCredentials
        }
        for id in map.keys where !isKnown(id) {
            throw InboxError.unknownProvider(id)
        }
        return map.keys.sorted().map { ($0, map[$0]!) }
    }
}
