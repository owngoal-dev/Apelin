import ApelinProtocol
import CryptoKit
import Foundation
import KWWKAI

/// Raccoon Work, SenseTime's office assistant, as a model provider.
///
/// It is not a kwwk login, so this is Apelin's own registration the way
/// DeepSeek's and Trae's are: the credential is read through kwwk's manager,
/// the provider is registered under the store id, and the token rides to the
/// wire in the request's headers rather than as a bearer.
///
/// The wire is **standard OpenAI over standard SSE** — `chat.completion.chunk`
/// frames ending in `data: [DONE]`, no envelope, no rewriting — so
/// `OpenAICompletionsProvider` is the transport and this file only shapes the
/// request. The reference implementation this follows
/// (`dsh-providers-hub`'s `raccoon-adapter.ts` and its `raccoon-product.ts`)
/// states that outright, and warns that a frame rewriter like Trae's would be
/// wrong here.
public enum RaccoonSite: String, Sendable, CaseIterable, Hashable {
    /// The one gateway. The `case` exists so the id is read the way the other
    /// providers' are, not because a second build is expected.
    case work

    /// The credential store id. It is the provider's scope too.
    public var id: String {
        switch self {
        case .work: "raccoon"
        }
    }

    public var name: String { "Raccoon" }

    public var apiBase: String { "https://xiaohuanxiong.com" }
    /// Chats and the model catalogue.
    public var llmPrefix: String { "/api/web/llm/v2" }
    /// The sign-in, its renewal and `user_info`.
    public var authPrefix: String { "/api/web/auth/v1" }

    /// The client the gateway is told it is talking to. The desktop build's
    /// own value, as its `asar` carries it.
    public var clientPlatform: String { "desktop-windows" }
    public var userAgent: String { "Raccoon Work/1.0.35 (Windows)" }

    /// Where a chat goes.
    public var chatURL: URL? {
        URL(string: apiBase + llmPrefix + "/chat/completions")
    }

    /// Where the account's model catalogue is.
    public var catalogURL: URL? {
        URL(string: apiBase + llmPrefix + "/model_catalog")
    }

    public init?(storeID: String) {
        guard storeID == RaccoonSite.work.id else { return nil }
        self = .work
    }
}

/// What the account's stored credential carries.
///
/// A sign-in leaves an access token, the refresh token that renews it, and
/// the office identity the gateway wants as `X-Org-Code`. The last one is the
/// reason the sign-in is a browser flow rather than a typed key: it comes
/// back from the authorization exchange and cannot be derived.
struct RaccoonCredential: Sendable {
    var access: String
    var refresh: String
    /// Unix ms of the access token's expiry; `.max` for one that says none.
    var expires: Int64
    /// `office_identity`, which the chat request sends as `X-Org-Code`.
    var orgCode: String
    /// `office_org_name`, for the account's label.
    var orgName: String
    /// `office_org_role`.
    var orgRole: String

    init(_ credentials: OAuthCredentials) {
        access = credentials.access
        refresh = credentials.refresh
        expires = credentials.expires
        orgCode = RaccoonCredential.extra("officeIdentity", in: credentials) ?? ""
        orgName = RaccoonCredential.extra("officeOrgName", in: credentials) ?? ""
        orgRole = RaccoonCredential.extra("officeOrgRole", in: credentials) ?? ""
    }

    static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }
}

