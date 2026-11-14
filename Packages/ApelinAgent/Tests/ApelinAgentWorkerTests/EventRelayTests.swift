import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import Foundation
import Testing

@Suite("The relay coalesces what streams")
struct EventRelayTests {
    /// What a relay emitted, in order.
    final class Emitted: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, ApelinCore.JSONValue?)] = []

        func append(_ kind: String, _ payload: ApelinCore.JSONValue?) {
            lock.withLock { events.append((kind, payload)) }
        }

        var kinds: [String] {
            lock.withLock { events.map(\.0) }
        }

        var tokens: [Double] {
            lock.withLock { events.filter { $0.0 == "received" }.compactMap { $0.1?["tokens"]?.doubleValue } }
        }

        func payloads(of kind: String) -> [ApelinCore.JSONValue?] {
            lock.withLock { events.filter { $0.0 == kind }.map(\.1) }
        }
    }

    /// kwwk asks again for a message it had begun: the app takes back what
    /// it showed, then hears the request is being made again.
    @Test
    func `a message given up follows its text out, and the request made again follows it`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted)
        await relay.relay(.textDelta("Partial"))
        await relay.relay(.messageDiscarded)
        await relay.relay(.reconnecting)
        await relay.relay(.messageStarted)
        #expect(emitted.kinds == ["messageStarted", "text", "messageDiscarded", "reconnecting", "messageStarted"])
        #expect(emitted.payloads(of: "messageDiscarded") == [nil] && emitted.payloads(of: "reconnecting") == [nil])
    }

    /// A request with no route says so in a kind of its own, and an error
    /// carries its reason only when the agent named one.
    @Test
    func `a wait for the network and an error's reason go out as the app reads them`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.waitingForNetwork)
        await relay.relay(.error(message: "The Internet connection appears to be offline.", reason: .offline))
        await relay.relay(.error(message: "A skill has a problem."))
        #expect(emitted.kinds == ["waitingForNetwork", "error", "error"])
        #expect(emitted.payloads(of: "waitingForNetwork") == [nil])
        #expect(emitted.payloads(of: "error") == [
            .object(["message": .string("The Internet connection appears to be offline."), "reason": .string("offline")]),
            .object(["message": .string("A skill has a problem.")]),
        ])
    }

    @Test
    func `the received count goes out with the streamed text, only its latest and only when new`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted)
        await relay.relay(.textDelta("Reading"))
        await relay.relay(.received(tokens: 2))
        await relay.relay(.textDelta(" it."))
        await relay.relay(.received(tokens: 3))
        await relay.relay(.toolCallPreparing)
        // within a quarter second this is one flush; a slow machine may
        // flush between the two, never sending a count twice
        #expect(emitted.kinds.suffix(2) == ["received", "toolCallPreparing"])
        #expect(emitted.tokens.last == 3 && emitted.tokens.count <= 2)
        let sent = emitted.tokens.count
        // a flush with no new count sends none
        await relay.relay(.messageFinished(text: "Reading it."))
        #expect(emitted.tokens.count == sent)
        await relay.relay(.received(tokens: 40))
        await relay.relay(.finished(reason: .completed))
        #expect(emitted.kinds.suffix(2) == ["received", "finished"], "the last count goes before the run's end")
        #expect(emitted.tokens.last == 40 && emitted.tokens.count == sent + 1)
    }
}
