import ApelinCore
import Foundation

/// The data folder 0.3.5 and earlier kept in the app's data container on
/// rootless, moved into mobile's at launch (#37).
///
/// rootless uicache registers an app without `no-container` with a data
/// container and makes that its home, and the app took its data folder
/// from its home there. The console made `<container>/Documents/wiki.qaq.apelin`
/// at the first launch, and the app kept its conversations, drafts and
/// uploads, the memories and skills added in Settings and its journal in
/// it, while the package, the session host and the agent used mobile's.
/// Its `Projects/` was empty, so every project's conversations were taken
/// for a deleted project's at each launch (`DeletedProjects`) and are gone.
///
/// Every regular file moves to the same place in mobile's folder by a
/// rename, so it is never copied and never deleted. Where mobile's has a
/// file of that name already, the newer stays there and the older stays in
/// the container's folder; memories are merged by ID instead, mobile's
/// winning. A link, a special file, a file where mobile's has a folder or a
/// link, and the console's `running/` (a script left there would run again)
/// stay where they are. The container's folder is then renamed aside,
/// `wiki.qaq.apelin.migrated`, which holds whatever stayed, so the next
/// launch finds nothing to do. The app's preferences are not here: they
/// stay in the container, where the app still reads them.
enum ContainerDataFolder {
    struct Recovery: Equatable {
        /// Moved where mobile's folder had nothing of that name.
        var moved: [String] = []
        /// The container's newer copy taken; mobile's older one kept aside.
        var replaced: [String] = []
        /// Mobile's newer copy kept; the container's older one kept aside.
        var kept: [String] = []
        /// Left in the container's folder: links, special files, clashes
        /// with a folder or a link, the console's running scripts.
        var left: [String] = []
        /// Memories added to mobile's.
        var memories = 0
        /// Memories mobile's does not hold as they were, which stay in the
        /// container's file: refused by the store, or of an ID mobile's has
        /// with other text.
        var memoriesLeft = 0
        /// The name the container's folder was given, once renamed aside.
        var setAside: String?
    }

    /// Paths that never move as files: the memories are merged by ID, their
    /// lock is the store's, and a running script would run again.
    private static let stays: Set = ["memories.json", "memories.lock", "console/running"]

    /// Moves what `stray` holds into `folder` and renames `stray` aside. Nil,
    /// with nothing touched, when there is nothing to move: `stray` missing
    /// (or already set aside) or a link, `folder` missing or a link, or one
    /// inside the other.
    static func recover(from stray: DataFolder, into folder: DataFolder, now: Date = Date()) -> Recovery? {
        guard isDirectory(stray.root.path), isDirectory(folder.root.path),
              let strayPath = CanonicalPath.resolve(stray.root.path),
              let folderPath = CanonicalPath.resolve(folder.root.path),
              !CanonicalPath.isCanonical(strayPath, inside: folderPath),
              !CanonicalPath.isCanonical(folderPath, inside: strayPath)
        else { return nil }
        var recovery = Recovery()
        merge("", from: stray.root.path, to: folder.root.path, into: &recovery)
        mergeMemories(from: stray, into: folder, into: &recovery)
        let parent = stray.root.deletingLastPathComponent()
        let base = stray.root.lastPathComponent + ".migrated"
        for name in [base, base + "-" + stamp(now)] {
            if renamex_np(stray.root.path, parent.appendingPathComponent(name).path, UInt32(RENAME_EXCL)) == 0 {
                recovery.setAside = name
                break
            }
        }
        return recovery
    }

    /// One folder's entries. `source` is a directory, never a link;
    /// `target` is one too, or missing until `made` makes it, which happens
    /// only once a file is to land in it.
    private static func merge(
        _ relative: String,
        from source: String,
        to target: String,
        made makeParent: () -> Bool = { true },
        into recovery: inout Recovery,
    ) {
        var exists = isDirectory(target)
        func made() -> Bool {
            if !exists {
                exists = makeParent() && (mkdir(target, 0o755) == 0 || isDirectory(target))
            }
            return exists
        }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []
        for entry in entries.sorted() {
            let path = relative.isEmpty ? entry : relative + "/" + entry
            let from = source + "/" + entry
            let to = target + "/" + entry
            var info = stat()
            guard lstat(from, &info) == 0 else { continue }
            if stays.contains(path) {
                if path == "console/running" {
                    recovery.left.append(path)
                }
                continue
            }
            var there = stat()
            let found = exists && lstat(to, &there) == 0
            let kind = info.st_mode & S_IFMT
            let thereKind = there.st_mode & S_IFMT
            if kind == S_IFDIR, !found || thereKind == S_IFDIR {
                merge(path, from: from, to: to, made: made, into: &recovery)
            } else if kind != S_IFREG || found && thereKind != S_IFREG {
                // a link, a special file, or a clash with a folder or a link
                recovery.left.append(path)
            } else if !found {
                if made(), renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 {
                    recovery.moved.append(path)
                } else {
                    recovery.left.append(path)
                }
            } else if isNewer(info, than: there) {
                // the two change places: the older goes aside with the folder
                if renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 {
                    recovery.replaced.append(path)
                } else {
                    recovery.left.append(path)
                }
            } else {
                recovery.kept.append(path)
            }
        }
    }

    /// Each memory mobile's lacks, by its ID, added as the store adds one.
    /// What mobile's then does not hold as it was stays in the container's
    /// file, and a file either store cannot read stays whole.
    private static func mergeMemories(from stray: DataFolder, into folder: DataFolder, into recovery: inout Recovery) {
        var info = stat()
        guard lstat(stray.root.appendingPathComponent("memories.json").path, &info) == 0 else { return }
        let store = MemoryStore(root: folder.root)
        guard let records = try? MemoryStore(root: stray.root).read().records, var snapshot = try? store.read() else {
            recovery.left.append("memories.json")
            return
        }
        for record in records where !snapshot.records.contains(where: { $0.id == record.id }) {
            guard let saved = try? store.save(record, revision: snapshot.revision) else { continue }
            snapshot = saved
            recovery.memories += 1
        }
        recovery.memoriesLeft = records.filter { !snapshot.records.contains($0) }.count
    }

    private static func isNewer(_ lhs: stat, than rhs: stat) -> Bool {
        (lhs.st_mtimespec.tv_sec, lhs.st_mtimespec.tv_nsec) > (rhs.st_mtimespec.tv_sec, rhs.st_mtimespec.tv_nsec)
    }

    /// A directory itself, never through a link.
    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
