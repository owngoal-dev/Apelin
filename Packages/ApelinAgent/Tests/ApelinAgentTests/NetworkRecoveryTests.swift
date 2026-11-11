@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("A model request the network failed")
struct NetworkRecoveryTests {
    /// One attempt as a provider streams it: its events, then its end.
    struct Attempt {
        var events: [AssistantMessageEvent]
        var final: AssistantMessage
    }

    /// The requests a scripted provider answers, the next attempt each.
    final class Script: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Attempt]
        private var made = 0

        init(_ attempts: [Attempt]) {
            self.attempts = attempts
        }

        var calls: Int {
            lock.withLock { made }
        }

        var stream: StreamFn {
            { _, _, _ in
                let attempt = self.lock.withLock {
                    self.made += 1
                    return self.attempts.removeFirst()
                }
                let (stream, out) = AssistantMessageStream.makeStream()
                for event in attempt.events {
                    out.push(event)
                }
                out.end(attempt.final)
                return stream
            }
        }
    }

    /// A route that comes back once it has been looked at `missing` times.
    final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var looks = 0
        private let missing: Int

        init(missing: Int) {
            self.missing = missing
        }

        var checks: Int {
            lock.withLock { looks }
        }

        var path: NetworkPath {
            NetworkPath {
                self.lock.withLock {
                    self.looks += 1
                    return self.looks > self.missing
                }
            }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        var count: Int {
            lock.withLock { value }
        }

        func add() {
            lock.withLock { value += 1 }
        }
    }

    private static let model = Model(id: "test-1", api: "test", provider: "test")
    private static let quick = NetworkRecovery.Patience(
        pathWait: 5000,
        pathPoll: 10,
        secureConnectionPause: 10,
        secureConnectionRetries: 2,
    )

    private static func message(_ content: [AssistantBlock], stopReason: StopReason = .stop) -> AssistantMessage {
        AssistantMessage(content: content, api: "test", provider: "test", model: model.id, stopReason: stopReason)
    }

    /// A request that failed with NSURLErrorDomain `code`, after `text`.
    private static func failure(_ code: Int, after text: String? = nil) -> Attempt {
        var events: [AssistantMessageEvent] = [.start(partial: message([]))]
        var content: [AssistantBlock] = []
        if let text {
            content = [.text(TextContent(text: text))]
            events.append(.textDelta(contentIndex: 0, delta: text, partial: message(content)))
        }
        var failed = message(content, stopReason: .error)
        failed.errorMessage = "Error Domain=NSURLErrorDomain Code=\(code)"
        failed.failure = ProviderFailure(message: "failed", transportDomain: NSURLErrorDomain, transportCode: code)
        events.append(.error(reason: .error, error: failed))
        return Attempt(events: events, final: failed)
    }

    private static func reply(_ text: String) -> Attempt {
        let done = message([.text(TextContent(text: text))])
        return Attempt(events: [
            .start(partial: message([])),
            .textDelta(contentIndex: 0, delta: text, partial: done),
            .done(reason: .stop, message: done),
        ], final: done)
    }

    /// The events the wrapped request streamed, and its end.
    private static func run(
        _ script: Script,
        path: NetworkPath = NetworkPath { true },
        patience: NetworkRecovery.Patience = quick,
        cancellation: CancellationHandle? = nil,
        waits: Counter,
    ) async throws -> (events: [String], final: AssistantMessage) {
        let stream = NetworkRecovery.stream(path: path, patience: patience, inner: script.stream) { waits.add() }
        let response = try await stream(model, Context(), StreamOptions(cancellation: cancellation))
        var events: [String] = []
        for await event in response {
            events.append(event.type)
        }
        return await (events, response.result())
    }

    @Test(.timeLimit(.minutes(1)))
    func `a failed handshake is asked again, and kwwk hears only the reply`() async throws {
        let script = Script([Self.failure(NSURLErrorSecureConnectionFailed), Self.reply("Hello.")])
        let waits = Counter()
        let (events, final) = try await Self.run(script, waits: waits)
        #expect(final.stopReason == .stop && final.content == [.text(TextContent(text: "Hello."))])
        #expect(events == ["start", "start", "text_delta", "done"], "no error of the failed attempt")
        #expect(script.calls == 2)
        #expect(waits.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a handshake that keeps failing is asked again twice, then handed on`() async throws {
        let script = Script(Array(repeating: Self.failure(NSURLErrorSecureConnectionFailed), count: 3))
        let waits = Counter()
        let (events, final) = try await Self.run(script, waits: waits)
        #expect(final.stopReason == .error && final.failure?.transportCode == NSURLErrorSecureConnectionFailed)
        #expect(events.last == "error")
        #expect(script.calls == 3)
        #expect(waits.count == 2)
    }

    /// An empty reply from the server (-1011) is one of them from kwwk
    /// 0.1.118, which retries it as it does a lost connection.
    @Test(.timeLimit(.minutes(1)), arguments: [NSURLErrorNotConnectedToInternet, NSURLErrorBadServerResponse])
    func `an offline request is handed to kwwk once the route is back, not asked again here`(code: Int) async throws {
        let script = Script([Self.failure(code)])
        let route = Route(missing: 5)
        let waits = Counter()
        let (events, final) = try await Self.run(script, path: route.path, waits: waits)
        #expect(final.failure?.transportCode == code, "kwwk retries it, as before")
        #expect(events == ["start", "error"])
        #expect(route.checks > 5, "held until the route came back")
        #expect(script.calls == 1)
        #expect(waits.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `with a route already there an offline failure goes straight to kwwk's own retry`() async throws {
        let script = Script([Self.failure(NSURLErrorNotConnectedToInternet)])
        let waits = Counter()
        let (_, final) = try await Self.run(script, waits: waits)
        #expect(final.failure?.transportCode == NSURLErrorNotConnectedToInternet)
        #expect(waits.count == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a route that stays away is waited for only so long`() async throws {
        let script = Script([Self.failure(NSURLErrorNetworkConnectionLost)])
        let waits = Counter()
        var patience = Self.quick
        patience.pathWait = 200
        let started = Date()
        let (_, final) = try await Self.run(script, path: NetworkPath { false }, patience: patience, waits: waits)
        #expect(Date().timeIntervalSince(started) >= 0.2)
        #expect(final.failure?.transportCode == NSURLErrorNetworkConnectionLost)
        #expect(waits.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a failure after the reply began is kwwk's to take back, never asked again here`() async throws {
        let script = Script([Self.failure(NSURLErrorSecureConnectionFailed, after: "Partial"), Self.reply("Again")])
        let waits = Counter()
        let (events, final) = try await Self.run(script, path: NetworkPath { false }, waits: waits)
        #expect(final.failure?.transportCode == NSURLErrorSecureConnectionFailed)
        #expect(events == ["start", "text_delta", "error"])
        #expect(script.calls == 1)
        #expect(waits.count == 0)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [NSURLErrorServerCertificateUntrusted, NSURLErrorBadURL])
    func `a certificate that will not do, and any other failure, passes straight through`(code: Int) async throws {
        let script = Script([Self.failure(code)])
        let waits = Counter()
        let (_, final) = try await Self.run(script, path: NetworkPath { false }, waits: waits)
        #expect(final.failure?.transportCode == code)
        #expect(script.calls == 1)
        #expect(waits.count == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `stopping the request ends the wait at once`() async throws {
        let script = Script([Self.failure(NSURLErrorNotConnectedToInternet)])
        let waits = Counter()
        let cancellation = CancellationHandle()
        var patience = Self.quick
        patience.pathWait = 60000
        let stop = Task {
            try await Task.sleep(for: .milliseconds(100))
            cancellation.cancel()
        }
        let (events, final) = try await Self.run(
            script, path: NetworkPath { false }, patience: patience, cancellation: cancellation, waits: waits,
        )
        _ = try await stop.value
        #expect(final.stopReason == .aborted)
        #expect(events == ["start", "error"])
    }

    // MARK: - In a session

    private static func session(_ home: TemporaryHome, _ faux: FauxProviderRegistration) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                network: NetworkPath { true },
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }

    /// A reply the network failed, as the faux provider streams one.
    private static func fauxFailure(_ code: Int, text: String? = nil) -> FauxResponseStep {
        var failed = fauxAssistantMessage(
            blocks: text.map { [fauxText($0)] } ?? [],
            stopReason: .error,
            errorMessage: "Error Domain=NSURLErrorDomain Code=\(code)",
        )
        failed.failure = ProviderFailure(message: "failed", transportDomain: NSURLErrorDomain, transportCode: code)
        return .message(failed)
    }

    private static func events(of session: AgentSession, prompt: String) async throws -> [AgentSessionEvent] {
        let stream = try await session.events(afterSeq: 0)
        try await session.prompt(prompt)
        var events: [AgentSessionEvent] = []
        for await record in stream {
            events.append(record.event)
            if case .finished = record.event {
                break
            }
        }
        await session.waitForIdle()
        return events
    }

    private static func isCall(_ event: AgentSessionEvent) -> Bool {
        if case .toolCallStarted = event {
            return true
        }
        return false
    }

    private static func isMessage(_ event: AgentSessionEvent) -> Bool {
        if case .messageFinished = event {
            return true
        }
        return false
    }

    private static func isError(_ event: AgentSessionEvent) -> Bool {
        if case .error = event {
            return true
        }
        return false
    }

    /// kwwk asks again for a request the network failed after a call ran;
    /// the call is not run again, and the app hears the request is retried.
    @Test(.timeLimit(.minutes(1)))
    func `a request retried after a call runs it once and says it is reconnecting`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("README.md", "Hello\n")
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [
                fauxToolCall(name: "file_read", arguments: ["reason": "Read the readme", "path": "README.md"]),
            ], stopReason: .toolUse)),
            Self.fauxFailure(NSURLErrorNotConnectedToInternet),
            Self.fauxFailure(NSURLErrorNotConnectedToInternet),
            .message(fauxAssistantMessage("It says hello.")),
        ])
        let session = try await Self.session(home, faux)
        let events = try await Self.events(of: session, prompt: "What does the readme say?")
        #expect(events.count(where: Self.isCall) == 1)
        #expect(events.count(where: { $0 == .reconnecting }) == 2)
        #expect(!events.contains(where: Self.isError))
        #expect(events.last == .finished(reason: .completed))
        await session.close()
    }

    /// kwwk would end the turn on a failed handshake; it is asked again.
    @Test(.timeLimit(.minutes(1)))
    func `a failed handshake no longer fails the turn`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            Self.fauxFailure(NSURLErrorSecureConnectionFailed),
            .message(fauxAssistantMessage("Hello.")),
        ])
        let session = try await Self.session(home, faux)
        let events = try await Self.events(of: session, prompt: "Hi")
        #expect(faux.state.callCount == 2)
        #expect(events.contains(.reconnecting))
        #expect(events.contains(.messageFinished(text: "Hello.")))
        #expect(!events.contains(where: Self.isError))
        #expect(events.last == .finished(reason: .completed))
        await session.close()
    }

    /// kwwk takes back a reply the connection dropped halfway and asks
    /// again; the app hears the partial text is not the reply.
    @Test(.timeLimit(.minutes(1)))
    func `a reply cut off halfway is discarded before it is asked for again`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            Self.fauxFailure(NSURLErrorNetworkConnectionLost, text: "Partial ans"),
            .message(fauxAssistantMessage("Full answer.")),
        ])
        let session = try await Self.session(home, faux)
        let events = try await Self.events(of: session, prompt: "Hi")
        let starts = events.indices.filter { events[$0] == .messageStarted }
        let discarded = try #require(events.firstIndex(of: .messageDiscarded))
        #expect(starts.count == 2 && starts[0] < discarded && discarded < starts[1])
        let partial = events[starts[0] ..< discarded].compactMap { event -> String? in
            if case let .textDelta(text) = event {
                return text
            }
            return nil
        }
        #expect(partial.joined() == "Partial ans")
        #expect(events[discarded...].contains(.reconnecting))
        #expect(events.filter(Self.isMessage) == [.messageFinished(text: "Full answer.")])
        #expect(events.last == .finished(reason: .completed))
        await session.close()
    }
}
