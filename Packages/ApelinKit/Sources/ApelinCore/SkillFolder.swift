import Foundation

/// The skills folder, `~/Documents/wiki.qaq.apelin/skills`, as Settings ▸
/// Skills changes it. A skill comes in as a copy of a folder with a
/// `SKILL.md` at its top, or of one Markdown file, which becomes the
/// `SKILL.md` of a folder named for it; it goes out by its place in the
/// folder (`AgentSkill.location`). Sessions read the folder again for every
/// message, so nothing else is told. Settings ▸ Skills and the agent's skill
/// tools both write it through this, as mobile.
public struct SkillFolder {
    public static let maximumBytes = 32 << 20
    public static let maximumEntries = 2000

    public enum Failure: Error, Equatable {
        /// Neither a folder with a `SKILL.md` at its top nor a Markdown
        /// file a folder can be named for.
        case notASkill
        /// Something already sits at that place in the folder.
        case exists(String)
        case tooLarge
        /// Not a place inside the folder.
        case invalidLocation
        /// The `SKILL.md` opens with an empty frontmatter, which gives no
        /// description and stops kwwk's loader
        /// (`SkillManifest.stopsKwwkLoader`).
        case emptyFrontmatter
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Where `source` goes: a folder keeps its name, a Markdown file gives
    /// its name without the extension.
    public func location(for source: URL) throws -> String {
        let name = source.lastPathComponent
        if Self.isDirectory(source) {
            guard Self.isRegularFile(source.appendingPathComponent("SKILL.md")) else { throw Failure.notASkill }
            return try Self.checked(name)
        }
        let stem = source.deletingPathExtension().lastPathComponent
        guard source.pathExtension.lowercased() == "md", stem.lowercased() != "skill" else {
            throw Failure.notASkill
        }
        return try Self.checked(stem)
    }

    /// Copies `source` in at `location(for:)`, over what is there only when
    /// `replacing`. Links and hidden entries stay behind; folders and
    /// regular files are copied, at most `maximumEntries` of them and
    /// `maximumBytes` in all. The copy is made beside the folder's skills
    /// under a hidden name and moved into place whole.
    @discardableResult
    public func add(_ source: URL, replacing: Bool) throws -> String {
        let location = try location(for: source)
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: false)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        if Self.isDirectory(source) {
            var budget = (entries: Self.maximumEntries, bytes: Self.maximumBytes)
            try Self.copyContents(of: source, into: staging, budget: &budget)
        } else {
            guard Self.size(of: source) <= Self.maximumBytes else { throw Failure.tooLarge }
            try manager.copyItem(at: source, to: staging.appendingPathComponent("SKILL.md"))
        }
        // Judged on the copy, the bytes that would stay.
        guard !SkillManifest.stopsKwwkLoader(fileAt: staging.appendingPathComponent("SKILL.md")) else {
            throw Failure.emptyFrontmatter
        }
        try place(staging, at: location, replacing: replacing)
        return location
    }

    /// Writes `text` as the `SKILL.md` of a folder named `name`, over what
    /// is there only when `replacing`. The folder is staged beside the
    /// folder's skills under a hidden name, still called `name`, and handed
    /// to `check` there; only if it passes is it moved into place whole.
    @discardableResult
    public func write(_ text: String, named name: String, replacing: Bool, check: (URL) throws -> Void = { _ in }) throws -> String {
        let location = try Self.checked(name)
        guard text.utf8.count <= Self.maximumBytes else { throw Failure.tooLarge }
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: false)
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(location, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(text.utf8).write(to: folder.appendingPathComponent("SKILL.md"), options: .withoutOverwriting)
        try check(folder)
        try place(folder, at: location, replacing: replacing)
        return location
    }

    /// Moves `staged` in at `location`; what is there goes only when
    /// `replacing`, moved aside first — a link itself, never what it names.
    private func place(_ staged: URL, at location: String, replacing: Bool) throws {
        let manager = FileManager.default
        let destination = root.appendingPathComponent(location, isDirectory: true)
        if Self.exists(destination) {
            guard replacing else { throw Failure.exists(location) }
            let old = root.appendingPathComponent(".removing-\(UUID().uuidString)", isDirectory: true)
            try manager.moveItem(at: destination, to: old)
            defer { try? manager.removeItem(at: old) }
            try manager.moveItem(at: staged, to: destination)
        } else {
            try manager.moveItem(at: staged, to: destination)
        }
    }

    /// Removes what sits at `location`, a link itself rather than what it
    /// names, and only inside the folder: no part of the way there may be a
    /// link that leads out of it.
    public func remove(_ location: String) throws {
        let parts = location.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ (try? Self.checked($0)) != nil }) else {
            throw Failure.invalidLocation
        }
        let target = parts.reduce(root) { $0.appendingPathComponent($1) }
        let folder = root.resolvingSymlinksInPath().path
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == folder || parent.hasPrefix(folder + "/"), Self.exists(target) else {
            throw Failure.invalidLocation
        }
        try FileManager.default.removeItem(at: target)
    }

    // MARK: - Copying

    private static func copyContents(
        of source: URL,
        into destination: URL,
        budget: inout (entries: Int, bytes: Int),
    ) throws {
        let manager = FileManager.default
        for name in try manager.contentsOfDirectory(atPath: source.path).sorted() where !name.hasPrefix(".") {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            budget.entries -= 1
            guard budget.entries >= 0 else { throw Failure.tooLarge }
            if isDirectory(from) {
                try manager.createDirectory(at: to, withIntermediateDirectories: false)
                try copyContents(of: from, into: to, budget: &budget)
            } else if isRegularFile(from) {
                budget.bytes -= size(of: from)
                guard budget.bytes >= 0 else { throw Failure.tooLarge }
                try manager.copyItem(at: from, to: to)
            }
        }
    }

    /// One name in the folder: not empty, hidden, `..` or holding a slash.
    private static func checked(_ name: String) throws -> String {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            throw Failure.invalidLocation
        }
        return name
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func exists(_ url: URL) -> Bool {
        attributes(url) != nil
    }

    /// A folder itself, never a link to one.
    private static func isDirectory(_ url: URL) -> Bool {
        attributes(url)?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        attributes(url)?[.type] as? FileAttributeType == .typeRegular
    }

    private static func size(of url: URL) -> Int {
        (attributes(url)?[.size] as? NSNumber)?.intValue ?? 0
    }
}
