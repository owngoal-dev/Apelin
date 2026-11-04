import ApelinProtocol
import Darwin
import Dispatch
import Foundation
@preconcurrency import XPC

/// apelind's launchd job: a thin, authenticated proxy. It authenticates each
/// peer before reading anything it sends, answers `hello` itself, and
/// forwards every other operation, unread, to the session host. It links
/// nothing third-party and holds no work of its own.
final class Proxy {
    private let installRoot: String
    private let queue = DispatchQueue(label: "wiki.qaq.apelind")
    private let authenticator: PeerAuthenticator
    private lazy var ledger = WorkLedger(queue: queue) { [weak self] in self?.exitIdle() }
    private lazy var session = SessionLink(executable: ownExecutable, queue: queue, ledger: ledger)
    private let ownExecutable: String

    init(installRoot: String, ownExecutable: String) {
        self.installRoot = installRoot
        self.ownExecutable = ownExecutable
        authenticator = PeerAuthenticator(installRoot: installRoot)
    }

    @objc dynamic func run() -> Never {
        // The Mach service listener, whose flag and constructor the iOS SDK keeps private.
        let listener = AppProtocol.serviceName.withCString {
            daemonCreateMachServiceListener($0, queue, machServiceListener)
        }
        guard let listener else { exit(EX_UNAVAILABLE) }
        xpc_connection_set_event_handler(listener) { [self] peer in
            guard xpc_get_type(peer) == AppXPC.typeConnection else { return }
            guard authenticator.authenticate(peer) else {
                xpc_connection_cancel(peer)
                return
            }
            accept(peer)
        }
        xpc_connection_activate(listener)
        queue.async { [self] in
            ledger.start()
            // Resume the session host's unfinished tasks on every launch.
            _ = try? session.running()
        }
        dispatchMain()
    }

    @objc dynamic private func accept(_ peer: xpc_connection_t) {
        // The peer's handler runs on the proxy queue, as the ledger does.
        xpc_connection_set_target_queue(peer, queue)
        ledger.connectionOpened()
        var open = true
        xpc_connection_set_event_handler(peer) { [self] message in
            if xpc_get_type(message) == AppXPC.typeError {
                if open {
                    open = false
                    ledger.connectionClosed()
                }
                return
            }
            handle(message, from: peer)
        }
        xpc_connection_activate(peer)
    }

    @objc dynamic private func handle(_ message: xpc_object_t, from peer: xpc_connection_t) {
        guard let reply = xpc_dictionary_create_reply(message) else { return }
        let request: WireRequest
        let descriptors: [OwnedDescriptor]
        switch XPCEnvelope.request(from: message) {
        case let .failure(error):
            XPCEnvelope.fill(reply, with: .failure("", error), descriptors: [])
            xpc_connection_send_message(peer, reply)
            return
        case let .success((decoded, received)):
            request = decoded
            descriptors = received
        }

        if request.operation == .hello {
            XPCEnvelope.fill(
                reply,
                with: .success(request.requestID, HelloResponse(installRoot: installRoot)),
                descriptors: [],
            )
            xpc_connection_send_message(peer, reply)
            return
        }

        ledger.requestBegan()
        Task { [queue, ledger, session] in
            let (answer, returned) = await session.forward(request, descriptors: descriptors)
            queue.async {
                XPCEnvelope.fill(reply, with: answer, descriptors: returned)
                xpc_connection_send_message(peer, reply)
                ledger.requestEnded()
            }
        }
    }

    @objc dynamic private func exitIdle() {
        NSLog("apelind: idle, exiting until launchd starts it again")
        session.shutdown()
        exit(0)
    }
}
