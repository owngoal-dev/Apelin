import Dispatch
import Foundation

/// Whether apelind has work, and when it may exit.
///
/// apelind is on demand: launchd starts it for a message to its Mach service
/// and never keeps it alive. It stays up while anything is open — a
/// connected app, a request in flight, or work the session host reports
/// (a task, a live worker) — and exits only once all of them have been gone
/// for `idleGrace`. The grace is longer than launchd's ten-second respawn
/// throttle, so an idle exit is never followed by a throttled relaunch, and
/// the session host's task records are on disk before it reports idle.
///
/// Every method runs on `queue`.
final class WorkLedger: @unchecked Sendable {
    private let queue: DispatchQueue
    private let idleGrace: DispatchTimeInterval = .seconds(30)
    private let onIdle: () -> Void
    @objc dynamic private var connections = 0
    @objc dynamic private var requests = 0
    @objc dynamic private(set) var sessionBusy = false
    private var idleTimer: DispatchWorkItem?

    init(queue: DispatchQueue, onIdle: @escaping () -> Void) {
        self.queue = queue
        self.onIdle = onIdle
    }

    @objc dynamic private var isIdle: Bool {
        connections == 0 && requests == 0 && !sessionBusy
    }

    /// Starts the clock: a launch that never sees a client still exits.
    @objc dynamic func start() {
        reevaluate()
    }

    @objc dynamic func connectionOpened() {
        connections += 1
        reevaluate()
    }

    @objc dynamic func connectionClosed() {
        connections -= 1
        reevaluate()
    }

    @objc dynamic func requestBegan() {
        requests += 1
        reevaluate()
    }

    @objc dynamic func requestEnded() {
        requests -= 1
        reevaluate()
    }

    @objc dynamic func sessionReported(busy: Bool) {
        sessionBusy = busy
        reevaluate()
    }

    @objc dynamic private func reevaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleTimer?.cancel()
        idleTimer = nil
        guard isIdle else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            onIdle()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + idleGrace, execute: timer)
    }
}
