import Foundation

/// An operation given so long and no longer.
enum Deadline {
    /// The operation did not end within its limit.
    struct Exceeded: Error {}

    /// `operation`'s result, or `Exceeded` once `limit` has passed. The
    /// operation is cancelled then and no longer waited for, so one that
    /// does not answer its cancellation cannot hold the caller either.
    static func within<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, contenders: [
                    Task {
                        do {
                            try await race.finish(.success(operation()))
                        } catch {
                            race.finish(.failure(error))
                        }
                    },
                    Task {
                        guard await (try? Task.sleep(for: limit)) != nil else { return }
                        race.finish(.failure(Exceeded()))
                    },
                ])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// The first result in wins: it answers the caller and stops the rest.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var contenders: [Task<Void, Never>] = []
        private var early: Result<T, any Error>?

        func start(_ continuation: CheckedContinuation<T, any Error>, contenders: [Task<Void, Never>]) {
            let early = lock.withLock {
                self.continuation = continuation
                self.contenders = contenders
                return self.early
            }
            // a contender, or the caller's cancellation, was first
            if let early {
                finish(early)
            }
        }

        func finish(_ result: Result<T, any Error>) {
            let (continuation, contenders) = lock.withLock {
                guard let continuation = self.continuation else {
                    early = early ?? result
                    return (CheckedContinuation<T, any Error>?.none, [Task<Void, Never>]())
                }
                self.continuation = nil
                defer { self.contenders = [] }
                return (continuation, self.contenders)
            }
            guard let continuation else { return }
            continuation.resume(with: result)
            contenders.forEach { $0.cancel() }
        }
    }
}