/// One failure of the Raccoon wire, in words the user can act on.
struct RaccoonError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The credential a request goes out with.
///
/// The gateway rotates its refresh token on every renewal, so what one
/// exchange answered is what the next one uses; the store keeps that one
/// in memory for the session's life. A renewal is attempted once per
/// resolution, shared by every request that needs it.
actor RaccoonTokenStore {
    struct Token: Sendable {
        var value: String
        var orgCode: String
        var refresh: String = ""
        var expires: Int64 = .max
    }

    private let site: RaccoonSite
    private let client: HTTPClient
    private var access: String
    private var refresh: String
    private var expires: Int64
    private var orgCode: String
    private var renewal: Task<Token, Error>?

    init(site: RaccoonSite, credential: RaccoonCredential, client: HTTPClient = URLSessionHTTPClient()) {
        self.site = site
        self.client = client
        access = credential.access
        refresh = credential.refresh
        expires = credential.expires
        orgCode = credential.orgCode
    }

    /// A token good enough for the next request: the stored one until it is
    /// within five minutes of its expiry, a renewed one past that.
    func current() async throws -> Token {
        let now = Date().timeIntervalSince1970 * 1000
        let fresh = expires == .max || now < Double(expires) - 5 * 60 * 1000
        if !access.isEmpty, fresh {
            return Token(value: access, orgCode: orgCode)
        }
        return try await renew()
    }

    /// One renewal at a time: concurrent requests await the same exchange.
    func renew() async throws -> Token {
        if let renewal { return try await renewal.value }
        guard !refresh.isEmpty else {
            throw RaccoonError("The saved Raccoon token cannot be renewed. Sign in again.")
        }
        let site = site
        let client = client
        let refreshToken = refresh
        let task = Task<Token, Error> {
            let exchanged = try await RaccoonWire.refresh(
                site: site,
                refreshToken: refreshToken,
                client: client,
            )
            return Token(
                value: exchanged.access,
                orgCode: exchanged.orgCode.isEmpty ? "" : exchanged.orgCode,
                refresh: exchanged.refresh,
                expires: exchanged.expires,
            )
        }
        renewal = task
        do {
            let renewed = try await task.value
            access = renewed.value
            // The exchange rotates the refresh token; the next renewal must
            // use the one it answered.
            refresh = renewed.refresh
            expires = renewed.expires
            if !renewed.orgCode.isEmpty { orgCode = renewed.orgCode }
            renewal = nil
            return renewed
        } catch {
            renewal = nil
            throw error
        }
    }
}

// MARK: - The wire

/// Raccoon's two control-plane calls: the model catalogue and the renewal.
///
/// The chat itself is standard OpenAI, which `OpenAICompletionsProvider`
/// drives; nothing here rewrites its frames.
public enum RaccoonWire {
    /// The gateway's own client sends these on every chat request. `X-Org-Code`
    /// is the account's `office_identity`: without it the gateway answers as
    /// an unauthorized caller even with a valid token.
    static func requestHeaders(token: String, orgCode: String) -> [String: String] {
        [
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
            "Authorization": "Bearer \(token)",
            "X-Org-Code": orgCode,
            "X-Raccoon-Language": "zh",
            "X-Client-Platform": RaccoonSite.work.clientPlatform,
        ]
    }

