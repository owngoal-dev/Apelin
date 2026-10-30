@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("OpenCode Go registration and session header", .serialized)
struct OpenCodeGoProviderTests {
    private static let key = OAuthCredentials(access: "oc_sk-key", refresh: "", expires: .max)

    @Test(arguments: [
        ("glm-5.2", "openai-completions", "https://opencode.ai/inference/go/openai/v1"),
        ("claude-haiku-5-5", "anthropic-messages", "https://opencode.ai/inference/go/anthropic"),
        ("grok-4.7", "openai-responses", "https://opencode.ai/inference/go/openai/v1"),
        ("minimax-m3", "anthropic-messages", "https://opencode.ai/inference/go/anthropic"),
        ("muse-spark-1.3-contributor", "openai-responses", "https://opencode.ai/inference/go/openai/v1"),
    ])
    func `catalog models keep their wire on Go's family base`(
        id: String,
        api: String,
        baseURL: String,
    ) async {
        let resolved = await OpenCodeGoProvider.resolve(credentials: Self.key, modelOverride: id)
        #expect(resolved.model.id == id)
        #expect(resolved.model.api == api)
        #expect(resolved.model.provider == CredentialProviderID.openCodeGo)
        #expect(resolved.model.baseURL == baseURL)
    }

    @Test
    func `DeepSeek's catalog capabilities survive the Go registration`() async {
        let resolved = await OpenCodeGoProvider.resolve(credentials: Self.key, modelOverride: "deepseek-v4.1-flash")
        #expect(resolved.model.compat?.thinkingFormat == "deepseek")
        #expect(resolved.model.input.contains(.image))
        #expect(resolved.model.contextWindow == 1_000_000)
    }

    @Test
    func `an unknown model falls back to Chat Completions`() async {
        let resolved = await OpenCodeGoProvider.resolve(credentials: Self.key, modelOverride: "future-model")
        #expect(resolved.model.api == "openai-completions")
        #expect(resolved.model.baseURL == "https://opencode.ai/inference/go/openai/v1")
        #expect(resolved.model.reasoning == false)
        #expect(resolved.model.input == [.text])
    }

    @Test
    func `a stored default model is used when the caller names none`() async {
        let credentials = OAuthCredentials(access: "key", refresh: "", expires: .max, extras: [
            "defaultModel": .string("claude-haiku-5-5"),
        ])
        let resolved = await OpenCodeGoProvider.resolve(credentials: credentials, modelOverride: nil)
        #expect(resolved.model.id == "claude-haiku-5-5")
        #expect(resolved.model.api == "anthropic-messages")
    }

    @Test
    func `the auth resolver carries the key as a bearer token`() async throws {
        let resolved = await OpenCodeGoProvider.resolve(credentials: Self.key, modelOverride: "glm-5.2")
        let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
        #expect(auth.token == "oc_sk-key")
        #expect(auth.scheme == .bearer)
    }

    @Test
    func `Gemini is registered on its own family root`() {
        #expect(OpenCodeGoProvider.baseURL(for: "google-generative-ai")
            == "https://opencode.ai/inference/go/google")
    }

    @Test
    func `every request names its conversation`() async throws {
        let capture = RequestCapture()
        let wrapped = OpenCodeGoSessionProvider(base: OpenAICompletionsProvider(client: capture))
        var model = try #require(ModelsCatalog.model(provider: "opencode-go", id: "glm-5.2"))
        model.baseURL = OpenCodeGoProvider.baseURL(for: model.api)

        let stream = wrapped.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                maxTokens: 32,
                sessionId: "ses_test",
                resolvedAuth: ResolvedProviderAuth(token: "oc_sk-key", scheme: .bearer),
                verbose: false,
            ),
        )
        for await _ in stream {}
        #expect(await stream.result().stopReason == .stop)

        let request = try #require(await capture.request)
        #expect(request.url.absoluteString == "https://opencode.ai/inference/go/openai/v1/chat/completions")
        #expect(request.headers["Authorization"] == "Bearer oc_sk-key")
        #expect(header(request, "x-opencode-session") == "ses_test")
    }

    @Test
    func `a request with no conversation uses one process-wide id`() async throws {
        let capture = RequestCapture()
        let wrapped = OpenCodeGoSessionProvider(base: OpenAICompletionsProvider(client: capture))
        var model = try #require(ModelsCatalog.model(provider: "opencode-go", id: "glm-5.2"))
        model.baseURL = OpenCodeGoProvider.baseURL(for: model.api)

        let stream = wrapped.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                maxTokens: 32,
                resolvedAuth: ResolvedProviderAuth(token: "oc_sk-key", scheme: .bearer),
                verbose: false,
            ),
        )
        for await _ in stream {}

        let request = try #require(await capture.request)
        #expect(header(request, "x-opencode-session") == OpenCodeGoProvider.processSession)
    }

    @Test
    func `a caller's session header wins`() async throws {
        let capture = RequestCapture()
        let wrapped = OpenCodeGoSessionProvider(base: OpenAICompletionsProvider(client: capture))
        var model = try #require(ModelsCatalog.model(provider: "opencode-go", id: "glm-5.2"))
        model.baseURL = OpenCodeGoProvider.baseURL(for: model.api)

        let stream = wrapped.stream(
            model: model,
            context: Context(messages: [.user(UserMessage(text: "hi"))]),
            options: StreamOptions(
                maxTokens: 32,
                sessionId: "ses_real",
                headers: ["X-OpenCode-Session": "caller"],
                resolvedAuth: ResolvedProviderAuth(token: "oc_sk-key", scheme: .bearer),
                verbose: false,
            ),
        )
        for await _ in stream {}

        let request = try #require(await capture.request)
        #expect(header(request, "x-opencode-session") == "caller")
    }

    private func header(_ request: RequestCapture.Request, _ name: String) -> String? {
        request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private actor RequestCapture: HTTPClient {
    struct Request: Sendable {
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    var request: Request?

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation _: CancellationHandle?,
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        #expect(method == "POST")
        request = Request(url: url, headers: headers, body: body)
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "text/event-stream"],
        ))
        let reply = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"OK\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        return (response, AsyncThrowingStream { continuation in
            continuation.yield(Data(reply.utf8))
            continuation.finish()
        })
    }
}
