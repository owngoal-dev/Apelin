import ApelinProtocol
import Darwin
import Foundation

/// The proxy's end of the session host: `apelind-session`, the same
/// executable started in session mode with a socketpair as descriptor 3.
/// It is a child launchd never sized, so what must outlive the app with
/// unbounded memory lives there, not in the launchd job. It is started on
/// the proxy's launch and again on the next request after it exits — or at
/// once when it exits while it still reported work, so the tasks it left
/// resume without waiting for the app.
final class SessionLink: @unchecked Sendable {
    static let sessionArgument = "--session"

    private let executable: String
    private let queue: DispatchQueue
    private let ledger: WorkLedger
    private let lock = PthreadLock()
    private var channel: WorkerChannel?
    @objc dynamic private var lastStart: Date?

    init(executable: String, queue: DispatchQueue, ledger: WorkLedger) {
        self.executable = executable
        self.queue = queue
        self.ledger = ledger
    }

    /// Forwards one request; the session host answers it.
    func forward(_ request: WireRequest, descriptors: [OwnedDescriptor]) async -> (WireReply, [OwnedDescriptor]) {
        do {
            let channel = try running()
            return try await channel.call(request, descriptors: descriptors)
        } catch let error as ApelinError {
            return (.failure(request.requestID, error), [])
        } catch {
            return (
                .failure(request.requestID, ApelinError(
                    .unavailable,
                    "Apelin's background service is unavailable. \(error)",
                )),
                [],
            )
        }
    }

    /// Starts the session host if it is not running.
    func running() throws -> WorkerChannel {
        try lock.withLock {
            if let channel, !channel.isClosed {
                return channel
            }
            // A host that keeps dying is not restarted in a tight loop.
            if let lastStart, Date().timeIntervalSince(lastStart) < 1 {
                throw ApelinError(.unavailable, "Apelin's background service stopped. Try again in a moment.")
            }
            lastStart = Date()
            let (local, remote) = try WorkerChannel.makePair()
            defer { close(remote) }
            let channel = WorkerChannel(adopting: local)
            channel.onControl { [weak self] frame in
                guard let self, frame.header.name == WorkerControl.work,
                      let report = try? JSONDecoder().decode(WorkReport.self, from: frame.body) else { return }
                queue.async { self.ledger.sessionReported(busy: !report.isIdle) }
            }
            channel.onClose { [weak self] in
                guard let self else { return }
                // A host that went away with work (killed, crashed) left task
                // records to resume: start the next one past the restart
                // throttle. Its own report keeps apelind up from there.
                queue.async {
                    let diedBusy = self.ledger.sessionBusy
                    self.ledger.sessionReported(busy: false)
                    if diedBusy {
                        self.queue.asyncAfter(deadline: .now() + 1.5) { _ = try? self.running() }
                    }
                }
            }
            channel.start()
            let pid = try spawnProcess(
                path: executable,
                arguments: ["apelind-session", Self.sessionArgument],
                environment: ["DISABLE_TWEAKS=1", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"],
                channel: remote,
                identity: nil,
            )
            reapWhenExited(pid, queue: queue) { status in
                NSLog("apelind: the session host exited (status %d)", status)
            }
            self.channel = channel
            return channel
        }
    }

    /// Asks the session host to persist and exit, and waits a moment for it.
    @objc dynamic func shutdown() {
        let channel = lock.withLock { self.channel }
        guard let channel, !channel.isClosed else { return }
        try? channel.sendControl(WorkerControl.shutdown)
        let deadline = Date().addingTimeInterval(3)
        while !channel.isClosed, Date() < deadline {
            usleep(50000)
        }
        channel.close()
    }
}
