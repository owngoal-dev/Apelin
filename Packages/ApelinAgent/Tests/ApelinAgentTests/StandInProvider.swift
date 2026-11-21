import Foundation
import KWWKAI
import Network

/// A model provider on 127.0.0.1 for tests: each request it takes is
/// answered with the next of its scripted replies, the last one again once
/// they run out, as a provider whose state does not change would.
final class StandInProvider: @unchecked Sendable {
    /// What a reply does once its body is sent.
    enum Ending: Sendable {
        /// Closes the connection, which ends the body.
        case close
        /// Keeps the connection open and says nothing more, as a provider
        /// or gateway that stalls.
        case hold
    }

    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: String
        var ending: Ending = .close
        /// How long the provider takes before it answers, in seconds.
        var delay: Double = 0

        /// A request taken and never answered, not even with a status.
        static let silence = Reply(status: 0, body: "", ending: .hold)

        /// An error answered whole, as a provider refuses a request.
        static func error(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
            var reply = Reply(status: status, body: body)
            reply.headers.merge(headers) { _, new in new }
            return reply
        }

        /// A 200 event stream with `events` in it, then `ending`.
        static func stream(_ events: [String], ending: Ending = .close) -> Reply {
            Reply(
                status: 200,
                headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"],
                body: events.joined(),
                ending: ending,
            )
        }

        /// A Chat Completions reply of `text`, whole.
        static func completion(_ text: String) -> Reply {
            stream([chunk(text) + #"},"finish_reason":"stop"}]}"# + "\n\n", "data: [DONE]\n\n"])
        }

        /// A Chat Completions reply that begins with `text` and goes no
        /// further, then `ending`.
        static func partialCompletion(_ text: String, ending: Ending) -> Reply {
            stream([chunk(text) + "}}]}\n\n"], ending: ending)
        }

        private static func chunk(_ text: String) -> String {
            #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"# + "\"\(text)\""
        }

        /// This reply, `seconds` later.
        func after(_ seconds: Double) -> Reply {
            var reply = self
            reply.delay = seconds
            return reply
        }
    }

    private let listener: NWListener
    private let lock = NSLock()
    private var replies: [Reply]
    private var answered = 0
    private var open: [NWConnection] = []
    private(set) var port: UInt16 = 0

    /// Starts listening; nil where nothing may bind (a sandbox).
    init?(_ replies: [Reply]) async {
        precondition(!replies.isEmpty)
        self.replies = replies
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        let (ports, ready) = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    ready.yield(port.rawValue)
                }
                ready.finish()
            case .waiting, .failed, .cancelled:
                ready.finish()
            default:
                break
            }
        }
        var iterator = ports.makeAsyncIterator()
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: DispatchQueue(label: "stand-in-provider"))
        guard let port = await iterator.next() else {
            listener.cancel()
            return nil
        }
        self.port = port
    }

    deinit {
        stop()
    }

    /// The base URL a provider's model is pointed at.
    var baseURL: String {
        "http://127.0.0.1:\(port)"
    }

    /// The requests answered so far.
    var requests: Int {
        lock.withLock { answered }
    }

    /// Stops listening and drops every connection it holds.
    func stop() {
        listener.cancel()
        let open = lock.withLock {
            defer { self.open = [] }
            return self.open
        }
        for connection in open {
            connection.cancel()
        }
    }

    /// A model of `api` served by this provider, registered under a scope
    /// of its own with kwwk's own provider for that wire.
    func model(api: String = "openai-completions") async -> Model {
        let scope = "stand-in-\(UUID().uuidString.prefix(8))"
        let provider: any APIProvider = switch api {
        case "anthropic-messages": AnthropicProvider(defaultAPIKey: "test-key")
        case "openai-responses": OpenAIResponsesProvider(webSocketClient: nil, defaultAPIKey: "test-key")
        case "google-generative-ai": GoogleGeminiProvider(defaultAPIKey: "test-key")
        default: OpenAICompletionsProvider(defaultAPIKey: "test-key")
        }
        await APIRegistry.shared.register(provider, scope: scope)
        // Chat Completions is asked at <base>/chat/completions, the others
        // add their own version
        let base = api == "openai-completions" ? baseURL + "/v1" : baseURL
        return Model(id: "stand-in", api: api, provider: scope, baseURL: base)
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { open.append(connection) }
        connection.start(queue: DispatchQueue(label: "stand-in-provider-connection"))
        read(connection, received: Data())
    }

    private func read(_ connection: NWConnection, received: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, ended, error in
            guard let self else { return }
            let request = received + (data ?? Data())
            guard let separator = request.range(of: Data("\r\n\r\n".utf8)) else {
                if ended || error != nil {
                    connection.cancel()
                } else {
                    read(connection, received: request)
                }
                return
            }
            let header = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.count - separator.upperBound >= length else {
                if ended || error != nil {
                    connection.cancel()
                } else {
                    read(connection, received: request)
                }
                return
            }
            respond(connection)
        }
    }

    private func respond(_ connection: NWConnection) {
        let reply = lock.withLock {
            answered += 1
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        guard reply.status != 0 else { return }
        guard reply.delay <= 0 else {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) {
                Self.send(reply, on: connection)
            }
            return
        }
        Self.send(reply, on: connection)
    }

    private static func send(_ reply: Reply, on connection: NWConnection) {
        var head = "HTTP/1.1 \(reply.status) Stand-In\r\n"
        for (name, value) in reply.headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        // no length: the body ends when the connection closes
        head += "Connection: close\r\n\r\n"
        let bytes = Data((head + reply.body).utf8)
        switch reply.ending {
        case .close:
            connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
        case .hold:
            connection.send(content: bytes, completion: .contentProcessed { _ in })
        }
    }
}
