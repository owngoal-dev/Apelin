import Darwin
import Foundation

/// Whose custom instructions: those for every conversation, or one
/// project's, by its `projectID`.
public enum InstructionsScope: Hashable, Sendable {
    case allChats
    case project(String)
}

/// What a scope's file holds, as a reader finds it.
public enum SavedInstructions: Equatable, Sendable {
    case none
    case text(String)
    /// A file is there that this store would not have written: a link, a
    /// file with another link or owner, one others may write, too long, not
    /// UTF-8, or holding a NUL. The app sets it aside when it next loads it.
    case unreadable

    public var text: String? {
        if case let .text(text) = self {
            return text
        }
        return nil
    }
}

public enum CustomInstructionsError: Error, Equatable {
    /// The file is no longer what the editor loaded: another window saved
    /// or cleared it, or it stopped reading.
    case changed
    case tooLong
    /// Text with a NUL in it.
    case invalidContent
    /// A project ID this store does not take as a file name.
    case invalidProject
    /// A level of the folder is a link or no directory, or does not open.
    case unsafeFile
}

/// The user's custom instructions for the agent (issue #74): standing
/// preferences, those for every conversation and one project's, which a
/// session puts in its system prompt when it opens. They are the user's,
/// so they live in the data folder, never in the project, where a commit
/// or another repository would take them:
///
///     Instructions/global.md               every conversation's
///     Instructions/Projects/<projectID>.md  one project's
///
/// The app writes them, as mobile; apelin-agent, mobile too, only reads.
/// Each is UTF-8 text of at most `maximumCharacters`, so a change of both
/// fits a `<system-state>` delta whole. A file is read only when it is
/// regular, singly linked, the caller's own and writable by no one else;
/// no link is followed at any level. A save replaces the file atomically,
/// under a lock, and only while it still holds what the editor loaded, so
/// an older window cannot undo a newer save or a Clear. A file that does
/// not read is set aside (`UnreadableFile`) when the app loads it, never
/// replaced by an empty one.
public struct CustomInstructionsStore: Sendable {
    /// Each scope's limit, in characters as Swift counts them.
    public static let maximumCharacters = 2000
    /// The most a file may hold, whatever its characters.
    public static let maximumBytes = 16 * 1024
    public static let folderName = "Instructions"
    static let globalFile = "global.md"
    static let projectsFolder = "Projects"
    static let lockFile = ".lock"
    private static let fileExtension = ".md"
    private static let maximumManifestBytes = 1 << 20

    private let root: URL

    /// `root` is the data folder, `~/Documents/wiki.qaq.apelin`.
    public init(root: URL) {
        self.root = root
    }

