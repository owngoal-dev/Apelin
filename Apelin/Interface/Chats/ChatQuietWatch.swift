import Foundation

/// Wakes the conversation page once, when the turn it shows will have gone
/// quiet long enough for a running summary to stand in under its reply
/// (`ChatTranscript.quietDeadline`). The page then builds its rows again
/// from the same events; an event before then moves the deadline, and
/// nothing polls.
@MainActor
final class ChatQuietWatch {
    private var pending: DispatchWorkItem?

    /// Runs `action` at `deadline`, in place of whatever was set before;
    /// nil only cancels.
    @objc dynamic func wake(at deadline: Date?, _ action: @escaping () -> Void) {
        pending?.cancel()
        pending = nil
        guard let deadline else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            action()
        }
        pending = item
        // a moment past it, so the rows built then are past it too
        let wait = max(0, deadline.timeIntervalSinceNow) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }
}