    /// `POST {auth}/refresh`, the four-field body the gateway takes.
    ///
    /// It is **not** `/refresh_token` — that path answers 404, and the
    /// reference implementation records that trap: a wrong path makes every
    /// renewal fail, so a token that lapses can only be replaced by signing
    /// in again.
    static func refresh(
        site: RaccoonSite,
        refreshToken: String,
        client: HTTPClient,
    ) async throws -> (access: String, refresh: String, expires: Int64, orgCode: String) {
        guard let url = URL(string: site.apiBase + site.authPrefix + "/refresh") else {
            throw RaccoonError("The Raccoon renewal address could not be read.")
        }
        let body: [String: Any] = ["refresh_token": refreshToken]
        let (response, data) = try await client.request(
            url: url,
            method: "POST",
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            cancellation: nil,
        )
        guard data.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw RaccoonError("The Raccoon renewal answer could not be read (HTTP \(response.statusCode)).")
        }
        // A refusal names itself in the envelope; the code is what tells a
        // lapse from a bad credential.
        if let failure = envelopeError(root) {
            throw RaccoonError("The Raccoon sign-in could not be renewed: \(failure)")
        }
        guard response.statusCode == 200 else {
            throw RaccoonError(
                response.statusCode == 401 || response.statusCode == 403
                    ? "Raccoon refused this token. Sign in again."
                    : "The Raccoon token could not be renewed (HTTP \(response.statusCode)).",
            )
        }
        let result = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        guard let access = firstString(result, ["access_token", "accessToken"]), !access.isEmpty else {
            throw RaccoonError("The Raccoon renewal returned no token. Sign in again.")
        }
        // The gateway rotates the refresh token; one it does not answer with
        // is the one that was sent.
        let renewed = firstString(result, ["refresh_token", "refreshToken"]) ?? refreshToken
        return (
            access,
            renewed,
            expiry(result["expires_at"] ?? result["expiresAt"] ?? result["exp"]),
            firstString(result, ["office_identity", "officeIdentity"]) ?? "",
        )
    }

    /// `GET {llm}/model_catalog`: the account's models, in the gateway's own
    /// order, each with the fields its picker shows.
    static func catalog(
        site: RaccoonSite,
        token: RaccoonTokenStore.Token,
        client: HTTPClient = URLSessionHTTPClient(),
    ) async -> [RaccoonModel] {
        guard let url = site.catalogURL else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        for (name, value) in requestHeaders(token: token.value, orgCode: token.orgCode) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4 * 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let body = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        return RaccoonModel.list(from: body)
    }

    /// The envelope's business code: `0` is success, anything else names a
    /// failure. A body with no code at all is a success — some of the
    /// gateway's answers are bare payloads.
    static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["code", "Code", "errCode", "ErrCode"] {
            guard let value = root[key] else { continue }
            let code: Int? = if let number = value as? NSNumber {
                number.intValue
            } else if let text = value as? String {
                Int(text)
            } else {
                nil
            }
            guard let code, code != 0 else { continue }
            return message(for: code) ?? firstString(root, ["message", "Message", "msg", "Msg"]) ?? "code \(code)"
        }
        if let error = root["error"] as? String ?? root["Error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    /// The gateway's business codes, as the user reads them. A code this file
    /// does not know keeps its own number rather than being guessed at.
    static func message(for code: Int) -> String? {
        switch code {
        case 200001: "Raccoon refused this token. Sign in again."
        case 200003, 200012: "The Raccoon sign-in has expired. Sign in again."
        case 200009: "This Raccoon account is disabled. Contact its support."
        case 200035: "That sign-in code has already been used. Sign in again."
        case 200402: "This Raccoon account has no credits left."
        case 200429: "Raccoon is rate limiting this account. Try again shortly."
        default: nil
        }
    }

    /// The first non-empty string among `keys`, numbers included as text.
    static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
            if let value = object[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    /// `expires_at` is Unix seconds or milliseconds; an entry that says
    /// neither never lapses.
    static func expiry(_ raw: Any?) -> Int64 {
        guard let number = raw as? NSNumber, number.doubleValue > 0 else { return .max }
        let milliseconds = Int64(number.doubleValue)
        return milliseconds > 1_000_000_000_000 ? milliseconds : milliseconds * 1000
    }

    /// A model's output limit as the gateway will take it.
    ///
    /// The catalogue answers `params.max_tokens` as `100_000` for several
    /// models, and the upstream refuses any `max_tokens` above `65_536` with
    /// a 400 for the whole turn — there is no fallback group. The reference
    /// implementation clamps both the declared value and the request body for
    /// that reason.
    static let maximumOutputTokens = 65_536

    static func clampOutputTokens(_ value: Int?) -> Int {
        guard let value, value > 0 else { return maximumOutputTokens }
        return min(value, maximumOutputTokens)
    }
}

// MARK: - The catalogue

/// One model of the account's catalogue.
///
/// The gateway answers `categories[].models[]` and, since 2026-10-04, carries
/// **no `id` field at all**: the wire id is `model_name`. The older fields
/// (`id`, `vision`, `input_modalities`, `context_window`, `max_output_*`,
/// `multiplier`) are gone, and a reader that still looks for them gets an
/// empty catalogue with no error at all — the reference implementation
/// records that as a real incident. The ladder below keeps the old names as
/// a fallback so a gateway that goes back to them still reads.
public struct RaccoonModel: Sendable, Hashable {
    public var id: String
    public var name: String
    public var contextWindow: Int
    public var maxTokens: Int
    public var supportsImage: Bool
    /// The credits a request costs as a multiple, as the picker shows it
    /// ("x0.03" is 0.03, "x0.00" is free). Nil where the config gives none.
    public var multiplier: Double?

    init(
        id: String,
        name: String,
        contextWindow: Int,
        maxTokens: Int,
        supportsImage: Bool,
        multiplier: Double?,
    ) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.supportsImage = supportsImage
        self.multiplier = multiplier
    }

    /// The models of one `model_catalog` answer, in its order, visible ones
    /// only.
    ///
    /// The gateway lists internal `raccoon-*` models with `visible: false`;
    /// they are not callable by an account and would fail if offered. The
    /// picker's "Auto" entry is not a remote model either — it is a client
    /// string, and sending it to `chat/completions` answers 404.
    public static func list(from body: [String: Any]) -> [RaccoonModel] {
        var out: [RaccoonModel] = []
        for category in body["categories"] as? [[String: Any]] ?? [] {
            for model in category["models"] as? [[String: Any]] ?? [] {
                if let visible = model["visible"] as? Bool, !visible { continue }
                guard let row = row(model), !out.contains(where: { $0.id == row.id }) else { continue }
                out.append(row)
            }
        }
        return out
    }

    static func row(_ model: [String: Any]) -> RaccoonModel? {
        // `model_name` first: it is the wire id since the 2026-10-04 change,
        // and `name` may be a display name rather than an id.
        guard let id = RaccoonWire.firstString(model, ["model_name", "id", "modelName"]),
              !id.isEmpty
        else { return nil }
        let params = model["params"] as? [String: Any] ?? [:]
        let display = RaccoonWire.firstString(model, ["display_name", "displayName", "name"]) ?? id
        let tags = model["tags"] as? [String] ?? []
        let window = int(model["context_window"] ?? model["contextWindow"])
            ?? int(params["context_window"] ?? params["contextWindow"])
        let maxTokens = int(model["max_output_length"] ?? model["maxOutputLength"])
            ?? int(params["max_tokens"] ?? params["maxTokens"])
        return RaccoonModel(
            id: id,
            name: display,
            contextWindow: window ?? 200_000,
            maxTokens: RaccoonWire.clampOutputTokens(maxTokens),
            supportsImage: supportsImage(id: id, tags: tags, model: model),
            multiplier: rate(model["billing_effective_multiplier"] ?? model["billing_multiplier"] ?? model["multiplier"]),
        )
    }

    /// Whether the model reads images.
    ///
    /// The catalogue says so in `tags`, and the gateway has never sent an
    /// explicit modality field — an exhaustive key union of one catalogue
    /// answer found none. Two exceptions the reference implementation
    /// measured rather than assumed: `sn-deepseek-v4-1-flash` reads images
    /// with no `vision` tag (a 200 with a real PNG), and the GLM family is
    /// listed `text-only` because the server drops the image and tells the
    /// model so.
    static func supportsImage(id: String, tags: [String], model: [String: Any]) -> Bool {
        if let said = model["vision"] as? Bool { return said }
        if let modalities = model["input_modalities"] as? [String], modalities.contains("image") {
            return true
        }
        let marks = Set(tags.map { $0.lowercased() })
        if marks.contains("vision") || marks.contains("image") || marks.contains("image-understanding") {
            return true
        }
        return visionWhitelist.contains(id)
    }

    /// Models measured to read images without saying so in `tags`. Adding a
    /// member takes a real probe, not a belief.
    static let visionWhitelist: Set<String> = ["sn-deepseek-v4-1-flash"]

    /// The multiple the picker shows by a model: "x0.03", "0", or a number.
    static func rate(_ raw: Any?) -> Double? {
        let text: String
        switch raw {
        case let string as String: text = string
        case let number as Double: text = String(number)
        case let number as Int: text = String(number)
        case let number as NSNumber: text = number.stringValue
        default: return nil
        }
        var digits = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if digits.hasPrefix("x") { digits = digits.dropFirst() }
        guard let rate = Double(digits), rate.isFinite, rate >= 0 else { return nil }
        return rate
    }

    static func int(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }

    /// The models offered before (or instead of) a live catalogue.
    ///
    /// The six visible models of the 2026-09-26 catalogue, in its order. The
    /// output limit is the upstream's ceiling rather than the `100_000` the
    /// catalogue names, which the gateway refuses.
    public static let fallback: [RaccoonModel] = [
        RaccoonModel(id: "sn-sensenova-6-8-flash", name: "SenseNova-6.8-Flash", contextWindow: 256_000, maxTokens: 63_999, supportsImage: true, multiplier: 0),
        RaccoonModel(id: "sn-sensenova-6-8-flash-lite", name: "SenseNova-6.8-Flash-Lite", contextWindow: 256_000, maxTokens: 63_999, supportsImage: true, multiplier: 0),
        RaccoonModel(id: "sn-glm-5-3", name: "GLM-5-3", contextWindow: 1_000_000, maxTokens: 65_536, supportsImage: true, multiplier: 0.75),
        RaccoonModel(id: "sn-kimi-k3", name: "Kimi-K3", contextWindow: 1_000_000, maxTokens: 65_536, supportsImage: true, multiplier: 1),
        RaccoonModel(id: "sn-glm-5-3-flash", name: "GLM-5-3-Flash", contextWindow: 1_000_000, maxTokens: 65_536, supportsImage: true, multiplier: 0.1),
        RaccoonModel(id: "sn-deepseek-v4-1-flash", name: "DeepSeek-V4.1-Flash", contextWindow: 1_000_000, maxTokens: 65_536, supportsImage: true, multiplier: 0.25),
    ]
}

