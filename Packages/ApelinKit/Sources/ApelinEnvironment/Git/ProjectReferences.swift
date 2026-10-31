import ApelinCore
import Darwin
import Foundation

/// The project IDs something on this device names besides a project's own
/// folder: a conversation (its `sessions/<id>/session.json`, which a
/// reopened session must match), a build (`Builds/<id>/`) and a memory
/// record. A repository's `apelin-project.json` brings an ID of its own into
/// a new workspace; the workspace takes it only where neither that ID nor
/// the workspace's is named by any of them, so no conversation, build or
/// memory ends up belonging to a project it was not made for.
///
/// The host's approval ledger is root's and not read here: a new workspace
/// has nothing in it (`projectCreate` answers no description digests for
/// one), and a ledger left by a project deleted since names an ID its
/// builds or conversations named too, in practice.
struct ProjectReferences {
    private var ids: Set<String> = []
    /// Something that would name an ID could not be read: every ID counts
    /// as named.
    private var uncertain = false

    private static let maximumSessionBytes = 1 << 20

    init(data: DataFolder) {
        readSessions(data.sessions)
        readBuilds(data.root.appendingPathComponent("Builds", isDirectory: true))
        do {
            try ids.formUnion(MemoryStore(root: data.root).read().records.compactMap(\.projectID))
        } catch {
            uncertain = true
        }
    }

    func names(_ id: String) -> Bool {
        uncertain || ids.contains(id)
    }

    private mutating func readSessions(_ sessions: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) else { return }
        for entry in entries where !entry.hasPrefix(".") {
            let file = sessions.appendingPathComponent(entry, isDirectory: true).appendingPathComponent("session.json")
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0 else { continue }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= Self.maximumSessionBytes,
                  let data = FileManager.default.contents(atPath: file.path),
                  let session = try? JSONCoding.decode(JSONValue.self, from: data)
            else {
                uncertain = true
                continue
            }
            if let id = session["project"]?["id"]?.stringValue {
                ids.insert(id)
            }
        }
    }

    private mutating func readBuilds(_ builds: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: builds.path) else { return }
        ids.formUnion(entries)
    }
}
