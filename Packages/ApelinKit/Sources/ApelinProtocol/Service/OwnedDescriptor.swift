import Darwin
import Foundation

/// A file descriptor this process owns and closes once, when the last
/// reference goes or `take()` hands it on.
public final class OwnedDescriptor: @unchecked Sendable {
    @objc private dynamic var descriptor: Int32
    private let lock = PthreadLock()

    /// Takes ownership of `descriptor`.
    public init(adopting descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Duplicates `descriptor`; the caller keeps its own.
    public static func duplicating(_ descriptor: Int32) -> OwnedDescriptor? {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        return copy >= 0 ? OwnedDescriptor(adopting: copy) : nil
    }

    /// The descriptor, still owned here; -1 once taken or closed.
    @objc public dynamic var rawValue: Int32 {
        lock.withLock { descriptor }
    }

    /// Hands the descriptor on: the caller closes it from now on.
    @objc public dynamic func take() -> Int32 {
        lock.withLock {
            let value = descriptor
            descriptor = -1
            return value
        }
    }

    @objc public dynamic func close() {
        let value = take()
        if value >= 0 {
            Darwin.close(value)
        }
    }

    deinit {
        if descriptor >= 0 {
            Darwin.close(descriptor)
        }
    }
}

/// A pthread mutex on its own allocation, so its address never moves.
public final class PthreadLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        mutex = .allocate(capacity: 1)
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}