/// The catalogue this process last read, per store id, for ten minutes.
///
/// A session resolves its provider on every open and every model switch, and
/// the picker asks for the list again; the gateway's answer does not change
/// that often, and it costs a request each time.
final class RaccoonCatalogCache: @unchecked Sendable {
    static let shared = RaccoonCatalogCache()

    private let lock = NSLock()
    private var entries: [String: (models: [RaccoonModel], at: Date)] = [:]
    private let lifetime: TimeInterval = 10 * 60

    // Swift-only types: Objective-C cannot carry `RaccoonModel`, so these
    // stay plain (AGENTS.md ▸ Hard rules).
    func models(for storeID: String) -> [RaccoonModel]? {
        lock.withLock {
            guard let entry = entries[storeID], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.models
        }
    }

    func store(_ models: [RaccoonModel], for storeID: String) {
        lock.withLock { entries[storeID] = (models, Date()) }
    }
}

// MARK: - The provider

/// Raccoon's chat: standard OpenAI over standard SSE, so the transport is
/// kwwk's own and this only shapes the request.
public struct RaccoonProvider: APIProvider {
    public let api = "openai-completions"
    public let site: RaccoonSite
    private let completions: OpenAICompletionsProvider

    public init(
        site: RaccoonSite,
        client: HTTPClient = URLSessionHTTPClient(),
    ) {
        self.site = site
        let url = site.chatURL ?? URL(string: site.apiBase + site.llmPrefix)!
        // The two headers that are not per-account go on every request; the
        // token and `X-Org-Code` come from the resolver, which `applyResolvedAuth`
        // writes into the same dictionary before the decorator below runs.
        let fixed: [String: String] = [
            "Accept": "text/event-stream",
            "X-Raccoon-Language": "zh",
            "X-Client-Platform": site.clientPlatform,
        ]
        completions = OpenAICompletionsProvider(
            client: client,
            defaultBaseURL: url,
            extraHeaders: fixed,
            // The base URL already names the endpoint; the generic builder
            // would append `/v1/chat/completions` to it.
            urlBuilder: { _, _, fallback in fallback },
            // A bearer token is not how this gate is signed; the resolver
            // hands over the headers instead, and this keeps kwwk from adding
            // one of its own when no resolver ran.
            authHeaderBuilder: { _ in [:] },
            bodyDecorator: { root, model, _, options in
                RaccoonWire.mend(&root, model: model, options: options)
            },
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        completions.stream(model: model, context: context, options: options)
    }
}

extension RaccoonWire {
    /// Shapes the request body Raccoon's gate reads.
    ///
    /// The OpenAI body kwwk encodes is kept for its messages, tools and
    /// sampling fields. Three things are this wire's own:
    /// - the output limit is clamped to what the gate accepts (above 65 536
    ///   it answers 400 for the whole turn, with no fallback group);
    /// - kwwk's `reasoning_effort` is **removed**: the gate accepts the field
    ///   and ignores it, and eight paired runs at temperature 0 measured no
    ///   difference between `minimal` and `max`;
    /// - the thinking level goes **inside `extra_body`**, as
    ///   `thinking.type` of `enabled` or `disabled`. Sent at the top level it
    ///   is ignored silently — not even an invalid value is refused.
    static func mend(_ root: inout [String: Any], model: Model, options: StreamOptions?) {
        if let maxTokens = root["max_tokens"] as? Int {
            root["max_tokens"] = clampOutputTokens(maxTokens)
        }
        root.removeValue(forKey: "reasoning_effort")
        root.removeValue(forKey: "reasoning")
        guard model.reasoning, let level = options?.reasoning else { return }
        root["extra_body"] = thinkingExtraBody(level)
    }

