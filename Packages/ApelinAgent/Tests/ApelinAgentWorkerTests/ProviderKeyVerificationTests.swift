@testable import ApelinAgentWorker
import ApelinProtocol
import Foundation
import KWWKAI
import Network
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ProviderKeyVerificationTests {
    @Test(arguments: [AgentProvider.openAICompatible, .deepSeek, .openCodeGo])
    func `verification sends an authenticated model request and rejects HTTP errors and empty answers`(provider: AgentProvider) async throws {
        let answer = "data: {\"id\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let empty = "data: {\"id\":\"test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        for (status, body, succeeds) in [(200, answer, true), (200, empty, false), (401, "{\"error\":{\"message\":\"candidate-secret\"}}", false)] {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            defer { server.cancel() }
            let (ports, ready) = AsyncStream<UInt16>.makeStream()
            server.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = server.port {
                        ready.yield(port.rawValue)
                    }
                    ready.finish()
                case .waiting, .failed, .cancelled:
                    // A listener that cannot bind (in a sandbox) ends the
                    // wait for a port instead of leaving it open.
                    ready.finish()
                default:
                    break
                }
            }
            server.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "provider-verification-connection"))
                Self.respond(connection, status: status, body: body)
            }
            server.start(queue: DispatchQueue(label: "provider-verification-listener"))
            var iterator = ports.makeAsyncIterator()
            let port = try #require(await iterator.next())
            let credentials = OAuthCredentials(access: "candidate-secret", refresh: "", expires: .max, extras: [
                "baseUrl": .string("http://127.0.0.1:\(port)/v1"), "defaultModel": .string("verification-model"),
            ])
            if succeeds {
                try await ProviderKeyVerification.verify(provider, credentials)
            } else {
                do {
                    try await ProviderKeyVerification.verify(provider, credentials)
                    Issue.record("verification accepted an error or empty answer")
                } catch let error as ApelinError {
                    #expect(error.code == .unavailable)
                    #expect(!error.message.contains("candidate-secret"))
                }
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: Int, body: String, received: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, ended, error in
            let request = received + (data ?? Data())
            guard let separator = request.range(of: Data("\r\n\r\n".utf8)) else {
                if ended || error != nil {
                    connection.cancel(); return
                }
                respond(connection, status: status, body: body, received: request)
                return
            }
            let header = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
            let length = header.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            guard request.count - separator.upperBound >= length else {
                if ended || error != nil {
                    connection.cancel(); return
                }
                respond(connection, status: status, body: body, received: request)
                return
            }
            #expect(header.hasPrefix("POST /v1/chat/completions HTTP/1.1"))
            #expect(header.lowercased().contains("authorization: bearer candidate-secret"))
            let payload = try? JSONSerialization.jsonObject(with: Data(request[separator.upperBound...])) as? [String: Any]
            #expect(payload?["model"] as? String == "verification-model")
            #expect(payload?["stream"] as? Bool == true)
            let response = "HTTP/1.1 \(status) Test\r\nContent-Type: text/event-stream\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
