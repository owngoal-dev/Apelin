import Foundation
// The one-line rule is ApelinCore's (`LogText`); the Mac harness compiles
// its file beside this one, with no module to import.
#if canImport(ApelinCore)
    import enum ApelinCore.LogText
#endif

/// A level as Dog writes it into a line: Dog's own `DogLevel` raw values,
/// which Settings ▸ Logs reads back.
public enum DiagnosticLevel: String, Sendable {
    case verbose
    case info
    case warning
    case error
    case critical
}

/// One conversation's diagnostic journal, `Journal/Agent/<session>.log` in
/// the data folder, in Dog's line format so that Settings ▸ Logs reads it as
/// it reads the app's own journal: a `[Category]` line when the category
/// changes, then `* |<level>| yyyy-MM-dd_HH-mm-ss| message`. A message is
/// one line: a line break in it is written `\n`, so nothing a tool printed
/// can start an entry or a category of its own.
///
/// The worker writes it as mobile; nothing links Dog here. It is appended to
/// across the session's reopens. Past `rotationBytes` the file becomes
/// `<session>.old.log`, replacing the one before, and a new one starts.
/// Every write is synchronous under a lock, so the worker's last moment
/// still reaches the file. The file is opened without following a link and
/// written only while it is a regular file of this user's with one link:
/// a link, another user's file or a second name of one is never written
/// through. One deleted from Settings meanwhile is made again.
public final class DiagnosticJournal: @unchecked Sendable {
    /// Where a file is rotated: one predecessor of at most this much is kept.
    public static let rotationBytes = 2 * 1024 * 1024
    /// The conversations whose journals the folder keeps, written last first.
    public static let retainedJournals = 100
    public static let fileExtension = "log"
    /// What a rotated file's name ends with: `<session>.old.log`.
    public static let previousSuffix = ".old.log"

    public let url: URL
    /// The file `url` was rotated into last.
    public let previousURL: URL
    private let rotationBytes: Int
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var identity: (device: dev_t, inode: ino_t)?
    private var size = 0
    /// The category of the last line written to the open file.
    private var category: String?
    private let formatter = DiagnosticJournal.formatter("yyyy-MM-dd_HH-mm-ss")

    /// The journal `name` in `folder`, which must exist; nothing is opened
    /// until the first write.
    public init(folder: URL, name: String, rotationBytes: Int = DiagnosticJournal.rotationBytes) {
        url = folder.appendingPathComponent(name + "." + Self.fileExtension)
        previousURL = folder.appendingPathComponent(name + Self.previousSuffix)
        self.rotationBytes = rotationBytes
    }

    deinit {
        if descriptor >= 0 {
            close(descriptor)
        }
    }

    /// Writes one entry, with its category line first when the category
    /// changed. Answers whether it reached the file.
    @discardableResult
    public func write(
        _ category: String,
        _ message: String,
        level: DiagnosticLevel = .info,
        date: Date = Date(),
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let entry = Self.entry(level: level, timestamp: formatter.string(from: date), message: message)
        guard prepare(adding: entry.utf8.count + category.utf8.count + 3) else { return false }
        var text = self.category == category ? "" : "[\(category)]\n"
        text += entry + "\n"
        let data = Array(text.utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        size += max(0, written)
        guard written == data.count else {
            // the category line may be what was lost: write it again next time
            self.category = nil
            return false
        }
        self.category = category
        return true
    }

    /// `* |<level>| <timestamp>| <message>`, the message on one line.
    public static func entry(level: DiagnosticLevel, timestamp: String, message: String) -> String {
        "* |\(level.rawValue)| \(timestamp)| " + LogText.oneLine(message)
    }

    /// What the journal holds, the rotated file first, each read up to
    /// twice `rotationBytes` without following a link.
    public func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return [previousURL, url].compactMap { Self.read($0, limit: 2 * rotationBytes) }.joined()
    }

