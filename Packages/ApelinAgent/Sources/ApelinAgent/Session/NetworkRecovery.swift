import Foundation
import KWWKAgent
import KWWKAI
import Network

/// Whether the device has a route to the network, which a model request the
/// network failed waits for (`NetworkRecovery`).
public struct NetworkPath: Sendable {
    /// False only while the system says there is no route; true before it
    /// has said anything.
    public var isSatisfied: @Sendable () -> Bool

    public init(isSatisfied: @escaping @Sendable () -> Bool) {
        self.isSatisfied = isSatisfied
    }

    /// The system's answer: `NWPathMonitor`'s latest, from one monitor a
    /// process, started when a session is first configured.
    public static var system: NetworkPath {
        let monitor = PathMonitor.shared
        return NetworkPath { monitor.isSatisfied }
    }
}

/// `NWPathMonitor` kept running, its latest status readable from any task.
private final class PathMonitor: @unchecked Sendable {
    static let shared = PathMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    @objc private dynamic var unsatisfied = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(unsatisfied: path.status == .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "wiki.qaq.apelin.agent.network-path"))
    }

    /// A path that needs a connection counts: the request may bring it up.
    @objc dynamic var isSatisfied: Bool {
        lock.withLock { !unsatisfied }
    }

    @objc private dynamic func update(unsatisfied: Bool) {
        lock.withLock { self.unsatisfied = unsatisfied }
    }
}

/// Model requests the network failed, answered once it is back.
///
/// kwwk tries a failed request five times within about fifteen seconds
/// (`ProviderRetryPolicy`), and takes a failed TLS handshake for a refused
/// request it never tries again. A phone that changes networks or wakes
/// from sleep is often offline for longer, and the turn ended with "The
/// Internet connection appears to be offline." or "An SSL error has
/// occurred…" for a spell it would have outlived.
///
/// Around the requests a session's agent makes (`AgentOptions.streamFn`),
/// an attempt the network failed before kwwk had anything of the reply:
/// - is handed to kwwk only once `NetworkPath` has a route again, or after
///   `Patience.pathWait`, so kwwk's own retry goes out when it can get
///   through; kwwk still retries it and counts the attempts;
/// - is asked again here when its TLS handshake failed, at most
///   `Patience.secureConnectionRetries` times, after a pause.
///
/// `onWait` hears of each wait first. An attempt that streamed text,
/// thinking or a call is kwwk's alone to take back (`streamRewind`) and ask
/// again, and no tool runs twice: kwwk runs a call only once its message
/// has settled.
enum NetworkRecovery {
    struct Patience: Sendable {
        /// The longest one failure waits for a route, in milliseconds.
        var pathWait: UInt64 = 30000
        /// How often the route is looked at meanwhile.
        var pathPoll: UInt64 = 100
        /// The pause before a failed handshake is asked again.
        var secureConnectionPause: UInt64 = 1000
        var secureConnectionRetries = 2

        static let standard = Patience()
    }

    /// `inner` with the failures above waited on, or asked again.
    static func stream(
        path: NetworkPath,
        patience: Patience = .standard,
        inner: @escaping StreamFn = { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        },
        onWait: @escaping @Sendable () async -> Void,
    ) -> StreamFn {
        { model, context, options in
            let first = try await inner(model, context, options)
            let (stream, out) = AssistantMessageStream.makeStream()
            Task {
                await relay(
                    first,
                    to: out,
                    path: path,
                    patience: patience,
                    cancellation: options?.cancellation,
                    onWait: onWait,
                ) {
                    try await inner(model, context, options)
                }
            }
            return stream
        }
    }

    /// A failure kwwk tries again and a missing route explains: a
    /// connection dropped, refused or timed out.
    static func isLostConnection(_ failure: ProviderFailure) -> Bool {
        failure.isRetryable && [.transport, .timeout].contains(failure.category)
    }

    /// `NSURLErrorSecureConnectionFailed`: a TLS handshake that failed, as
    /// one does while the network changes under it. A certificate that will
    /// not do (-1201 to -1206) is another failure, never asked again.
    static func isFailedHandshake(_ failure: ProviderFailure) -> Bool {
        failure.transportDomain == NSURLErrorDomain && failure.transportCode == NSURLErrorSecureConnectionFailed
    }

    /// Hands each attempt's events to `out` as they come, and its end once
    /// judged: as it came, after a wait for the route, or asked again.
    private static func relay(
        _ first: AssistantMessageStream,
        to out: AssistantMessageStream.Continuation,
        path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
        onWait: @Sendable () async -> Void,
        ask: @Sendable () async throws -> AssistantMessageStream,
    ) async {
        var attempt = first
        // Whether kwwk has had any of the reply: a start alone carries
        // nothing, and the next attempt's start stands in for it.
        var answered = false
        var retries = 0
        while true {
            var ending: AssistantMessageEvent?
            for await event in attempt {
                switch event {
                case .done, .error:
                    ending = event
                case .start:
                    out.push(event)
                default:
                    answered = true
                    out.push(event)
                }
            }
            let final = await attempt.result()
            guard !answered, final.stopReason == .error, let failure = final.providerFailure else {
                finish(out, ending, final)
                return
            }
            let asksAgain = isFailedHandshake(failure) && retries < patience.secureConnectionRetries
            guard asksAgain || (isLostConnection(failure) && !path.isSatisfied()) else {
                finish(out, ending, final)
                return
            }
            await onWait()
            do {
                try await waitForRoute(path, patience: patience, cancellation: cancellation)
                if asksAgain {
                    try await ProviderRetryPolicy.wait(patience.secureConnectionPause, cancellation: cancellation)
                }
            } catch {
                let stopped = stopped(final)
                finish(out, .error(reason: .aborted, error: stopped), stopped)
                return
            }
            guard asksAgain, let next = try? await ask() else {
                finish(out, ending, final)
                return
            }
            attempt = next
            retries += 1
        }
    }

    /// Returns once `path` has a route or `patience.pathWait` has passed;
    /// throws once the request is stopped.
    private static func waitForRoute(
        _ path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
    ) async throws {
        var waited: UInt64 = 0
        while !path.isSatisfied(), waited < patience.pathWait {
            try await ProviderRetryPolicy.wait(patience.pathPoll, cancellation: cancellation)
            waited += patience.pathPoll
        }
    }

    private static func finish(
        _ out: AssistantMessageStream.Continuation,
        _ ending: AssistantMessageEvent?,
        _ final: AssistantMessage,
    ) {
        if let ending {
            out.push(ending)
        }
        out.end(final)
    }

    /// What a provider ends a request stopped before its reply with.
    private static func stopped(_ failed: AssistantMessage) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: failed.api,
            provider: failed.provider,
            model: failed.model,
            stopReason: .aborted,
            errorMessage: "Request was aborted",
        )
    }
}
