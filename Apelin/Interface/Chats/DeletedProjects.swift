import ApelinCore
import Foundation

/// A project whose folder has gone from `Projects/` takes its conversations
/// with it, as the app's own Delete takes them (`ChatRuntime.deleteProject`):
/// an agent deleted it with apelin_project_delete, after the host closed
/// its sessions, or a command or another app removed it. Nothing else
/// tells the app, so the folder is what it goes by.
///
/// Only a disappearance the app saw counts: a project listed in an earlier
/// reading of this same `Projects/` and missing from this one. A folder the
/// app has not read before has seen nothing, so it takes nothing — the
/// wrong data folder (0.3.5 on rootless read its data container's, where
/// `Projects/` was empty, and took every project's conversations at each
/// launch, #37), a `Projects/` made again empty after it went, or the first
/// reading after an upgrade. What was seen is kept in the same data folder.
enum DeletedProjects {
    struct Gone: Equatable {
        /// The projects whose folders went.
        var projects: Set<String> = []
        /// Their conversations, to take away.
        var conversations: [UUID] = []
    }

    /// What the app last read in `Projects/`: that folder, by its device and
    /// inode, and the names it held, with any gone since whose conversations
    /// are still to be taken.
    struct Seen: Codable, Equatable {
        var device: UInt64
        var inode: UInt64
        var names: [String]
    }

    /// `projects-seen.json`, beside `Projects/`.
    static func seenFile(in folder: DataFolder) -> URL {
        folder.root.appendingPathComponent("projects-seen.json")
    }

    /// The projects among `conversations`' that were `seen` and that
    /// `listed`, the names `Projects/` holds now, no longer has, and their
    /// conversations. A temporary conversation has no project to lose.
    static func gone(from conversations: [ChatSummary], listed: [String], seen: Set<String>) -> Gone {
        let vanished = seen.subtracting(listed)
        let orphaned = conversations.filter { summary in
            summary.projectName.map(vanished.contains) ?? false
        }
        return Gone(projects: Set(orphaned.compactMap(\.projectName)), conversations: orphaned.map(\.id))
    }

    /// Reads `Projects/` in `folder`, answers what went since the last
    /// reading of the same folder, and keeps this reading for the next. A
    /// listing that does not read takes nothing and changes nothing. A name
    /// gone stays seen while a conversation of it is left, so one that could
    /// not be taken away is tried again.
    static func gone(from conversations: [ChatSummary], in folder: DataFolder) -> Gone {
        guard let reading = reading(in: folder) else { return Gone() }
        let file = seenFile(in: folder)
        // persisted-read: an unreadable record only means nothing was seen, so nothing is taken
        let previous = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Seen.self, from: $0) }
        let seen = previous.map { $0.device == reading.device && $0.inode == reading.inode ? Set($0.names) : [] } ?? []
        let gone = gone(from: conversations, listed: reading.names, seen: seen)
        let next = Seen(
            device: reading.device,
            inode: reading.inode,
            names: Set(reading.names).union(gone.projects).sorted(),
        )
        if next != previous, let data = try? JSONEncoder().encode(next) {
            try? data.write(to: file, options: .atomic)
        }
        return gone
    }

    /// The names in `Projects/` and which folder it is, read where
    /// `DataFolder.removeProject` deletes: nil when the folder is missing, a
    /// link out of the data folder, or does not read.
    static func reading(in folder: DataFolder) -> Seen? {
        var info = stat()
        guard let root = CanonicalPath.resolve(folder.root.path),
              let projects = CanonicalPath.resolve(folder.projects.path), projects == root + "/Projects",
              stat(projects, &info) == 0,
              let names = try? FileManager.default.contentsOfDirectory(atPath: projects)
        else { return nil }
        return Seen(device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), names: names)
    }
}
