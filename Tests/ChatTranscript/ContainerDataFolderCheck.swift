import ApelinCore
import Foundation

/// The data folder a rootless app kept in its data container moves into
/// mobile's at launch (#37): every file mobile's lacks by a rename, the newer
/// of two of one name kept and the older set aside with the container's
/// folder, memories merged by ID, links and the console's running scripts
/// left; never through a link, never when either folder is missing or the
/// two are one; and once set aside, nothing more.
func checkContainerDataFolder() {
    let manager = FileManager.default
    let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("apelin-container-data-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? manager.removeItem(at: base) }
    let mobile = base.appendingPathComponent("var/mobile", isDirectory: true)
    let folder = DataFolder(home: mobile.path)
    let container = mobile.appendingPathComponent("Containers/Data/Application/0F1E2D3C-0000-4000-8000-000000000000")
    let stray = DataFolder(home: container.path)
    let outside = base.appendingPathComponent("outside", isDirectory: true)
    let only = UUID().uuidString + ".json"
    let newer = UUID().uuidString + ".json"
    let older = UUID().uuidString + ".json"
    let temporary = UUID().uuidString
    let earlier = Date(timeIntervalSince1970: 1_790_000_000)
    let later = earlier.addingTimeInterval(60)

    func write(_ text: String, _ path: String, in root: URL, at date: Date? = nil) {
        let url = root.appendingPathComponent(path)
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
        if let date {
            try? manager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }
    func text(_ path: String, in root: URL) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }
    func exists(_ path: String, in root: URL) -> Bool {
        var info = stat()
        return lstat(root.appendingPathComponent(path).path, &info) == 0
    }

    // What 0.3.5 left in the container, and an outside folder a link names.
    write("only", "Chats/" + only, in: stray.root)
    write("container's, later", "Chats/" + newer, in: stray.root, at: later)
    write("container's, earlier", "Chats/" + older, in: stray.root, at: earlier)
    write("{", "Chats/Unreadable/" + only, in: stray.root)
    write("upload", "Chats/Uploads/0001/photo.jpg", in: stray.root)
    write("launch", "Journal/Dog_2026-11-01_10-00-00_abcdefgh.log", in: stray.root)
    write("mine", "skills/mine/SKILL.md", in: stray.root)
    write("notes", "Temporary/\(temporary)/notes.txt", in: stray.root)
    write("result", "console/out/run.jsonl", in: stray.root)
    write("{}", "console/running/script.json", in: stray.root)
    write("secret", "secret.txt", in: outside)
    try? manager.createDirectory(at: stray.projects, withIntermediateDirectories: true)
    try? manager.createSymbolicLink(
        at: stray.root.appendingPathComponent("Chats/link.json"),
        withDestinationURL: outside.appendingPathComponent("secret.txt"),
    )
    try? manager.createSymbolicLink(at: stray.root.appendingPathComponent("Linked"), withDestinationURL: outside)
    write("into a link", "inbox/archive.tar", in: stray.root)

    precondition(ContainerDataFolder.recover(from: stray, into: folder) == nil, "no data folder of mobile's: nothing moves")
    precondition(exists("Chats/" + only, in: stray.root), "and the container's stays as it was")

    // What mobile's already holds.
    write("mobile's, earlier", "Chats/" + newer, in: folder.root, at: earlier)
    write("mobile's, later", "Chats/" + older, in: folder.root, at: later)
    write("agent", "Journal/Agent/session.log", in: folder.root)
    try? manager.createSymbolicLink(at: folder.root.appendingPathComponent("inbox"), withDestinationURL: outside)
    let kept = MemoryRecord(title: "Kept", body: "The agent saved this.")
    _ = try? MemoryStore(root: folder.root).save(kept, revision: "empty")
    let added = MemoryRecord(title: "Added", body: "The reader typed this in Settings.")
    let again = MemoryRecord(id: kept.id, title: "Kept", body: "Another text under the same ID.")
    _ = try? MemoryStore(root: stray.root).save(added, revision: "empty")
    if let snapshot = try? MemoryStore(root: stray.root).read() {
        _ = try? MemoryStore(root: stray.root).save(again, revision: snapshot.revision)
    }

    precondition(ContainerDataFolder.recover(from: folder, into: folder) == nil, "one folder: nothing to move")
    let linked = DataFolder(home: base.appendingPathComponent("linked").path)
    try? manager.createDirectory(at: linked.root.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? manager.createSymbolicLink(at: linked.root, withDestinationURL: stray.root)
    precondition(ContainerDataFolder.recover(from: linked, into: folder) == nil, "a data folder that is a link is never followed")

    guard let recovery = ContainerDataFolder.recover(from: stray, into: folder, now: later) else {
        preconditionFailure("both folders there: what the container's holds moves")
    }
    precondition(Set(recovery.moved) == [
        "Chats/" + only, "Chats/Unreadable/" + only, "Chats/Uploads/0001/photo.jpg",
        "Journal/Dog_2026-11-01_10-00-00_abcdefgh.log",
        "Temporary/\(temporary)/notes.txt",
        "console/out/run.jsonl",
        "skills/mine/SKILL.md",
    ], "every file mobile's lacks: \(recovery.moved)")
    precondition(text("Chats/" + only, in: folder.root) == "only", "a conversation moves whole")
    precondition(text("Chats/Uploads/0001/photo.jpg", in: folder.root) == "upload", "and its uploads with it")
    precondition(text("skills/mine/SKILL.md", in: folder.root) == "mine", "a folder mobile's lacks is made for what lands in it")
    precondition(text("Journal/Agent/session.log", in: folder.root) == "agent", "mobile's own files stay")

    precondition(recovery.replaced == ["Chats/" + newer], "the container's newer copy is taken: \(recovery.replaced)")
    precondition(text("Chats/" + newer, in: folder.root) == "container's, later", "into mobile's folder")
    precondition(recovery.kept == ["Chats/" + older], "mobile's newer copy stays: \(recovery.kept)")
    precondition(text("Chats/" + older, in: folder.root) == "mobile's, later", "as it was")

    precondition(
        Set(recovery.left) == ["Chats/link.json", "Linked", "console/running", "inbox"],
        "links, a link in mobile's way and running scripts stay: \(recovery.left)",
    )
    precondition(!exists("Chats/link.json", in: folder.root) && !exists("Linked", in: folder.root), "no link is moved")
    precondition((try? manager.contentsOfDirectory(atPath: outside.path)) == ["secret.txt"], "nothing is put through a link")
    precondition(!exists("console/running", in: folder.root), "a running script would run again")
    precondition(!exists("Projects", in: folder.root), "an empty folder makes nothing")

    precondition(recovery.memories == 1, "the memory mobile's lacks is added: \(recovery.memories)")
    precondition(recovery.memoriesLeft == 1, "the one of an ID mobile's has stays in the container: \(recovery.memoriesLeft)")
    let memories = (try? MemoryStore(root: folder.root).read().records) ?? []
    precondition(memories == [kept, added], "mobile's text wins for its ID: \(memories)")

    precondition(recovery.setAside == "wiki.qaq.apelin.migrated", "renamed aside: \(String(describing: recovery.setAside))")
    let aside = stray.root.deletingLastPathComponent().appendingPathComponent("wiki.qaq.apelin.migrated")
    precondition(!manager.fileExists(atPath: stray.root.path), "the container's folder is gone from where the app looked")
    precondition(text("Chats/" + newer, in: aside) == "mobile's, earlier", "mobile's older copy is kept aside")
    precondition(text("Chats/" + older, in: aside) == "container's, earlier", "and so is the container's")
    precondition(text("console/running/script.json", in: aside) == "{}", "with what stayed")
    precondition(text("inbox/archive.tar", in: aside) == "into a link", "a file a link stood in the way of too")
    precondition(ContainerDataFolder.recover(from: stray, into: folder) == nil, "the next launch has nothing to do")

    // An older build run again makes the folder again; it is moved again,
    // and set aside beside the first.
    write("again", "Chats/" + UUID().uuidString + ".json", in: stray.root)
    let second = ContainerDataFolder.recover(from: stray, into: folder, now: later)
    precondition(second?.moved.count == 1, "what the older build wrote moves too")
    precondition(second?.setAside == "wiki.qaq.apelin.migrated-20260921-141420", "beside the first: \(String(describing: second?.setAside))")
    print("ok: a rootless app's data container moves into mobile's data folder, keeping the newer of two")
}
