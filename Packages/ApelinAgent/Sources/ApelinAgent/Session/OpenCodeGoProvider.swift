import Foundation
import KWWKAI

/// OpenCode Go, opencode.ai's coding subscription, by the API key the
/// OpenCode Console issues. kwwk 0.1.100 carries the catalog
/// (`opencode-go`) but no login for it, so this registers each model on the
/// wire its catalog entry names and stamps the header Go routes by.
///
/// Go refuses a request without `x-opencode-session` with HTTP 400
/// `MissingSessionID`, before it looks at the key:
/// https://opencode.ai/v2/docs/console/go#where-can-i-use-it
/// kwwk sends every other session header but not that one, which is why an
/// OpenAI-compatible entry cannot reach Go.
///
/// The routes are Go's documented family bases, not the catalog's
/// `baseUrl`: kwwk's transports append their own version and path, and the
/// pinned catalog's Google base would append `/v1beta` twice. See
/// https://opencode.ai/v2/docs/console/harnesses#base-urls.
public enum OpenCodeGoProvider {
    public static let storeID = CredentialProviderID.openCodeGo
    public static let catalogKey = "opencode-go"

    /// The gateway's host for the Go plan. The model list lives at
    /// `modelListBaseURL`, not under the OpenAI family base.
    public static let host = "https://opencode.ai/inference/go"
    public static let modelListBaseURL = "\(host)/v1"

    /// Go has no default of its own. This one is cheap, text-only and
    /// listed on the Go plan.
    public static let defaultModel = "glm-5.2"

    /// The header Go routes and caches a conversation by.
    static let sessionHeader = "x-opencode-session"

    /// One id for requests that have no conversation of their own: a model
    /// verification, a title completion. Go wants one on every request.
    static let processSession = UUID().uuidString.lowercased()

    /// Registers the model on its wire and returns what the session uses.
    /// `modelOverride` is the model the app chose; a stored `defaultModel`
    /// (an imported credential) is the fallback before `glm-5.2`.
    static func resolve(credentials: OAuthCredentials, modelOverride: String?) async -> ResolvedAuth {
        let id = modelOverride ?? extra("defaultModel", in: credentials) ?? defaultModel
        let catalog = ModelsCatalog.model(provider: catalogKey, id: id)
        let api = supported(catalog?.api)

        var model = catalog ?? fallbackModel(id: id, api: api)
        model.api = api
        model.provider = storeID
        model.baseURL = extra("baseUrl", in: credentials) ?? baseURL(for: api)

        await register(api: api)
        return ResolvedAuth(
            model: model,
            modelLabel: "\(model.name) · OpenCode Go",
            authResolver: { _, _ in
                ResolvedProviderAuth(token: credentials.access, scheme: .bearer)
            },
        )
    }

    /// Go's family root. The provider appends its own version and path.
    static func baseURL(for api: String) -> String {
        switch api {
        case "anthropic-messages": "\(host)/anthropic"
        case "google-generative-ai": "\(host)/google"
        default: "\(host)/openai/v1" // Chat Completions and Responses
        }
    }

    /// A catalog entry Apelin can route. An unknown wire falls back to Chat
    /// Completions, which Console translates for every Go text model.
    private static func supported(_ api: String?) -> String {
        guard let api,
              ["openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai"].contains(api)
        else { return "openai-completions" }
        return api
    }

    /// An id kwwk's pinned catalog does not carry yet. Conservative on
    /// purpose: text-only, no reasoning, and the compat its known models
    /// share, so a new id still routes.
    private static func fallbackModel(id: String, api: String) -> Model {
        Model(
            id: id,
            name: id,
            api: api,
            provider: storeID,
            baseURL: baseURL(for: api),
            reasoning: false,
            input: [.text],
            cost: ModelCost(),
            contextWindow: 131_072,
            maxTokens: 32_000,
            compat: defaultCompat,
        )
    }

    private static let defaultCompat: ModelCompat = {
        var compat = ModelCompat()
        compat.maxTokensField = "max_tokens"
        compat.supportsDeveloperRole = false
        compat.supportsStore = false
        compat.supportsStrictMode = true
        return compat
    }()

    private static func register(api: String) async {
        let base: any APIProvider
        switch api {
        case "openai-responses":
            // Go documents HTTP/SSE; don't spend a failed WebSocket upgrade
            // on every conversation.
            base = OpenAIResponsesProvider(webSocketClient: nil)
        case "anthropic-messages":
            base = AnthropicProvider()
        case "google-generative-ai":
            base = GoogleGeminiProvider()
        default:
            base = OpenAICompletionsProvider()
        }
        await APIRegistry.shared.register(OpenCodeGoSessionProvider(base: base), scope: storeID)
    }

    private static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }
}

/// Stamps OpenCode Go's per-request session header on a route whose provider
/// has no header hook of its own, after `CopilotRequestHeadersProvider`. The
/// header is the conversation's id; a request with no conversation uses one
/// process-wide id. Session cleanup and native compaction pass straight
/// through, so the wrapped route keeps what the registry finds by cast.
struct OpenCodeGoSessionProvider: APIProvider, APIProviderSessionLifecycle, NativeCompactionProvider {
    let base: any APIProvider

    var api: String { base.api }

    func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        base.stream(model: model, context: context, options: stamped(options))
    }

    func closeSession(sessionId: String) async {
        await (base as? any APIProviderSessionLifecycle)?.closeSession(sessionId: sessionId)
    }

    func compact(
        model: Model,
        context: Context,
        instructions: String,
        options: StreamOptions?,
    ) async throws -> NativeCompactionResult? {
        guard let native = base as? any NativeCompactionProvider else { return nil }
        return try await native.compact(
            model: model,
            context: context,
            instructions: instructions,
            options: stamped(options),
        )
    }

    private func stamped(_ options: StreamOptions?) -> StreamOptions {
        var stamped = options ?? StreamOptions()
        var headers = stamped.headers ?? [:]
        let present = headers.keys.contains {
            $0.caseInsensitiveCompare(OpenCodeGoProvider.sessionHeader) == .orderedSame
        }
        if !present {
            headers[OpenCodeGoProvider.sessionHeader] =
                stamped.sessionId.flatMap { $0.isEmpty ? nil : $0 }
                ?? OpenCodeGoProvider.processSession
        }
        stamped.headers = headers
        return stamped
    }
}
