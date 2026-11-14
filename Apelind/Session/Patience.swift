import Foundation

/// An answer waited for so long and no longer.
enum Patience {
    /// `operation`'s answer, or nil once `seconds` have passed. The
    /// operation goes on then, its answer unread: one that never answers
    /// cannot hold the caller.
    static func answer<T: Sendable>(
        within seconds: Double,
        of operation: @escaping @Sendable () async -> T,
    ) async -> T? {
        let slot = Slot<T?>()
        return await withCheckedContinuation { continuation in
            slot.wait(continuation)
            Task { await slot.fill(operation()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                slot.fill(nil)
            }
        }
    }

    /// Holds the first value it is given for whoever waits.
    private final class Slot<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        func wait(_ continuation: CheckedContinuation<T, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func fill(_ value: T) {
            let waiting = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
    }
}