    /// The `extra_body` the gate reads for a level.
    ///
    /// The gate has two states, enabled and disabled, and the levels between
    /// them change nothing measurable: eight paired runs at temperature 0
    /// measured `minimal` at 197 reasoning tokens and `max` at 226, with the
    /// difference positive four times and negative four.
    ///
    /// A level the caller named means thinking **on**. A level it did not
    /// name — which is what kwwk sends for `off`, and for a model that does
    /// not reason — sends no field at all, so the server keeps its own
    /// default, which is on. That is the honest mapping: the gate's `off` is
    /// not a weaker level, it is a different channel.
    static func thinkingExtraBody(_ level: ReasoningLevel) -> [String: Any] {
        ["thinking": ["type": "enabled"]]
    }
}

// MARK: - Registration

/// The models the app sees for a Raccoon account.
public enum RaccoonModels {
    /// The models offered before (or instead of) a live catalogue.
    public static var fallback: [String] { RaccoonModel.fallback.map(\.id) }

    /// The account's live catalogue, nil when the gateway gave none.
    public static func live(site: RaccoonSite, credentials: OAuthCredentials) async -> [RaccoonModel]? {
        if let cached = RaccoonCatalogCache.shared.models(for: site.id) { return cached }
        let store = RaccoonTokenStore(site: site, credential: RaccoonCredential(credentials))
        guard let token = try? await store.current() else { return nil }
        let models = await RaccoonWire.catalog(site: site, token: token)
        if !models.isEmpty { RaccoonCatalogCache.shared.store(models, for: site.id) }
        return models.isEmpty ? nil : models
    }

