import ApelinCore
import ApelinDiagnosticsCore
import ApelinProtocol
import Foundation

/// A `logStream` task over any log source: the wire's filter, made the
/// fixed `LogFilter` the readers take, listened to without a seam until the
/// window ends, the limit is reached or the host cancels. Each entry is a
/// `log` event, sent as it arrives; a stream that hit its limit, or whose
/// source lost lines (the system ended its stream early), says `truncated`
/// before it ends.
///
/// Both sources keep one stream open for the whole window (`LiveLogSource`:
/// the root reader's LoggingSupport stream, the mobile worker's icli
/// `SyslogStream`), so nothing falls between two reads.
public final class LogStreamPump: @unchecked Sendable {
    public static let defaultWindow: Double = 30
    public static let windowRange: ClosedRange<Double> = 1 ... 600
    public static let defaultLimit = 1000

    private let source: any LiveLogSource
    private let lock = PthreadLock()
    private var cancelled: Set<TaskID> = []
    private var listeners: [TaskID: LiveLogListener] = [:]

    public init(source: any LiveLogSource) {
        self.source = source
    }

    public func cancel(_ taskID: TaskID) {
        let listener = lock.withLock {
            _ = cancelled.insert(taskID)
            return listeners[taskID]
        }
        listener?.finish()
    }

    /// The reader-side filter, or the wire field that is out of range.
    public static func filter(
        _ wire: ApelinProtocol.LogFilter,
        duration: Double,
        maxEntries: Int,
    ) throws -> ApelinDiagnosticsCore.LogFilter {
        let level: LogLevel
        switch wire.level {
        case nil, "debug"?: level = .debug
        case "info"?: level = .info
        case "default"?, "notice"?: level = .default
        case "error"?: level = .error
        case "fault"?: level = .fault
        case let other?: throw ApelinError(.badRequest, "\(other) is not a log level")
        }
        let filter = ApelinDiagnosticsCore.LogFilter(
            subsystem: wire.subsystem,
            process: wire.process,
            messageContains: wire.messageContains,
            minimumLevel: level,
            duration: duration,
            since: wire.since,
            maxEntries: maxEntries,
        )
        do {
            try filter.validate()
        } catch let error as DiagnosticsError {
            throw ApelinError(.badRequest, "\(error.localizedDescription)")
        }
        return filter
    }

    public static func window(_ wire: ApelinProtocol.LogFilter) throws -> Double {
        let window = wire.windowSeconds ?? defaultWindow
        guard window.isFinite, windowRange.contains(window) else {
            throw ApelinError(
                .badRequest,
                String(format: "windowSeconds must be %g–%g", windowRange.lowerBound, windowRange.upperBound),
            )
        }
        return window
    }

    public static func limit(_ wire: ApelinProtocol.LogFilter) throws -> Int {
        let limit = wire.limit ?? defaultLimit
        let range = ApelinDiagnosticsCore.LogFilter.maxEntriesRange
        guard range.contains(limit) else {
            throw ApelinError(.badRequest, "limit must be \(range.lowerBound)–\(range.upperBound)")
        }
        return limit
    }

    /// Validates the request and listens for a second before answering, so
    /// a source that cannot read at all is a refusal (`denied` when it lacks
    /// the right, so the host can turn to the root reader), not a task that
    /// fails later. The rest runs on its own thread.
    public func start(
        _ request: LogStreamRequest,
        taskID: TaskID,
        emit: @escaping @Sendable (String, JSONValue?) -> Void,
        finish: @escaping @Sendable (TaskState, String?) -> Void,
    ) throws {
        guard let wire = request.filter else { throw ApelinError(.badRequest, "logStream needs a filter") }
        let window = try Self.window(wire)
        let limit = try Self.limit(wire)
        let filter = try Self.filter(
            wire,
            duration: min(window, ApelinDiagnosticsCore.LogFilter.durationRange.upperBound),
            maxEntries: limit,
        )

        let sent = Counter()
        let started = Date()
        let listener: LiveLogListener
        do {
            listener = try source.listen(filter, until: Date().addingTimeInterval(window)) { entry in
                emit("log", Self.payload(entry))
                return sent.increment() < limit
            }
        } catch let error as DiagnosticsError {
            if case let .unavailable(message) = error {
                throw ApelinError(.denied, message)
            }
            throw ApelinError(.unavailable, error.localizedDescription)
        }
        let cancelledAlready = lock.withLock {
            listeners[taskID] = listener
            return cancelled.contains(taskID)
        }
        if cancelledAlready {
            listener.finish()
        }
        // The first second is listened to before the answer, so a caller
        // that causes its event once the stream is accepted finds it heard.
        listener.settle(until: started.addingTimeInterval(min(1, window)))

        Thread.detachNewThread { [self] in
            var reason: (TaskState, String?) = (.succeeded, nil)
            var dropped = false
            do {
                dropped = try listener.wait()
            } catch {
                reason = (.failed, (error as? DiagnosticsError)?.localizedDescription ?? "\(error)")
            }
            let wasCancelled = lock.withLock {
                listeners[taskID] = nil
                return cancelled.contains(taskID)
            }
            if wasCancelled {
                reason = (.cancelled, nil)
            } else if sent.value >= limit {
                emit("truncated", .object(["limit": .number(Double(limit))]))
            } else if dropped {
                emit("truncated", .object(["limit": .number(Double(limit)), "reason": .string("source")]))
            }
            finish(reason.0, reason.1)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = PthreadLock()
        @objc private dynamic var count = 0

        @objc dynamic func increment() -> Int {
            lock.withLock {
                count += 1
                return count
            }
        }

        @objc dynamic var value: Int {
            lock.withLock { count }
        }
    }

    /// `{time, process, pid, subsystem, category, level, message}`.
    public static func payload(_ entry: LogEntry) -> JSONValue {
        var object: [String: JSONValue] = [
            "process": .string(entry.process),
            "pid": .number(Double(entry.pid)),
            "subsystem": .string(entry.subsystem),
            "category": .string(entry.category),
            "level": .string(entry.level.rawValue),
            "message": .string(entry.message),
        ]
        if let date = entry.date {
            object["time"] = .string(ISO8601DateFormatter().string(from: date))
        }
        return .object(object)
    }
}
