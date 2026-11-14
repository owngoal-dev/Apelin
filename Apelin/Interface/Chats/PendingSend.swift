import Foundation

/// A message on its way to the host: its send, and whoever waits for it.
///
/// The send itself cannot be called off: the host answers when it does,
/// and that can be half a minute. The reader's Stop only stops waiting
/// (`withdraw`), so the composer is free again at once; the send goes on to
/// its own end and finds there that it was withdrawn (`ChatRuntime.send`).
@MainActor
final class PendingSend {
    let chat: UUID
    let draft: UUID
    /// The reader stopped it before its send answered.
    @objc dynamic private(set) var isWithdrawn = false
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    init(chat: UUID, draft: UUID) {
        self.chat = chat
        self.draft = draft
    }

    /// The send ended, or was withdrawn, as `outcome`: whoever waits hears
    /// it now, and only the first one counts.
    func end(_ outcome: Result<Void, Error>) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }

    /// Stops waiting for the send, which ends as cancelled for whoever
    /// waits on it.
    @objc dynamic func withdraw() {
        isWithdrawn = true
        end(.failure(CancellationError()))
    }

    /// Returns once the send has ended or been withdrawn, throwing what it
    /// ended with. One caller waits at a time.
    func value() async throws {
        if let outcome {
            return try outcome.get()
        }
        try await withCheckedThrowingContinuation { waiter = $0 }
    }
}
