import ApelinCore
import ApelinProtocol
import Dispatch
import Foundation
@preconcurrency import XPC

@_silgen_name("xpc_connection_create_mach_service")
private func appCreateMachServiceConnection(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

/// The app's connection to apelind, and the `ApelinTransport` under
/// `ApelinService.app`.
///
/// Hello first. A miss means launchd has not started the daemon yet, so it is
/// retried; only after `gracePeriod`, measured from the first miss, does the
/// app fall back to running without it. Each hello has its own bound,
/// because a daemon launchd cannot start leaves the message queued with no
/// error, and each attempt's reply and timeout share a one-shot claim.
///
/// After a hello answers, the connection stays open: a connected app is work
/// that keeps apelind up. If it drops (apelind restarted, idle exit), the
/// next call says hello again on a new connection. Calls made while the app
/// runs without the backend fail with `.backendUnavailable`; each one first
/// tries a single hello, so a daemon started later is found.
final class DaemonClient: ApelinTransport, @unchecked Sendable {
    static let shared = DaemonClient()

    private static let gracePeriod: TimeInterval = 10
    private static let helloTimeout: DispatchTimeInterval = .seconds(5)
    private static let retryDelay: DispatchTimeInterval = .seconds(1)
    /// A call's bound beyond the attach's own wait.
    private static let callMargin: TimeInterval = 30

    private enum State {
        case unknown
        case connected(xpc_connection_t)
        case unprivileged
    }

    private let queue = DispatchQueue(label: "wiki.qaq.apelin.client")
    @objc private dynamic var firstMiss: Date?
    private var state = State.unknown
    private var helloWaiters: [(xpc_connection_t?) -> Void] = []

    // MARK: ApelinTransport

    func call(_ request: WireRequest, descriptors: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        guard let connection = await connection() else {
            throw ApelinError(.backendUnavailable, "Apelin’s background service is not running")
        }
        let wait = (try? JSONCoding.decode(WaitField.self, from: request.payload))?.waitMilliseconds ?? 0
        let bound = Self.callMargin + Double(wait) / 1000
        let message = XPCEnvelope.message(for: request, descriptors: descriptors)
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once()
            xpc_connection_send_message_with_reply(connection, message, queue) { reply in
                guard once.claim() else { return }
                if xpc_get_type(reply) == AppXPC.typeError {
                    self.dropped(connection)
                    continuation.resume(
                        throwing: ApelinError(
                            .unavailable,
                            String(localized: "The connection to Apelin’s background service closed. Try again."),
                        ),
                    )
                    return
                }
                continuation.resume(returning: XPCEnvelope.reply(from: reply, requestID: request.requestID))
            }
            queue.asyncAfter(deadline: .now() + bound) {
                guard once.claim() else { return }
                let waited = Duration.seconds(Int(bound)).formatted(.units(allowed: [.seconds], width: .wide))
                continuation.resume(
                    throwing: ApelinError(
                        .timeout,
                        String(localized: "Apelin’s background service did not answer within \(waited). Try again."),
                    ),
                )
            }
        }
    }

    // MARK: Connection

    private func connection() async -> xpc_connection_t? {
        await withCheckedContinuation { continuation in
            queue.async {
                switch self.state {
                case let .connected(connection):
                    continuation.resume(returning: connection)
                case .unprivileged:
                    // One fresh attempt, no grace: the daemon may have started since.
                    self.state = .unknown
                    self.firstMiss = Date().addingTimeInterval(-Self.gracePeriod)
                    fallthrough
                case .unknown:
                    self.ensureHello { continuation.resume(returning: $0) }
                }
            }
        }
    }

    /// On `queue`. Joins the hello in progress, or starts one.
    @objc private dynamic func ensureHello(_ completion: @escaping (xpc_connection_t?) -> Void) {
        helloWaiters.append(completion)
        guard helloWaiters.count == 1 else { return }
        attempt()
    }

    @objc private dynamic func finishHello(_ connection: xpc_connection_t?) {
        let waiters = helloWaiters
        helloWaiters = []
        waiters.forEach { $0(connection) }
    }

    @objc private dynamic func attempt() {
        guard let connection = AppProtocol.serviceName.withCString({
            appCreateMachServiceConnection($0, queue, 0)
        }) else {
            missed()
            return
        }
        xpc_connection_set_event_handler(connection) { [weak self] event in
            if xpc_get_type(event) == AppXPC.typeError {
                self?.dropped(connection)
            }
        }
        xpc_connection_activate(connection)

        let request = try! WireRequest(HelloRequest())
        let once = Once()
        xpc_connection_send_message_with_reply(
            connection,
            XPCEnvelope.message(for: request, descriptors: []),
            queue,
        ) { reply in
            guard once.claim() else { return }
            let (wireReply, _) = XPCEnvelope.reply(from: reply, requestID: request.requestID)
            if case let .success(payload) = wireReply.result,
               (try? JSONCoding.decode(HelloResponse.self, from: payload)) != nil
            {
                self.firstMiss = nil
                self.state = .connected(connection)
                self.finishHello(connection)
            } else {
                xpc_connection_cancel(connection)
                self.missed()
            }
        }
        queue.asyncAfter(deadline: .now() + Self.helloTimeout) {
            guard once.claim() else { return }
            xpc_connection_cancel(connection)
            self.missed()
        }
    }

    @objc private dynamic func missed() {
        let first = firstMiss ?? Date()
        firstMiss = first
        guard Date().timeIntervalSince(first) < Self.gracePeriod else {
            state = .unprivileged
            finishHello(nil)
            return
        }
        queue.asyncAfter(deadline: .now() + Self.retryDelay) { self.attempt() }
    }

    /// On `queue`. The connection is gone; the next call says hello again.
    @objc private dynamic func dropped(_ connection: xpc_connection_t) {
        dispatchPrecondition(condition: .onQueue(queue))
        if case let .connected(current) = state, current === connection {
            xpc_connection_cancel(connection)
            state = .unknown
        }
    }
}

/// Reads an attach's wait from any request without knowing its type.
private struct WaitField: Decodable {
    var waitMilliseconds: Int?
}

private final class Once: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc private dynamic var claimed = false

    @objc dynamic func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
