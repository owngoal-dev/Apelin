import Foundation

/// A reader that listens for a whole window at once, so a stream of any
/// length is one read with no seam in it. The root reader keeps LoggingSupport's
/// live stream open (`SystemLogReader`); the mobile worker keeps one icli
/// `SyslogStream` open (`Diagnostics`).
public protocol LiveLogSource: Sendable {
    /// Starts listening through `filter` (its `duration` and `maxEntries` are
    /// not used) and calls `deliver`, serially and in arrival order, with every
    /// matching entry until `deadline`, until `deliver` answers false, or until
    /// the listener is stopped. Throws `DiagnosticsError` when it cannot listen
    /// at all, before anything is delivered.
    func listen(
        _ filter: LogFilter,
        until deadline: Date,
        deliver: @escaping @Sendable (LogEntry) -> Bool,
    ) throws -> LiveLogListener
}

/// One listen in progress. `deliver` is called under its lock, so once
/// `stop()` or `wait()` has returned no further entry arrives.
public final class LiveLogListener: @unchecked Sendable {
    private let condition = NSCondition()
    private let deliver: @Sendable (LogEntry) -> Bool
    private let deadline: Date
    @objc private dynamic var done = false
    private var failure: DiagnosticsError?
    @objc private dynamic var dropped = false
    @objc private dynamic var onEnd: (() -> Void)?

    /// `deadline` ends the listen by itself.
    public init(deadline: Date, deliver: @escaping @Sendable (LogEntry) -> Bool) {
        self.deadline = deadline
        self.deliver = deliver
    }

    /// Run once when the listen ends however it ends, outside the lock: the
    /// source closes what it opened here.
    @objc public dynamic func onEnd(_ body: @escaping () -> Void) {
        condition.lock()
        let already = done
        if !already {
            onEnd = body
        }
        condition.unlock()
        if already {
            body()
        }
    }

    /// Hands one entry on. False once the listen is over, or when the
    /// receiver wants no more — which ends it.
    @discardableResult
    public func offer(_ entry: LogEntry) -> Bool {
        condition.lock()
        guard !done else {
            condition.unlock()
            return false
        }
        let more = deliver(entry)
        condition.unlock()
        if !more {
            finish()
        }
        return more
    }

    /// The source lost entries (the system ended its stream before the
    /// window did): the stream is no longer complete, and says so when it ends.
    @objc public dynamic func markDropped() {
        condition.lock()
        dropped = true
        condition.unlock()
    }

    /// Ends the listen now: nothing more is delivered. `error` is a read that
    /// failed after it began.
    public func finish(_ error: DiagnosticsError? = nil) {
        condition.lock()
        guard !done else {
            condition.unlock()
            return
        }
        done = true
        failure = error
        let end = onEnd
        onEnd = nil
        condition.broadcast()
        condition.unlock()
        end?()
    }

    /// Blocks until the listen is over or `date` passes, whichever is first.
    @objc public dynamic func settle(until date: Date) {
        condition.lock()
        while !done, condition.wait(until: date) {}
        condition.unlock()
    }

    /// Blocks until the listen is over. Answers whether the source dropped
    /// entries; throws the read that failed.
    @discardableResult
    public func wait() throws -> Bool {
        condition.lock()
        while !done {
            if !condition.wait(until: deadline), Date() >= deadline {
                condition.unlock()
                finish()
                condition.lock()
            }
        }
        let failure = failure
        let dropped = dropped
        condition.unlock()
        if let failure {
            throw failure
        }
        return dropped
    }
}
