import ApelinCore
import ApelinProtocol
import Foundation

/// Set once, read from anywhere: whether a task was asked to stop.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc private dynamic var cancelled = false

    public init() {}

    @objc public dynamic var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    @objc public dynamic func cancel() {
        lock.withLock { cancelled = true }
    }
}

/// How a running environment task reports: events go to the host (or to a
/// test's closure), and cancellation is asked here and through Swift's own
/// task cancellation, which the toolchain package checks.
public struct TaskReporter: Sendable {
    private let emitter: @Sendable (String, JSONValue?) -> Void
    public let cancellation: CancellationFlag

    public init(
        cancellation: CancellationFlag = CancellationFlag(),
        emit: @escaping @Sendable (String, JSONValue?) -> Void,
    ) {
        emitter = emit
        self.cancellation = cancellation
    }

    /// A reporter that drops everything; for calls made outside a task.
    public static let silent = TaskReporter { _, _ in }

    public var isCancelled: Bool {
        cancellation.isCancelled || Task.isCancelled
    }

    public func checkCancelled() throws {
        if isCancelled {
            throw ApelinError(.cancelled, "cancelled")
        }
    }

    public func emit(_ kind: String, _ payload: JSONValue? = nil) {
        emitter(kind, payload)
    }

    public func emit(_ kind: String, encoding value: some Encodable) {
        emitter(kind, try? JSONValue(encoding: value))
    }

    public func stage(_ stage: String) {
        emit("stage", .object(["stage": .string(stage)]))
    }

    public func progress(_ stage: String, completed: Int64, total: Int64? = nil, detail: String? = nil) {
        var payload: [String: JSONValue] = ["stage": .string(stage), "completed": .number(Double(completed))]
        if let total {
            payload["total"] = .number(Double(total))
        }
        if let detail {
            payload["detail"] = .string(detail)
        }
        emit("progress", .object(payload))
    }

    public func warning(_ message: String) {
        emit("warning", .object(["message": .string(message)]))
    }
}

/// Throttles progress events to a few a second, plus the last one.
final class ProgressThrottle: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc private dynamic var last = Date.distantPast
    private let interval: TimeInterval

    init(interval: TimeInterval = 0.25) {
        self.interval = interval
    }

    @objc dynamic func shouldEmit(force: Bool = false) -> Bool {
        lock.withLock {
            let now = Date()
            guard force || now.timeIntervalSince(last) >= interval else { return false }
            last = now
            return true
        }
    }
}