    /// `Instructions/` in the data folder.
    public var folder: URL {
        root.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Whether `id` names a project's file: letters, digits and hyphens, a
    /// letter or digit first, at most 64, as a `projectID` (a UUID) is. A
    /// temporary conversation's `temporary:` identity is none.
    public static func isProjectKey(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.utf8.count <= 64 else { return false }
        func allowed(_ scalar: Unicode.Scalar) -> Bool {
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
        return first != "-" && id.unicodeScalars.allSatisfy(allowed)
    }

    // MARK: - Reading

    /// What `scope` holds, as a session reads it: nothing is changed, made
    /// or set aside.
    public func read(_ scope: InstructionsScope) -> SavedInstructions {
        guard let name = Self.fileName(scope) else { return .none }
        do {
            guard let base = try openRoot() else { return .none }
            defer { close(base) }
            guard let instructions = try Self.openDirectory(Self.folderName, in: base) else { return .none }
            defer { close(instructions) }
            guard case .project = scope else { return Self.readFile(name, in: instructions) }
            guard let projects = try Self.openDirectory(Self.projectsFolder, in: instructions) else { return .none }
            defer { close(projects) }
            return Self.readFile(name, in: projects)
        } catch {
            return .unreadable
        }
    }

    /// What the editor starts from, and where a file that did not read was
    /// set aside (`UnreadableFile`), so a save can never replace it.
    public struct Loaded: Equatable, Sendable {
        public var text: String
        /// The set-aside file's name, beside where it was.
        public var setAside: String?

        public init(text: String, setAside: String? = nil) {
            self.text = text
            self.setAside = setAside
        }
    }

    /// What `scope` holds, for the app to edit: a file that does not read is
    /// set aside and the editor starts empty. Makes no folder.
    public func load(_ scope: InstructionsScope) throws -> Loaded {
        guard let name = Self.fileName(scope) else { throw CustomInstructionsError.invalidProject }
        return try locked(making: false) { instructions in
            guard let directory = try Self.directory(for: scope, in: instructions, making: false) else {
                return Loaded(text: "", setAside: nil)
            }
            defer { Self.closeIfOwn(directory, instructions) }
            switch Self.readFile(name, in: directory) {
            case .none:
                return Loaded(text: "", setAside: nil)
            case let .text(text):
                return Loaded(text: text, setAside: nil)
            case .unreadable:
                guard let aside = UnreadableFile.setAside(name, in: directory) else {
                    throw CustomInstructionsError.unsafeFile
                }
                return Loaded(text: "", setAside: aside)
            }
        } ?? Loaded(text: "", setAside: nil)
    }

    // MARK: - Writing

    /// Saves `text` for `scope`, trimmed; empty text clears it. Refused with
    /// `changed` unless the file still holds `previous`, what the editor
    /// loaded ("" for none).
    public func save(_ text: String, for scope: InstructionsScope, replacing previous: String) throws {
        guard let name = Self.fileName(scope) else { throw CustomInstructionsError.invalidProject }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.utf8.contains(0) else { throw CustomInstructionsError.invalidContent }
        guard text.count <= Self.maximumCharacters, text.utf8.count < Self.maximumBytes else {
            throw CustomInstructionsError.tooLong
        }
        _ = try locked(making: true) { instructions in
            guard let directory = try Self.directory(for: scope, in: instructions, making: true) else {
                throw CustomInstructionsError.unsafeFile
            }
            defer { Self.closeIfOwn(directory, instructions) }
            let current = Self.readFile(name, in: directory)
            guard current != .unreadable, (current.text ?? "") == expected else {
                throw CustomInstructionsError.changed
            }
            if text.isEmpty {
                guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw Self.posixError() }
            } else {
                try Self.write(text + "\n", named: name, in: directory)
            }
            guard fsync(directory) == 0 else { throw Self.posixError() }
        }
    }

    /// Removes a deleted project's instructions, and any copy of them set
    /// aside: `ProjectDeletion` and the app's sweep (`removeGoneProjects`).
    public func removeProject(_ id: String) throws {
        guard let name = Self.fileName(.project(id)) else { return }
        _ = try locked(making: false) { instructions in
            guard let projects = try Self.openDirectory(Self.projectsFolder, in: instructions) else { return }
            defer { close(projects) }
            for entry in try Self.names(in: projects) where entry == name || entry.hasPrefix(name + ".unreadable-") {
                guard unlinkat(projects, entry, 0) == 0 || errno == ENOENT else { throw Self.posixError() }
            }
        }
    }

    /// The project IDs a file here names, set-aside copies included: what
    /// `ProjectReferences` counts as named. Nil when the folder does not read.
    public func projectIDs() -> Set<String>? {
        do {
            guard let base = try openRoot() else { return [] }
            defer { close(base) }
            guard let instructions = try Self.openDirectory(Self.folderName, in: base) else { return [] }
            defer { close(instructions) }
            guard let projects = try Self.openDirectory(Self.projectsFolder, in: instructions) else { return [] }
            defer { close(projects) }
            return try Set(Self.names(in: projects).compactMap(Self.projectID(ofEntry:)))
        } catch {
            return nil
        }
    }

    /// Removes the instructions of every project no folder in `Projects/`
    /// names any more, whatever took it away: the app's Delete, the
    /// agent's, a command or another app. Only when every folder there
    /// tells its project: a `Projects/` that does not read, or a folder
    /// whose `apelin-project.json` is missing, does not read or names no
    /// project (one being rewritten, or set aside by an import), takes
    /// nothing. Links and files there are no projects. Answers the IDs whose
    /// instructions went.
    @discardableResult
    public func removeGoneProjects() -> [String] {
        guard let saved = projectIDs(), !saved.isEmpty, let listed = Self.listedProjectIDs(in: root) else { return [] }
        var removed: [String] = []
        for id in saved.subtracting(listed).sorted() where (try? removeProject(id)) != nil {
            removed.append(id)
        }
        return removed
    }

    // MARK: - Files

    private static func fileName(_ scope: InstructionsScope) -> String? {
        switch scope {
        case .allChats: globalFile
        case let .project(id): isProjectKey(id) ? id + fileExtension : nil
        }
    }

    /// The project a file in `Projects/` is for: `<id>.md` or a copy of it
    /// set aside.
    private static func projectID(ofEntry entry: String) -> String? {
        guard let range = entry.range(of: fileExtension) else { return nil }
        let rest = entry[range.upperBound...]
        guard rest.isEmpty || rest.hasPrefix(".unreadable-") else { return nil }
        let id = String(entry[..<range.lowerBound])
        return isProjectKey(id) ? id : nil
    }

    /// Reads one scope's file; see `SavedInstructions.unreadable`.
    private static func readFile(_ name: String, in directory: Int32) -> SavedInstructions {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno == ENOENT ? .none : .unreadable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_size <= maximumBytes
        else { return .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8), !text.utf8.contains(0)
        else {
            // an empty file reads as no data
            return info.st_size == 0 ? .none : .unreadable
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maximumCharacters else { return .unreadable }
        return trimmed.isEmpty ? .none : .text(trimmed)
    }

    private static func write(_ text: String, named name: String, in directory: Int32) throws {
        let temporary = ".\(name)-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        defer {
            close(descriptor)
            unlinkat(directory, temporary, 0)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: Data(text.utf8))
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, name) == 0 else { throw posixError() }
    }

