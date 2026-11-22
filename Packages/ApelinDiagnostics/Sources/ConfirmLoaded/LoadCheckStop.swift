import ApelinDiagnosticsCore
import Foundation

/// Stops a load check from another thread: its listen ends at once, its
/// trigger is not run if it has not run yet, and `ConfirmLoaded.run`
/// answers with what it had. Told before the listen has begun, it ends the
/// listen as soon as it does. A listen of minutes is stopped this way when
/// the caller that waited on it goes (the agent's Stop, the host's cancel).
public final class LoadCheckStop: @unchecked Sendable {
    private let lock = NSLock()
    @objc private dynamic var stopped = false
    private var listener: LiveLogListener?

    public init() {}

    @objc public dynamic func stop() {
        lock.lock()
        stopped = true
        let listener = listener
        lock.unlock()
        listener?.finish()
    }

    @objc public dynamic var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// The listen to end on `stop()`; ended now if that came first.
    func watch(_ listener: LiveLogListener) {
        lock.lock()
        self.listener = listener
        let stopped = stopped
        lock.unlock()
        if stopped {
            listener.finish()
        }
    }
}
