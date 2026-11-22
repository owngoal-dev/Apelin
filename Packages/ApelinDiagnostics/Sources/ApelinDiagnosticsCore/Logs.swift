import Foundation

/// Unified log levels, in increasing severity. `default` is os_log's own
/// name for the level `os_log()` writes at.
public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug, info, `default`, error, fault

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .default: 2
        case .error: 3
        case .fault: 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// The unified log's `os_log_type_t` values: 0x00 default, 0x01 info,
    /// 0x02 debug, 0x10 error, 0x11 fault. Anything else reads as default.
    public init(logType: UInt8) {
        switch logType {
        case 0x01: self = .info
        case 0x02: self = .debug
        case 0x10: self = .error
        case 0x11: self = .fault
        default: self = .default
        }
    }

    /// icli's spelling: `notice` for the default level.
    public init(icliName: String) {
        switch icliName {
        case "debug": self = .debug
        case "info": self = .info
        case "error": self = .error
        case "fault": self = .fault
        default: self = .default
        }
    }
}

/// One unified log line, as both readers return it.
public struct LogEntry: Codable, Hashable, Sendable {
    public var date: Date?
    public var process: String
    public var pid: Int32
    public var subsystem: String
    public var category: String
    public var level: LogLevel
    public var message: String

    public init(
        date: Date?,
        process: String,
        pid: Int32,
        subsystem: String,
        category: String,
        level: LogLevel,
        message: String,
    ) {
        self.date = date
        self.process = process
        self.pid = pid
        self.subsystem = subsystem
        self.category = category
        self.level = level
        self.message = message
    }
}

/// The fixed shape of every log request: no free-form predicate, nothing that
/// names a file or a program. A reader takes this and nothing else.
///
/// The unified log is read live: `duration` is how long to listen, starting
/// when the read starts. `since` drops entries stamped earlier, for a caller
/// that started listening before the moment it cares about.
public struct LogFilter: Codable, Hashable, Sendable {
    /// Keeps this subsystem and its dotted children (`a.b` keeps `a.b.c`).
    public var subsystem: String?
    /// Exact process name, compared case-insensitively.
    public var process: String?
    /// Case-sensitive substring of the message: a tweak's marker.
    public var messageContains: String?
    public var minimumLevel: LogLevel
    /// Seconds to listen, 0.1–60.
    public var duration: TimeInterval
    public var since: Date?
    /// At most this many entries come back, 1–5000. Entries past it are
    /// counted as truncation, not kept.
    public var maxEntries: Int

    public static let durationRange: ClosedRange<TimeInterval> = 0.1 ... 60
    public static let maxEntriesRange: ClosedRange<Int> = 1 ... 5000
    /// Bound on every string field, in UTF-8 bytes.
    public static let maxFieldBytes = 256

    public init(
        subsystem: String? = nil,
        process: String? = nil,
        messageContains: String? = nil,
        minimumLevel: LogLevel = .debug,
        duration: TimeInterval = 3,
        since: Date? = nil,
        maxEntries: Int = 500,
    ) {
        self.subsystem = subsystem
        self.process = process
        self.messageContains = messageContains
        self.minimumLevel = minimumLevel
        self.duration = duration
        self.since = since
        self.maxEntries = maxEntries
    }

    /// Throws `DiagnosticsError.invalidParameter` naming the first field out
    /// of range. A reader calls this before it opens anything.
    public func validate() throws {
        guard duration.isFinite, Self.durationRange.contains(duration) else {
            let range = Self.durationRange
            throw DiagnosticsError.invalidParameter(
                String(format: "duration must be %g–%g seconds", range.lowerBound, range.upperBound),
            )
        }
        guard Self.maxEntriesRange.contains(maxEntries) else {
            throw DiagnosticsError.invalidParameter("maxEntries must be \(Self.maxEntriesRange.lowerBound)–\(Self.maxEntriesRange.upperBound)")
        }
        try validateMatchFields()
    }

    /// `validate` without `duration` and `maxEntries`: what a `LiveLogSource`
    /// checks, since its window and cap are its own.
    public func validateMatchFields() throws {
        for (name, value) in [("subsystem", subsystem), ("process", process), ("messageContains", messageContains)] {
            guard let value else { continue }
            guard !value.isEmpty, value.utf8.count <= Self.maxFieldBytes, !value.contains("\0") else {
                throw DiagnosticsError.invalidParameter("\(name) must be 1–\(Self.maxFieldBytes) bytes with no NUL")
            }
        }
    }

    /// Whether an entry passes every field. `since` compares against the
    /// entry's own date; an undated entry passes it.
    public func matches(_ entry: LogEntry) -> Bool {
        if let subsystem, entry.subsystem != subsystem, !entry.subsystem.hasPrefix(subsystem + ".") {
            return false
        }
        if let process, entry.process.caseInsensitiveCompare(process) != .orderedSame {
            return false
        }
        if let messageContains, !entry.message.contains(messageContains) {
            return false
        }
        if entry.level < minimumLevel {
            return false
        }
        if let since, let date = entry.date, date < since {
            return false
        }
        return true
    }
}

public struct LogReadResult: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// icli's `captureSyslog`, in the mobile diagnostics worker.
        case icli
        /// `ApelinLogReader`'s own LoggingSupport live stream.
        case liveStream
    }

    public var entries: [LogEntry]
    /// More entries matched than `maxEntries` let through, or the source
    /// itself stopped at its own cap before the filter could see everything.
    public var truncated: Bool
    public var source: Source

    public init(entries: [LogEntry], truncated: Bool, source: Source) {
        self.entries = entries
        self.truncated = truncated
        self.source = source
    }
}

/// Anything that can answer a `LogFilter` in one bounded read: the
/// icli-backed diagnostics worker and the root log reader both do.
/// `ConfirmLoaded` listens through a `LiveLogSource` instead, so its window
/// can outlast a bounded read and end as soon as the marker is heard.
public protocol LogEvidenceSource: Sendable {
    func readLogs(_ filter: LogFilter) throws -> LogReadResult
}
