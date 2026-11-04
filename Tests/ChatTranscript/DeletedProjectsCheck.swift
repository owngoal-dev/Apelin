import ApelinCore
import Foundation

/// A project whose folder has gone from `Projects/` takes its conversations
/// with it, but only a disappearance the app saw: a project listed in an
/// earlier reading of the same `Projects/`. One still there keeps them, a
/// temporary conversation has no project to lose, and a `Projects/` that
/// did not read, one in the wrong data folder, or one made again empty
/// takes nothing (#37).
func checkDeletedProjects() {
    let weather = ChatSummary(title: "Rain", lastInteraction: Date(), projectName: "Weather")
    let weatherToo = ChatSummary(title: "Wind", lastInteraction: Date(), projectName: "Weather")
    let clock = ChatSummary(title: "Alarm", lastInteraction: Date(), projectName: "Clock")
    let general = ChatSummary(title: "Hello", lastInteraction: Date(), projectName: nil)
    let chats = [weather, clock, general, weatherToo]

    // What went, from what was seen and what is listed.
    let seenBoth: Set = ["Clock", "Weather"]
    let gone = DeletedProjects.gone(from: chats, listed: ["Clock", ".Weather.creating-1a2b3c4d"], seen: seenBoth)
    precondition(gone.projects == ["Weather"], "the project whose folder went: \(gone.projects)")
    precondition(gone.conversations == [weather.id, weatherToo.id], "and every conversation of it, none of another's or General Chat's")
    precondition(DeletedProjects.gone(from: chats, listed: ["Clock", "Weather"], seen: seenBoth) == DeletedProjects.Gone(), "every folder still there: nothing")
    precondition(DeletedProjects.gone(from: chats, listed: [], seen: []) == DeletedProjects.Gone(), "nothing seen before: nothing goes, however empty the listing")
    precondition(DeletedProjects.gone(from: chats, listed: [], seen: ["Clock"]).projects == ["Clock"], "only what was seen goes")
    precondition(DeletedProjects.gone(from: [general], listed: [], seen: seenBoth).conversations.isEmpty, "a temporary conversation has no project to lose")
    // The same name in another normalisation is the same folder.
    let café = ChatSummary(title: "Menu", lastInteraction: Date(), projectName: "Caf\u{E9}")
    precondition(DeletedProjects.gone(from: [café], listed: ["Cafe\u{301}"], seen: ["Caf\u{E9}"]).conversations.isEmpty, "a name is compared as text, not as bytes")

    // Read in a data folder, and kept there for the next reading.
    let base = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("apelin-deleted-projects-\(UUID().uuidString.prefix(8))", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let manager = FileManager.default
    let folder = DataFolder(home: base.appendingPathComponent("mobile").path)
    try? manager.createDirectory(at: folder.root, withIntermediateDirectories: true)
    precondition(DeletedProjects.gone(from: chats, in: folder) == DeletedProjects.Gone(), "no Projects/ takes nothing")
    precondition(!manager.fileExists(atPath: DeletedProjects.seenFile(in: folder).path), "and records nothing")

    for name in ["Clock", "Weather"] {
        try? manager.createDirectory(at: folder.projects.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    precondition(DeletedProjects.gone(from: chats, in: folder) == DeletedProjects.Gone(), "the first reading has seen nothing go")
    precondition(DeletedProjects.gone(from: chats, in: folder) == DeletedProjects.Gone(), "nor does a second with both there")

    // apelin_project_delete, a command or another app takes the folder away:
    // its conversations go, and again until they are gone.
    try? manager.removeItem(at: folder.projects.appendingPathComponent("Weather"))
    let removed = DeletedProjects.gone(from: chats, in: folder)
    precondition(removed.projects == ["Weather"], "a project seen and gone takes its conversations: \(removed.projects)")
    precondition(removed.conversations == [weather.id, weatherToo.id], "all of them")
    precondition(DeletedProjects.gone(from: chats, in: folder) == removed, "one not taken away yet is tried again")
    let left = [clock, general]
    precondition(DeletedProjects.gone(from: left, in: folder) == DeletedProjects.Gone(), "once taken, nothing more")
    let weatherAgain = ChatSummary(title: "Fog", lastInteraction: Date(), projectName: "Weather")
    precondition(DeletedProjects.gone(from: left + [weatherAgain], in: folder) == DeletedProjects.Gone(), "and the name is no longer seen")

    // The app's own Delete takes the folder and its conversations together.
    try? manager.removeItem(at: folder.projects.appendingPathComponent("Clock"))
    precondition(DeletedProjects.gone(from: [general], in: folder) == DeletedProjects.Gone(), "nothing left to take after Delete")

    // A Projects/ made again, empty, after it went: a folder never read.
    let alarm = ChatSummary(title: "Snooze", lastInteraction: Date(), projectName: "Alarm")
    try? manager.createDirectory(at: folder.projects.appendingPathComponent("Alarm"), withIntermediateDirectories: true)
    precondition(DeletedProjects.gone(from: [alarm], in: folder) == DeletedProjects.Gone(), "Alarm seen")
    try? manager.removeItem(at: folder.projects)
    precondition(DeletedProjects.gone(from: [alarm], in: folder) == DeletedProjects.Gone(), "no Projects/: nothing goes")
    try? manager.createDirectory(at: folder.projects, withIntermediateDirectories: true)
    precondition(DeletedProjects.gone(from: [alarm], in: folder) == DeletedProjects.Gone(), "a Projects/ made again has seen nothing go")

    // Another data folder, its Projects/ new and empty: the conversations
    // were never its to take, at the first reading or any after (0.3.5 on
    // rootless read its data container's).
    let other = DataFolder(home: base.appendingPathComponent("container").path)
    try? manager.createDirectory(at: other.projects, withIntermediateDirectories: true)
    precondition(DeletedProjects.gone(from: chats, in: other) == DeletedProjects.Gone(), "a wrong folder takes nothing")
    precondition(DeletedProjects.gone(from: chats, in: other) == DeletedProjects.Gone(), "the next launch neither")

    // A record that does not read means nothing was seen.
    try? manager.createDirectory(at: folder.projects.appendingPathComponent("Alarm"), withIntermediateDirectories: true)
    precondition(DeletedProjects.gone(from: [alarm], in: folder) == DeletedProjects.Gone(), "Alarm seen again")
    try? Data("{".utf8).write(to: DeletedProjects.seenFile(in: folder))
    try? manager.removeItem(at: folder.projects.appendingPathComponent("Alarm"))
    precondition(DeletedProjects.gone(from: [alarm], in: folder) == DeletedProjects.Gone(), "an unreadable record has seen nothing go")

    // A Projects/ that links out of the data folder is no listing.
    let elsewhere = base.appendingPathComponent("Elsewhere", isDirectory: true)
    try? manager.moveItem(at: folder.projects, to: elsewhere)
    try? manager.createSymbolicLink(at: folder.projects, withDestinationURL: elsewhere)
    precondition(DeletedProjects.reading(in: folder) == nil, "a Projects/ that links out of the data folder is no listing")
    print("ok: a deleted project's conversations go with it, only once the app saw it go")
}