    /// The journal's last `bytes` — of the rotated file too when the
    /// current one is shorter — from the first whole line in them.
    public func tail(bytes: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        var text = Self.read(url, last: bytes) ?? ""
        let missing = bytes - text.utf8.count
        if missing > 0, let earlier = Self.read(previousURL, last: missing) {
            text = earlier + text
        }
        // what comes before the first line end may be part of a line
        guard text.utf8.count >= bytes, let newline = text.firstIndex(of: "\n") else { return text }
        return String(text[text.index(after: newline)...])
    }

    /// Removes the journals in `folder` past the `keeping` written last,
    /// a journal and its rotated file going together, never `sparing`'s.
    /// One whose current file is gone still counts by its rotated one.
    /// Only regular files count: a link is neither followed nor removed.
    public static func prune(folder: URL, keeping: Int = retainedJournals, sparing: String? = nil) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        // a journal was last written when its current file was; its
        // predecessor only stands in when that file is gone
        var current: [String: Double] = [:]
        var previous: [String: Double] = [:]
        for name in names where name.hasSuffix("." + fileExtension) {
            var metadata = stat()
            guard lstat(folder.appendingPathComponent(name).path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG else { continue }
            let journal = name.hasSuffix(previousSuffix)
                ? String(name.dropLast(previousSuffix.count))
                : String(name.dropLast(fileExtension.count + 1))
            let modified = Double(metadata.st_mtimespec.tv_sec) + Double(metadata.st_mtimespec.tv_nsec) / 1e9
            if name.hasSuffix(previousSuffix) {
                previous[journal] = modified
            } else {
                current[journal] = modified
            }
        }
        let written = previous.merging(current) { _, own in own }
        let journals = written.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
        for (name, _) in journals.dropFirst(max(0, keeping)) where name != sparing {
            unlink(folder.appendingPathComponent(name + "." + fileExtension).path)
            unlink(folder.appendingPathComponent(name + previousSuffix).path)
        }
    }

    /// A formatter fixed to en_US_POSIX and the Gregorian calendar, as
    /// Dog's, so the reader's calendar or clock cannot change a line.
    public static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }

    // MARK: - The file

    /// The file open and ready for `bytes` more: opened again when the one
    /// open is no longer at `url`, rotated first when it would grow past
    /// `rotationBytes`.
    private func prepare(adding bytes: Int) -> Bool {
        if descriptor >= 0, !isStillAtURL() {
            closeFile()
        }
        if descriptor < 0, !openFile() {
            return false
        }
        if size > 0, size + bytes > rotationBytes {
            closeFile()
            // one that cannot be moved aside is written on: a line is
            // worth more than the bound
            _ = rename(url.path, previousURL.path)
            return openFile()
        }
        return true
    }

    private func isStillAtURL() -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, let identity else { return false }
        return metadata.st_dev == identity.device && metadata.st_ino == identity.inode
    }

    private func openFile() -> Bool {
        let opened = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return false }
        var metadata = stat()
        guard fstat(opened, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_uid == geteuid()
        else {
            close(opened)
            return false
        }
        descriptor = opened
        identity = (metadata.st_dev, metadata.st_ino)
        size = Int(metadata.st_size)
        // what the file ended with is not known: the next line names its category
        category = nil
        return true
    }

    private func closeFile() {
        if descriptor >= 0 {
            close(descriptor)
        }
        descriptor = -1
        identity = nil
        size = 0
        category = nil
    }

    private static func read(_ url: URL, limit: Int) -> String? {
        read(url) { size in (0, min(size, limit)) }
    }

    /// The last `bytes` of the file at `url`.
    private static func read(_ url: URL, last bytes: Int) -> String? {
        read(url) { size in (max(0, size - bytes), min(size, bytes)) }
    }

    /// The part of the file at `url` that `span` picks from its size, read
    /// without following a link.
    private static func read(_ url: URL, span: (Int) -> (offset: Int, count: Int)) -> String? {
        let opened = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard opened >= 0 else { return nil }
        defer { close(opened) }
        var metadata = stat()
        guard fstat(opened, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { return nil }
        let (offset, count) = span(Int(metadata.st_size))
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { pread(opened, $0.baseAddress, count, off_t(offset)) }
        guard read >= 0 else { return nil }
        return String(decoding: data.prefix(read), as: UTF8.self)
    }
}