    // MARK: - Folders

    /// The data folder, opened as the directory it was when looked at, never
    /// through a link at its last level; nil when it is not there.
    private func openRoot() throws -> Int32? {
        var info = stat()
        guard lstat(root.path, &info) == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw Self.posixError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR, let canonical = CanonicalPath.resolve(root.path) else {
            throw CustomInstructionsError.unsafeFile
        }
        let directory = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw Self.posixError() }
        var opened = stat()
        guard fstat(directory, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            close(directory)
            throw CustomInstructionsError.unsafeFile
        }
        return directory
    }

    /// `name` in `parent` as a directory, never through a link; nil when it
    /// is not there.
    private static func openDirectory(_ name: String, in parent: Int32, making: Bool = false) throws -> Int32? {
        if making, mkdirat(parent, name, 0o755) != 0, errno != EEXIST {
            throw posixError()
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw CustomInstructionsError.unsafeFile
        }
        return directory
    }

    /// The directory `scope`'s file is in: `instructions` itself, or its
    /// `Projects/`, which the caller closes (`closeIfOwn`).
    private static func directory(for scope: InstructionsScope, in instructions: Int32, making: Bool) throws -> Int32? {
        guard case .project = scope else { return instructions }
        return try openDirectory(projectsFolder, in: instructions, making: making)
    }

    private static func closeIfOwn(_ directory: Int32, _ instructions: Int32) {
        if directory != instructions {
            close(directory)
        }
    }

    /// Runs `operation` on `Instructions/`, holding its lock. Without
    /// `making`, a folder that is not there answers nil and is not made.
    private func locked<T>(making: Bool, _ operation: (Int32) throws -> T) throws -> T? {
        guard let base = try openRoot() else {
            guard !making else { throw CustomInstructionsError.unsafeFile }
            return nil
        }
        defer { close(base) }
        guard let instructions = try Self.openDirectory(Self.folderName, in: base, making: making) else { return nil }
        defer { close(instructions) }
        let lock = openat(instructions, Self.lockFile, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw CustomInstructionsError.unsafeFile }
        defer { close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid()
        else {
            throw CustomInstructionsError.unsafeFile
        }
        guard flock(lock, LOCK_EX) == 0 else { throw Self.posixError() }
        defer { flock(lock, LOCK_UN) }
        return try operation(instructions)
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 {
                close(duplicate)
            }
            throw posixError()
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != ".", name != ".." {
                names.append(name)
            }
        }
        return names
    }

    // MARK: - Projects

    /// The `projectID` of every project folder in `Projects/`, or nil when
    /// one cannot be told (see `removeGoneProjects`).
    static func listedProjectIDs(in root: URL) -> Set<String>? {
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        guard let base = CanonicalPath.resolve(root.path),
              let canonical = CanonicalPath.resolve(projects.path), canonical == base + "/Projects"
        else { return nil }
        let directory = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        guard let entries = try? names(in: directory) else { return nil }
        var ids: Set<String> = []
        for entry in entries where !entry.hasPrefix(".") {
            var info = stat()
            guard fstatat(directory, entry, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            // a link or a file is no project
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            guard let id = projectID(ofFolder: entry, in: directory) else { return nil }
            ids.insert(id)
        }
        return ids
    }

    /// The `projectID` `Projects/<folder>/apelin-project.json` names, read
    /// without following a link.
    private static func projectID(ofFolder folder: String, in projects: Int32) -> String? {
        let directory = openat(projects, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        let descriptor = openat(directory, "apelin-project.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= maximumManifestBytes
        else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumManifestBytes + 1),
              let document = try? JSONCoding.decode(JSONValue.self, from: data)
        else { return nil }
        return document["projectID"]?.stringValue
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