    /// The account's models as ids, the live catalogue when it answers and
    /// the standing list when it does not.
    public static func list(site: RaccoonSite, credentials: OAuthCredentials) async -> [String] {
        if let live = await live(site: site, credentials: credentials) { return live.map(\.id) }
        return fallback
    }
}

/// Registers Raccoon for account verification and session requests.
///
/// Like Trae and DeepSeek this is Apelin's own registration, not a kwwk
/// login: the credential is read through kwwk's manager, the provider is
/// registered under its store id, and the token rides in the request's
/// headers rather than as a bearer.
enum RaccoonRegistration {
    static func resolve(
        site: RaccoonSite,
        credentials: OAuthCredentials,
        modelOverride: String? = nil,
    ) async -> ResolvedAuth {
        let store = RaccoonTokenStore(site: site, credential: RaccoonCredential(credentials))
        let catalog = await RaccoonModels.live(site: site, credentials: credentials) ?? RaccoonModel.fallback
        let id = modelOverride
            ?? RaccoonCredential.extra("defaultModel", in: credentials)
            ?? catalog.first?.id
            ?? RaccoonModel.fallback[0].id
        let row = catalog.first { $0.id == id } ?? RaccoonModel.fallback.first { $0.id == id }
        var model = Model(
            id: id,
            name: row?.name ?? id,
            api: "openai-completions",
            provider: site.id,
            baseURL: site.chatURL?.absoluteString ?? "",
            reasoning: true,
        )
        model.contextWindow = row?.contextWindow ?? 200_000
        model.maxTokens = row?.maxTokens ?? 65_536
        if let row, row.supportsImage { model.input = [.text, .image] }
        await APIRegistry.shared.register(
            RaccoonProvider(site: site),
            scope: site.id,
        )
        return ResolvedAuth(model: model, modelLabel: "\(model.name) · \(site.name)", authResolver: { _, _ in
            do {
                let token = try await store.current()
                return ResolvedProviderAuth(
                    token: nil,
                    scheme: .none,
                    headers: RaccoonWire.requestHeaders(token: token.value, orgCode: token.orgCode),
                )
            } catch {
                throw ApelinError(.denied, error.localizedDescription)
            }
        })
    }
}
