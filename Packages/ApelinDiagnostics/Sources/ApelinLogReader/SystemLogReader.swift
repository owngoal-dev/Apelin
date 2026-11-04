import ApelinDiagnosticsCore
import ApelinLogReaderSPI
import Foundation

/// The root log helper's core: one bounded read of the live unified log
/// through a fixed `LogFilter`. System libraries only — Foundation, libobjc
/// and LoggingSupport resolved at run time; no icli, nothing third-party.
///
/// Why not `OSLogStore`: on iOS its only scope is `.currentProcessIdentifier`
/// (`OSLogStore.local()` and `.system` are macOS-only), so it cannot read
/// another process's lines. The live stream can, given diagnosticd's consent
/// (root, or the logging entitlements; see the README). It sees only what is
/// logged while it listens: the caller starts a read, then causes the event.
/// `listen` keeps one stream open for a whole window, so a long stream has
/// no seam where lines could fall between two reads.
public struct SystemLogReader: LogEvidenceSource, LiveLogSource {
    public init() {}

    public func listen(
        _ filter: LogFilter,
        until deadline: Date,
        deliver: @escaping @Sendable (LogEntry) -> Bool,
    ) throws -> LiveLogListener {
        try filter.validateMatchFields()
        let listener = LiveLogListener(deadline: deadline, deliver: deliver)
        var failure: NSString?
        let stream = ApelinLogLiveStreamOpen({ date, process, pid, subsystem, category, type, message in
            let entry = LogEntry(
                date: date,
                process: process,
                pid: pid,
                subsystem: subsystem,
                category: category,
                level: LogLevel(logType: type),
                message: message,
            )
            guard filter.matches(entry) else { return true }
            return listener.offer(entry)
        }, &failure)
        guard let stream else {
            throw DiagnosticsError.unavailable(failure as String? ?? "The unified log live stream is not available.")
        }
        // Closed off this thread: the end can come from inside the stream's
        // own handler (the receiver wanted no more), which holds the gate
        // the close takes.
        let open = OpenStream(stream)
        listener.onEnd { DispatchQueue.global().async { ApelinLogLiveStreamClose(open.stream) } }
        return listener
    }

    public func readLogs(_ filter: LogFilter) throws -> LogReadResult {
        try filter.validate()
        let collector = Collector(filter: filter)
        var failure: NSString?
        let ran = ApelinLogLiveStreamRun(filter.duration, { date, process, pid, subsystem, category, type, message in
            collector.offer(LogEntry(
                date: date,
                process: process,
                pid: pid,
                subsystem: subsystem,
                category: category,
                level: LogLevel(logType: type),
                message: message,
            ))
        }, &failure)
        guard ran else {
            throw DiagnosticsError.unavailable(failure as String? ?? "The unified log live stream is not available.")
        }
        return collector.result
    }

    private final class OpenStream: @unchecked Sendable {
        let stream: Any
        init(_ stream: Any) {
            self.stream = stream
        }
    }

    /// Called serially by the stream; the lock is for reading the result
    /// after the stream is gone, from another thread.
    private final class Collector: @unchecked Sendable {
        private let filter: LogFilter
        private let lock = NSLock()
        private var entries = [LogEntry]()
        @objc private dynamic var truncated = false

        init(filter: LogFilter) {
            self.filter = filter
        }

        /// Returns false once one more entry than the cap has matched: that
        /// one proves truncation, and listening longer cannot change the result.
        func offer(_ entry: LogEntry) -> Bool {
            guard filter.matches(entry) else { return true }
            lock.lock()
            defer { lock.unlock() }
            guard entries.count < filter.maxEntries else {
                truncated = true
                return false
            }
            entries.append(entry)
            return true
        }

        var result: LogReadResult {
            lock.lock()
            defer { lock.unlock() }
            return LogReadResult(entries: entries, truncated: truncated, source: .liveStream)
        }
    }
}
