@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

/// #67: Stop ends a turn at any point a provider out of allowance, out of
/// reach or silent can hold it, within seconds. Each waits on a provider on
/// this Mac, through kwwk's own provider, retries and request timeouts.
@Suite("Stop ends a turn wherever it waits", .serialized)
struct StopTests {
    /// What a session recorded, and when, from its start.
    final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(Date, AgentSessionEvent)] = []
        private var reader: Task<Void, Never>?

        init(_ session: AgentSession) async throws {
            let stream = try await session.events(afterSeq: 0)
            reader = Task { [weak self] in
                for await record in stream {
                    self?.lock.withLock { self?.seen.append((Date(), record.event)) }
                }
            }
        }

        deinit {
            reader?.cancel()
        }

        var events: [AgentSessionEvent] {
            lock.withLock { seen.map(\.1) }
        }

        /// When the first event `matching` came, waiting up to `limit`.
        func first(
            within limit: Duration = .seconds(30),
            _ matching: @escaping (AgentSessionEvent) -> Bool,
        ) async -> Date? {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if let found = lock.withLock({ seen.first { matching($0.1) }?.0 }) {
                    return found
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }

        /// Whether `ready` came to hold of the events, waiting up to `limit`.
        func wait(
            within limit: Duration = .seconds(10),
            until ready: @escaping ([AgentSessionEvent]) -> Bool,
        ) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if ready(events) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }

    /// How long a stopped turn may take to end: the promise is seconds.
    static let promptly: TimeInterval = 3

    static func session(
        _ home: TemporaryHome,
        _ server: StandInProvider,
        network: NetworkPath = NetworkPath { true },
    ) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(server.model()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                network: network,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }

    static func isFinished(_ event: AgentSessionEvent) -> Bool {
        if case .finished = event {
            return true
        }
        return false
    }

    /// Sends "Hi", waits until `ready` says the turn is where the test
    /// wants it (and sends a second message there when `queueing`), stops
    /// it and answers how long the turn took to end.
    static func stop(
        _ server: StandInProvider,
        network: NetworkPath = NetworkPath { true },
        queueing: Bool = false,
        until ready: @escaping ([AgentSessionEvent]) -> Bool,
    ) async throws -> (took: TimeInterval?, events: [AgentSessionEvent]) {
        let home = try TemporaryHome()
        defer { home.remove() }
        let session = try await session(home, server, network: network)
        let recorded = try await Recorded(session)
        try await session.prompt("Hi", messageID: UUID())
        #expect(await recorded.wait(until: ready), "the turn never got there")
        if queueing {
            try await session.prompt("And this", messageID: UUID())
        }
        // in the wait, not at its start
        try await Task.sleep(for: .milliseconds(300))
        let stopped = Date()
        await session.abort()
        let ended = await recorded.first(Self.isFinished)
        let events = recorded.events
        await session.close()
        return (ended.map { $0.timeIntervalSince(stopped) }, events)
    }

    @Test(.timeLimit(.minutes(1)))
    func `during kwwk's wait before it asks a rate-limited request again`() async throws {
        let busy = StandInProvider.Reply.error(
            429,
            #"{"error":{"message":"Sorry, you have been rate-limited.","code":"rate_limited"}}"#,
            headers: ["retry-after": "30"],
        )
        let server = try #require(await StandInProvider([busy]))
        defer { server.stop() }
        let (took, events) = try await Self.stop(server) { $0.contains(.reconnecting) }
        #expect(try #require(took) < Self.promptly)
        #expect(server.requests == 1, "not asked again")
        #expect(events.last == .finished(reason: .aborted))
    }

    @Test(.timeLimit(.minutes(1)))
    func `during the wait for the network to come back`() async throws {
        // nothing listens there any more: the connection is refused
        let server = try #require(await StandInProvider([.completion("unused")]))
        server.stop()
        let (took, events) = try await Self.stop(server, network: NetworkPath { false }) { $0.contains(.waitingForNetwork) }
        #expect(try #require(took) < Self.promptly)
        #expect(events.last == .finished(reason: .aborted))
    }

    /// A reply cut off where the allowance ran out, its connection held.
    @Test(.timeLimit(.minutes(1)))
    func `during a reply that stopped halfway`() async throws {
        let server = try #require(await StandInProvider([.partialCompletion("Hello ", ending: .hold)]))
        defer { server.stop() }
        let (took, events) = try await Self.stop(server) { $0.contains(.textDelta("Hello ")) }
        #expect(try #require(took) < Self.promptly)
        #expect(events.last == .finished(reason: .aborted))
    }

    @Test(.timeLimit(.minutes(1)))
    func `during a request that is never answered`() async throws {
        let server = try #require(await StandInProvider([.silence]))
        defer { server.stop() }
        // nothing of the reply comes: the request was taken
        let (took, events) = try await Self.stop(server) { _ in server.requests == 1 }
        #expect(try #require(took) < Self.promptly)
        #expect(events.last == .finished(reason: .aborted))
    }

    @Test(.timeLimit(.minutes(1)))
    func `with a message queued behind the turn`() async throws {
        let busy = StandInProvider.Reply.error(
            429,
            #"{"error":{"message":"Sorry, you have been rate-limited.","code":"rate_limited"}}"#,
            headers: ["retry-after": "30"],
        )
        let server = try #require(await StandInProvider([busy]))
        defer { server.stop() }
        let (took, events) = try await Self.stop(server, queueing: true) { $0.contains(.reconnecting) }
        #expect(try #require(took) < Self.promptly)
        #expect(events.contains {
            if case .queuedMessagesDropped = $0 {
                true
            } else {
                false
            }
        }, "back to the reader")
        #expect(events.count(where: Self.isFinished) == 1, "and no run takes it")
        #expect(events.last == .finished(reason: .aborted))
    }

    /// Compact… against a provider that does not answer.
    @Test(.timeLimit(.minutes(1)))
    func `during a compaction`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        // three replies of about 10k tokens each: more than the 20k kwwk
        // keeps as they are, so the compaction asks for a summary
        let long = String(repeating: "The build log says the hook loaded. ", count: 1200)
        var replies: [StandInProvider.Reply] = (1 ... 3).map { .completion("Reply \($0): \(long)") }
        replies.append(.silence)
        let server = try #require(await StandInProvider(replies))
        defer { server.stop() }
        let session = try await Self.session(home, server)
        for text in ["One", "Two", "Three"] {
            let recorded = try await Recorded(session)
            try await session.prompt(text)
            _ = await recorded.first(Self.isFinished)
            await session.waitForIdle()
        }
        let recorded = try await Recorded(session)
        try await session.compact()
        _ = await recorded.first(within: .seconds(10)) { $0 == .compactionStarted }
        try await Task.sleep(for: .milliseconds(500))
        let stopped = Date()
        await session.abort()
        let ended = try #require(await recorded.first {
            if case .compactionFinished = $0 {
                true
            } else {
                false
            }
        })
        #expect(ended.timeIntervalSince(stopped) < Self.promptly)
        #expect(server.requests == 4, "the summary was asked for")
        #expect(recorded.events.contains {
            if case let .compactionFinished(result) = $0 {
                result.outcome == .cancelled
            } else {
                false
            }
        })
        await session.close()
    }

    /// The chat's title is asked for beside the turn; a stop does not wait
    /// for it either.
    @Test(.timeLimit(.minutes(1)))
    func `during the title's request`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let server = try #require(await StandInProvider([.silence]))
        defer { server.stop() }
        let session = try await Self.session(home, server)
        await session.generateTitle(for: "Make a tweak")
        try await Task.sleep(for: .milliseconds(300))
        let stopped = Date()
        await session.abort()
        await session.waitForTitle()
        #expect(Date().timeIntervalSince(stopped) < Self.promptly)
        await session.close()
    }
}
