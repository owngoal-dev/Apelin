import Foundation

/// One journal: a launch's, the file Dog opens at launch in the data
/// folder's `Journal/`, named `Dog_<yyyy-MM-dd_HH-mm-ss>_<eight characters>.log`;
/// or a conversation's, the one its agent writes in `Journal/Agent/`,
/// `<session>.log` with the file it rotated out as `<session>.old.log`.
struct JournalFile: Hashable, Sendable {
    let url: URL
    /// When the launch began, read off the name; nil for a name Dog did
    /// not write, and for a conversation's.
    let started: Date?
    let size: Int
    /// The conversation's session, for a conversation's journal.
    var sessionID: String?
    /// The file the conversation's journal rotated out, read before it.
    var previous: URL?
    /// When a conversation's journal was last written.
    var modified: Date?

    var name: String {
        url.lastPathComponent
    }

    /// What Share names the copy it sends: `apelin-<launch>.log`, or
    /// `apelin-agent-<session>.log`.
    var shareName: String {
        sessionID.map { "apelin-agent-\($0).log" } ?? "apelin-" + name.dropFirst(4)
    }
}

/// The journals Settings ▸ Logs lists: Dog's, one per launch, its 100
/// newest — the only record of an earlier launch, since the live log keeps
/// no history on iOS — and the agent's, one per conversation, the 100
/// written last.
enum JournalFiles {
    /// Dog's journals in `directory`, newest first: by the launch in the
    /// name, then by name, with names Dog did not date last. Only regular
    /// files named `Dog_` … `.log` count, as Dog's own clean-up counts them;
    /// a link is not followed.
    static func list(in directory: URL) -> [JournalFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasPrefix("Dog_") && $0.hasSuffix(".log") }.compactMap { name -> JournalFile? in
            let url = directory.appendingPathComponent(name)
            guard let metadata = regularFile(at: url) else { return nil }
            return JournalFile(url: url, started: started(fromName: name), size: Int(metadata.st_size))
        }
        return files.sorted { a, b in
            switch (a.started, b.started) {
            case let (first?, second?) where first != second: first > second
            case (_?, nil): true
            case (nil, _?): false
            default: a.name > b.name
            }
        }
    }

    /// The conversations' journals in `directory`, written last first:
    /// regular files named for a session, `<session>.log`, each with its
    /// rotated `<session>.old.log` when that is a regular file too. A link
    /// is not followed.
    static func conversations(in directory: URL) -> [JournalFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.compactMap { name -> JournalFile? in
            guard name.hasSuffix(".log") else { return nil }
            let session = String(name.dropLast(".log".count))
            guard UUID(uuidString: session) != nil else { return nil }
            let url = directory.appendingPathComponent(name)
            guard let metadata = regularFile(at: url) else { return nil }
            let previous = directory.appendingPathComponent(session + ".old.log")
            let modified = metadata.st_mtimespec
            return JournalFile(
                url: url,
                started: nil,
                size: Int(metadata.st_size),
                sessionID: session,
                previous: regularFile(at: previous) == nil ? nil : previous,
                modified: Date(timeIntervalSince1970: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1e9),
            )
        }
        return files.sorted { a, b in
            a.modified != b.modified ? (a.modified ?? .distantPast) > (b.modified ?? .distantPast) : a.name > b.name
        }
    }

    /// The launch a name Dog wrote begins with: `Dog_`, the date in local
    /// time, `_`, eight characters and `.log`.
    static func started(fromName name: String) -> Date? {
        guard name.count == 36, name.hasPrefix("Dog_"), name.hasSuffix(".log") else { return nil }
        return formatter.date(from: String(name.dropFirst(4).prefix(19)))
    }

    private static func regularFile(at url: URL) -> stat? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        return metadata
    }

    /// Dog's own: fixed to en_US_POSIX and the Gregorian calendar, so the
    /// reader's calendar or clock cannot change how a name reads back.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
