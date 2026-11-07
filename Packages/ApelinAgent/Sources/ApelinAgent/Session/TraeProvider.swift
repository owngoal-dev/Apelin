import ApelinProtocol
import CryptoKit
import Foundation
import KWWKAI

/// Trae, ByteDance's IDE, in its two builds: the China one (`trae`) and the
/// international one (`trae-intl`), each its own remote gate and sign-in the
/// way qoder and qoder.cn are.
public enum TraeSite: String, Sendable, CaseIterable, Hashable {
    case china
    case international

    /// The credential store id, in kwwk's shape.
    public var id: String {
        switch self {
        case .china: "trae"
        case .international: "trae-intl"
        }
    }

    public var name: String {
        switch self {
        case .china: "Trae CN"
        case .international: "Trae"
        }
    }

    /// The remote session gate. The agent and IDE endpoints hang off its
    /// origin, not off `/api/remote/v1`.
    public var remoteBase: String {
        switch self {
        case .china: "https://trae-api-cn.mchost.guru/api/remote/v1"
        case .international: "https://core-normal.trae.ai/api/remote/v1"
        }
    }

    /// Where `ExchangeToken` is posted. The international build's credential
    /// names its own account host (grow-normal.trae.ai among others); this is
    /// the one its remote gate publishes, used when the stored credential
    /// names none.
    public var oauthHost: String {
        switch self {
        case .china: "https://api.trae.cn"
        case .international: "https://core-normal.trae.ai"
        }
    }

    public init?(storeID: String) {
        guard let site = Self.allCases.first(where: { $0.id == storeID }) else { return nil }
        self = site
    }

    /// `https://host[:port]` of an address, which is what the agent and IDE
    /// endpoints hang off; nil when it names no host.
    public func origin(of address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespaces)),
              let host = components.host, !host.isEmpty
        else { return nil }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard let port = components.port else { return "\(scheme)://\(host)" }
        return "\(scheme)://\(host):\(port)"
    }

    /// Where this account's requests go: the address it was given, else the
    /// gate this build publishes.
    public func origin(base: String?) -> String {
        if let base, let origin = origin(of: base) { return origin }
        return origin(of: remoteBase) ?? remoteBase
    }
}

/// What the account's stored key is, and how to renew it.
///
/// A browser sign-in stores the JWT, its refresh token and the device ids
/// that sign-in registered; a typed key stores the Cloud-IDE-JWT itself or
/// the account's refresh token, one opaque string in the API-key form. A
/// refresh token is exchanged once for a JWT when a request first needs one,
/// and the JWT is renewed the same way when it is about to lapse.
struct TraeCredential: Sendable {
    var access: String
    var refresh: String
    /// Unix ms of the access token's expiry; `.max` for one never lapses.
    var expires: Int64
    var userID: String
    /// The 64-hex machine id the browser sign-in sent, and the 16-digit
    /// device id it registered. Nil for a typed key: that sign-in made none,
    /// and the headers then derive both from the account.
    var machineID: String?
    var deviceID: String?
    /// The gate that accepted this sign-in, which its renewals go to: the
    /// international build has several and only one serves the account.
    var oauthHost: String?

    init(_ credentials: OAuthCredentials) {
        access = credentials.access
        refresh = credentials.refresh
        expires = credentials.expires
        userID = TraeCredential.extra("userId", in: credentials) ?? ""
        machineID = TraeCredential.extra("machineId", in: credentials)
        deviceID = TraeCredential.extra("checkinDeviceId", in: credentials)
        oauthHost = TraeCredential.extra("oauthHost", in: credentials)
    }

    static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }

    /// The base an account was given, when it typed one in.
    static func base(in credentials: OAuthCredentials) -> String? {
        extra("baseUrl", in: credentials)
    }
}

/// One failure of the Trae wire, in words the user can act on.
struct TraeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The token a request goes out with, renewed through `ExchangeToken`.
///
/// One per resolution, shared by every `authResolver` call, so a renewed JWT
/// is reused rather than exchanged again per request.
actor TraeTokenStore {
    struct Token: Sendable {
        var value: String
        var userID: String
        var refresh: String = ""
        var expires: Int64 = .max
        /// The device identity the sign-in registered, for the headers.
        var machineID: String?
        var deviceID: String?
    }

    private let site: TraeSite
    private let client: HTTPClient
    private var access: String
    private var refresh: String
    private var expires: Int64
    private var userID: String
    private var machineID: String?
    private var deviceID: String?
    private var oauthHost: String?
    private var renewal: Task<Token, Error>?

    init(site: TraeSite, credential: TraeCredential, client: HTTPClient = URLSessionHTTPClient()) {
        self.site = site
        self.client = client
        access = credential.access
        refresh = credential.refresh
        expires = credential.expires
        userID = credential.userID
        machineID = credential.machineID
        deviceID = credential.deviceID
        oauthHost = credential.oauthHost
    }

    /// A token good enough for the next request: a JWT as it is until it is
    /// within five minutes of its expiry, a refresh token exchanged first.
    func current() async throws -> Token {
        let now = Date().timeIntervalSince1970 * 1000
        let fresh = expires == .max || now < Double(expires) - 5 * 60 * 1000
        if !access.isEmpty, !isRefreshToken, fresh {
            return Token(
                value: access,
                userID: userID,
                machineID: machineID,
                deviceID: deviceID,
            )
        }
        return try await renew()
    }

    /// One renewal at a time: concurrent requests await the same exchange.
    func renew() async throws -> Token {
        if let renewal { return try await renewal.value }
        let token = refresh.isEmpty ? access : refresh
        guard !token.isEmpty else {
            throw TraeError("The saved Trae token cannot be renewed. Sign in again with a new one.")
        }
        let site = site
        let client = client
        let userID = userID
        let machineID = machineID
        let deviceID = deviceID
        let oauthHost = oauthHost
        let task = Task<Token, Error> {
            let exchanged = try await TraeWire.exchangeToken(
                site: site,
                refreshToken: token,
                userID: userID,
                gate: oauthHost,
                client: client,
            )
            return Token(
                value: exchanged.access,
                userID: userID,
                refresh: exchanged.refresh,
                expires: exchanged.expires,
                machineID: machineID,
                deviceID: deviceID,
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
            renewal = nil
            return renewed
        } catch {
            renewal = nil
            throw error
        }
    }

    /// A JWT carries two dots; a refresh token does not.
    private var isRefreshToken: Bool {
        access.filter { $0 == "." }.count < 2
    }
}

// MARK: - The wire

/// Trae's chat channel and its model directory.
///
/// Chats go over `llm_utils_chat`, not `chat_sessions`: the latter runs the
/// model in Trae's own cloud sandbox, which executes tools itself and never
/// hands a `tool_calls` back. `llm_utils_chat` is the raw LLM proxy the IDE's
/// agent uses — the caller's tools pass through and pending calls stream
/// back to the caller.
public enum TraeWire {
    static let appID = "6eefa01c-1036-4c7e-9ca5-d891f63bfcd8"
    /// The SOLO generation's build, which the chat gate and the directory
    /// both read. The three version values are one set: a capture proved
    /// `x-ide-version-code: 20260820`, `x-ide-version: 0.1.61` and
    /// `User-Agent: Trae/0.1.61` together are what the gate accepts, and
    /// changing any one of them alone no longer matches its configuration
    /// table. The IDE generation's `3.3.x` is a different protocol line.
    static let ideVersion = "0.1.61"
    static let versionCode = 20260820

    /// The directory functions a model may be listed under. A model is
    /// callable only through the function whose roster publishes it.
    /// `solo_work_remote` first: it carries every model a user may pick
    /// (`glm-5.3` is only here, and asking through `solo_work_lite` answers
    /// `4001 param is invalid`). `solo_work_lite` lists internal agent
    /// entries too, so it stands in only when the first one fails.
    public static let directoryFunctions = ["solo_work_remote", "solo_work_lite"]

    /// The function a model is asked through when no roster named one.
    static let defaultFunction = "solo_work_remote"

    /// The model a session talks to when none was chosen.
    public static let defaultModel = "auto"

    static func chatURL(origin: String) -> URL? {
        URL(string: origin + "/api/agent/v3/llm_utils_chat")
    }

    static func directoryURL(origin: String) -> URL? {
        URL(string: origin + "/api/ide/v1/get_detail_param")
    }

    /// The headers every Trae request carries, whatever the account.
    static func clientHeaders() -> [String: String] {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "x-plugin-channel": "icube-ai",
            "x-app-id": appID,
            "x-device-type": "ios",
            "x-device-cpu": "arm64",
            "x-os-version": "iOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            "x-ide-version-type": "stable",
            "x-app-version": ideVersion,
            "x-ide-version": ideVersion,
            "x-app-version-code": String(versionCode),
            "x-ide-version-code": String(versionCode),
            "request-traffic-type": "prod",
            "User-Agent": "Trae/\(ideVersion)",
        ]
    }

    /// The headers naming the account: its token in the three places the
    /// gate reads it, and the machine and device ids the browser sign-in
    /// registered. A typed key made neither, so both are derived from the
    /// account — there is no Trae install here to read them from.
    static func accountHeaders(
        token: String,
        userID: String,
        machineID registeredMachineID: String? = nil,
        deviceID: String? = nil,
    ) -> [String: String] {
        let trace = traceID()
        let machine = registeredMachineID ?? machineID(account: userID.isEmpty ? token : userID)
        return [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-Ide-Token": token,
            "X-Cloudide-Token": token,
            "x-uid": userID,
            "x-machine-id": machine,
            "x-device-id": deviceID ?? machine,
            "x-custom-trace-id": trace,
            "x-flow-traceparent": "04-\(trace)-\(trace.prefix(16))-01",
        ]
    }

    static func traceID() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< 32).map { _ in "0123456789abcdef".randomElement(using: &generator) ?? "0" })
    }

    /// 32 hex digits, the same for one account across requests and renewals.
    static func machineID(account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// `POST {gate}/cloudide/api/v3/trae/oauth/ExchangeToken`.
    ///
    /// `gate` is the one the sign-in recorded: the international build has
    /// several, and a refresh token only renews against the one that issued
    /// it. Without one — a typed key — the build's own default is used.
    static func exchangeToken(
        site: TraeSite,
        refreshToken: String,
        userID: String,
        gate: String? = nil,
        client: HTTPClient,
    ) async throws -> (access: String, refresh: String, expires: Int64) {
        guard let url = URL(string: "\(gate ?? site.oauthHost)/cloudide/api/v3/trae/oauth/ExchangeToken") else {
            throw TraeError("The Trae sign-in address could not be read.")
        }
        let body: [String: Any] = [
            "ClientID": "ono9krqynydwx5",
            "RefreshToken": refreshToken,
            "ClientSecret": "-",
            "UserID": userID,
        ]
        let (response, data) = try await client.request(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json", "Accept": "application/json"],
            body: try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            cancellation: nil,
        )
        guard response.statusCode == 200, data.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = (root["Result"] ?? root["result"]) as? [String: Any],
              let access = (result["Token"] ?? result["token"]) as? String, !access.isEmpty
        else {
            throw TraeError(
                response.statusCode == 401 || response.statusCode == 403
                    ? "Trae refused this token. Sign in again with a new one."
                    : "The Trae token could not be renewed (HTTP \(response.statusCode)).",
            )
        }
        let refresh = (result["RefreshToken"] ?? result["refreshToken"]) as? String ?? refreshToken
        return (access, refresh, expiry(result["TokenExpireAt"] ?? result["tokenExpireAt"]))
    }

    /// `TokenExpireAt` is Unix seconds or milliseconds, or a date string; an
    /// entry that says neither never lapses.
    static func expiry(_ raw: Any?) -> Int64 {
        func unix(_ value: Double) -> Int64 {
            let milliseconds = Int64(value)
            return milliseconds > 1_000_000_000_000 ? milliseconds : milliseconds * 1000
        }
        if let number = raw as? NSNumber, number.int64Value > 0 {
            return unix(number.doubleValue)
        }
        guard let text = raw as? String, !text.isEmpty else { return .max }
        if let seconds = Double(text), seconds > 0 { return unix(seconds) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return .max
    }

    // MARK: Request body

    /// A request body as `llm_utils_chat` takes it.
    ///
    /// The OpenAI body kwwk encodes is kept for its messages, tools and
    /// reasoning effort; everything else is this wire's own: the model's
    /// `config_name`, the directory `function` that lists it, and the
    /// scalar fields the gate reads as ints and strings.
    static func mending(_ root: inout [String: Any], function: String) {
        let model = root["model"] as? String ?? ""
        var body: [String: Any] = [
            "app_id": appID,
            "app_version_code": versionCode,
            "function": function,
            "model": model,
            "config_name": model,
            "stream": true,
            "messages": mendMessages(root["messages"] as? [[String: Any]] ?? []),
        ]
        if let tools = root["tools"] as? [[String: Any]], !tools.isEmpty {
            body["tools"] = mendTools(tools)
        }
        if let effort = root["reasoning_effort"] as? String, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        root = body
    }

    /// `llm_utils_chat` takes every message's content as text blocks. These
    /// are the mends the reference client makes: `developer` becomes
    /// `system`; an interrupted assistant turn's null or empty content
    /// becomes an empty block, which the upstream's validator accepts where
    /// it refuses null for every later request of that conversation; an
    /// assistant turn with neither text nor calls goes; and its `tool_calls`
    /// are read back as `function_call`.
    static func mendMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for var message in messages {
            if (message["role"] as? String) == "developer" {
                message["role"] = "system"
            }
            let role = message["role"] as? String ?? "user"
            let calls = message["tool_calls"] as? [[String: Any]]
            let hasContent: Bool = {
                if let text = message["content"] as? String { return !text.isEmpty }
                if let blocks = message["content"] as? [[String: Any]] { return !blocks.isEmpty }
                return false
            }()
            if role == "assistant", !hasContent, (calls ?? []).isEmpty { continue }
            message["content"] = textBlocks(message["content"])
            message.removeValue(forKey: "reasoning_content")
            message.removeValue(forKey: "reasoning_details")
            if role == "assistant", let calls, !calls.isEmpty {
                message["function_call"] = calls
                message.removeValue(forKey: "tool_calls")
            }
            out.append(message)
        }
        return out
    }

    /// A message's content as `[{type: "text", text: …}]`. A bare string is
    /// wrapped; text blocks are kept; anything else (an image, which this
    /// wire does not take) is left out.
    static func textBlocks(_ content: Any?) -> [[String: Any]] {
        switch content {
        case let text as String:
            return [["type": "text", "text": text]]
        case let blocks as [[String: Any]]:
            return blocks.compactMap { block in
                guard (block["type"] as? String) == "text", let text = block["text"] as? String else { return nil }
                return ["type": "text", "text": text]
            }
        default:
            return [["type": "text", "text": ""]]
        }
    }

    /// `parameters` is a JSON *string* on this wire, not an object.
    static func mendTools(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard var function = tool["function"] as? [String: Any] else { return nil }
            if let parameters = function["parameters"], !(parameters is NSNull),
               let data = try? JSONSerialization.data(withJSONObject: parameters),
               let text = String(data: data, encoding: .utf8) {
                function["parameters"] = text
            } else {
                function["parameters"] = #"{"type":"object","properties":{}}"#
            }
            return ["type": "function", "function": function]
        }
    }

    // MARK: Response frames

    /// What one upstream frame became: the OpenAI data lines to yield, and
    /// whether it carried an answer, closed the turn, or failed.
    struct Translation {
        var lines: [Data] = []
        /// Text, thinking or tool calls the caller can read.
        var answers = false
        /// The turn is over: its finish reason or its refusal has gone out.
        var ends = false
        /// The stream must stop reading this turn.
        var finished = false
        var failed = false
    }

    /// One upstream SSE frame as the OpenAI data lines
    /// `OpenAICompletionsProvider` reads.
    ///
    /// Upstream is `event: output` with `{response, reasoning_content,
    /// tool_calls}`, `event: token_usage`, `event: error {code, message}` and
    /// `event: done {finish_reason}` — no `choices` anywhere, so nothing
    /// downstream would read it as it comes.
    static func translated(event: String, data: String) -> Translation {
        var out = Translation()
        // A frame with no event name is the gateway's default, `output`.
        let named = event.isEmpty || event == "message" ? "output" : event
        guard let root = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
            return out
        }
        // A queue refusal arrives as a 200 frame carrying its own status.
        if let status = root["statusCodeValue"] as? Int, status != 200 {
            let body = String(describing: root["body"] ?? "")
            out.lines = [errorFrame("Trae answered \(status): \(body.prefix(240))")]
            out.ends = true
            out.finished = true
            out.failed = true
            return out
        }
        switch named {
        case "error":
            let code = root["code"].map { String(describing: $0) } ?? ""
            let message = root["message"] as? String ?? "unknown"
            out.lines = [errorFrame("Trae \(code.isEmpty ? "error" : "code \(code)"): \(message)")]
            out.ends = true
            out.finished = true
            out.failed = true
        case "token_usage":
            out.lines = [usageFrame(root)]
        case "done":
            out.lines = [finishFrame(finishReason(root["finish_reason"] as? String))]
            out.ends = true
            out.finished = true
        case "output":
            if let reasoning = root["reasoning_content"] as? String, !reasoning.isEmpty {
                out.lines.append(deltaFrame(["reasoning_content": reasoning]))
                out.answers = true
            }
            if let text = root["response"] as? String, !text.isEmpty {
                out.lines.append(deltaFrame(["content": text]))
                out.answers = true
            }
            if let calls = root["tool_calls"] as? [[String: Any]] {
                for (position, call) in calls.enumerated() {
                    if let frame = toolCallFrame(call, position: position) {
                        out.lines.append(frame)
                        out.answers = true
                    }
                }
            }
        default:
            break
        }
        return out
    }

    /// The finish reason the callers read. The gate labels a tool-call turn
    /// `stop` as often as `tool_calls`, so a turn that streamed calls says it
    /// called them.
    static func finishReason(_ raw: String?) -> String {
        let reason = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        switch reason {
        case "", "stop", "end": return "stop"
        case "length", "max_tokens": return "length"
        case "tool_calls", "function_call": return "tool_calls"
        default: return reason
        }
    }

    static func toolCallFrame(_ call: [String: Any], position: Int) -> Data? {
        let function = (call["function_call"] ?? call["function"]) as? [String: Any] ?? [:]
        var fields: [String: Any] = [:]
        if let name = function["name"] as? String, !name.isEmpty { fields["name"] = name }
        if let arguments = function["arguments"] as? String, !arguments.isEmpty { fields["arguments"] = arguments }
        guard !fields.isEmpty else { return nil }
        var entry: [String: Any] = [
            "index": (call["index"] as? NSNumber)?.intValue ?? position,
            "type": "function",
            "function": fields,
        ]
        if let id = call["id"] as? String, !id.isEmpty { entry["id"] = id }
        return deltaFrame(["tool_calls": [entry]])
    }

    static func deltaFrame(_ delta: [String: Any]) -> Data {
        sseData(["choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]]])
    }

    static func finishFrame(_ reason: String) -> Data {
        sseData(["choices": [["index": 0, "delta": [String: Any](), "finish_reason": reason]]])
    }

    static func usageFrame(_ root: [String: Any]) -> Data {
        func number(_ key: String) -> Int {
            (root[key] as? NSNumber)?.intValue ?? 0
        }
        let usage: [String: Any] = [
            "prompt_tokens": number("prompt_tokens"),
            "completion_tokens": number("completion_tokens"),
            "total_tokens": number("total_tokens"),
        ]
        return sseData(["choices": [Any](), "usage": usage])
    }

    static func errorFrame(_ message: String) -> Data {
        sseData(["error": ["message": message, "type": "upstream_error"]])
    }

    static func sseData(_ object: [String: Any]) -> Data {
        guard let json = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return Data("data: {}\n\n".utf8)
        }
        var out = Data("data: ".utf8)
        out.append(json)
        out.append(Data("\n\n".utf8))
        return out
    }

    static let doneFrame = Data("data: [DONE]\n\n".utf8)

    // MARK: Model directory

    /// One model as the directory publishes it, with the function that lists
    /// it — the only one the model may be asked through.
    public struct Entry: Sendable, Hashable {
        public var id: String
        public var function: String
        public var reasoning: Bool
        public var contextWindow: Int
        public var maxTokens: Int
    }

    /// The roster served before (or instead of) a live one. New upstream
    /// models appear as soon as the directory answers.
    /// The models a Trae CN account may pick, when its directory answers
    /// nothing. Every one is reachable through `solo_work_remote`, which a
    /// capture confirmed; the eleven are the client's own catalogue with the
    /// five entries the SOLO channel cannot call left out.
    public static let fallbackModels = [
        Entry(id: defaultModel, function: defaultFunction, reasoning: false, contextWindow: 200_000, maxTokens: 64_000),
        Entry(id: "Doubao-Seed-Evolving", function: defaultFunction, reasoning: false, contextWindow: 262_144, maxTokens: 64_000),
        Entry(id: "Doubao-Seed-2.1-Pro", function: defaultFunction, reasoning: true, contextWindow: 262_144, maxTokens: 64_000),
        Entry(id: "Doubao-Seed-2.1-Turbo", function: defaultFunction, reasoning: true, contextWindow: 262_144, maxTokens: 32_000),
        Entry(id: "glm-5.3", function: defaultFunction, reasoning: true, contextWindow: 119_040, maxTokens: 64_000),
        Entry(id: "glm-5.2", function: defaultFunction, reasoning: true, contextWindow: 119_040, maxTokens: 64_000),
        Entry(id: "DeepSeek-V4-Flash-Official", function: defaultFunction, reasoning: true, contextWindow: 119_040, maxTokens: 64_000),
        Entry(id: "DeepSeek-V4-Pro-Official", function: defaultFunction, reasoning: true, contextWindow: 119_040, maxTokens: 64_000),
        Entry(id: "kimi-k3", function: defaultFunction, reasoning: true, contextWindow: 204_800, maxTokens: 64_000),
        Entry(id: "minimax-m3", function: defaultFunction, reasoning: false, contextWindow: 119_040, maxTokens: 64_000),
        Entry(id: "qwen3.8-max", function: defaultFunction, reasoning: true, contextWindow: 204_800, maxTokens: 64_000),
        Entry(id: "qwen-3.7-plus", function: defaultFunction, reasoning: false, contextWindow: 204_800, maxTokens: 64_000),
    ]

    /// `POST {origin}/api/ide/v1/get_detail_param` for one function.
    static func directoryRequest(origin: String, function: String, headers: [String: String]) -> URLRequest? {
        guard let url = directoryURL(origin: origin) else { return nil }
        // Short: the account verification that reads this roster has 45
        // seconds for the whole sign-in.
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        for (name, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "function": function,
            "config_names": NSNull(),
            "need_prompt": false,
            "current_config_info": NSNull(),
            "poly_prompt": true,
            "mode_type": NSNull(),
            "agent_type": NSNull(),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Every function's roster, the first listing of an id winning. Entries
    /// the IDE never shows an agent (sub-agents, summarizers, internal
    /// helpers) are left out.
    static func entries(in document: [String: Any], function: String) -> [Entry] {
        let list = document["config_info_list"] as? [[String: Any]] ?? []
        return list.compactMap { raw in
            guard let id = raw["config_name"] as? String, !id.isEmpty, !isHidden(id),
                  raw["is_invisible_to_user"] as? Bool != true
            else { return nil }
            let display = raw["display_config"] as? [String: Any] ?? [:]
            let context = raw["context_window_tokens"] as? [String: Any] ?? [:]
            let detail = (raw["model_detail_list"] as? [[String: Any]])?.first ?? [:]
            let window = (context["dev"] as? NSNumber)?.intValue
                ?? (detail["prompt_max_tokens"] as? NSNumber)?.intValue ?? 0
            let maxTokens = (detail["max_tokens"] as? NSNumber)?.intValue ?? 0
            return Entry(
                id: id,
                function: function,
                reasoning: (display["model_capability"] as? String) == "reasoning_model",
                contextWindow: window > 0 ? window : 200_000,
                maxTokens: maxTokens > 0 ? maxTokens : 64_000,
            )
        }
    }

    static func isHidden(_ id: String) -> Bool {
        if id.hasPrefix("custom_model_") || id.hasPrefix("search_agent") { return true }
        // The directory lists the agent's own internal entries beside the
        // models a user may pick; no user-facing id carries `agent` in it.
        if id.contains("agent") { return true }
        if id.contains("_advisor") || id.hasSuffix("_auto") { return true }
        for prefix in ["summary", "title_generation", "input_optimization", "fast_apply"] where id.hasPrefix(prefix) {
            return true
        }
        return id == "sagitta" || id == "aquila"
    }

    /// The live roster: every function asked at once, the first listing of an
    /// id kept, in the order the functions are declared. Failures are left
    /// out, so an unreachable function costs only its own models.
    ///
    /// Kept for ten minutes per origin: a session resolves its provider on
    /// every open, and the roster is the same answer each time.
    static func roster(origin: String, token: TraeTokenStore.Token) async -> [Entry] {
        if let cached = RosterCache.shared.roster(for: origin) { return cached }
        let roster = await fetchRoster(origin: origin, token: token)
        if !roster.isEmpty { RosterCache.shared.store(roster, for: origin) }
        return roster
    }

    private static func fetchRoster(origin: String, token: TraeTokenStore.Token) async -> [Entry] {
        let headers = clientHeaders().merging(
            accountHeaders(
                token: token.value,
                userID: token.userID,
                machineID: token.machineID,
                deviceID: token.deviceID,
            ),
        ) { _, new in
            new
        }
        let functions = directoryFunctions
        let answers = await withTaskGroup(of: (Int, [Entry]).self) { group in
            for (index, function) in functions.enumerated() {
                guard let request = directoryRequest(origin: origin, function: function, headers: headers) else {
                    continue
                }
                group.addTask {
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200,
                          data.count <= 4 * 1024 * 1024,
                          let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    else { return (index, []) }
                    return (index, entries(in: document, function: function))
                }
            }
            var collected: [(Int, [Entry])] = []
            for await answer in group { collected.append(answer) }
            return collected
        }
        var seen: Set<String> = []
        var roster: [Entry] = []
        for (_, listed) in answers.sorted(by: { $0.0 < $1.0 }) {
            for entry in listed where seen.insert(entry.id).inserted {
                roster.append(entry)
            }
        }
        return roster
    }

    /// The function a model is asked through: the one its roster published
    /// it under, else the default.
    static func function(for modelID: String) -> String {
        fallbackModels.first { $0.id == modelID }?.function ?? defaultFunction
    }
}

/// The rosters this process has read, per origin, for ten minutes. A session
/// resolves its provider on every open and every model switch; the gate's
/// answer does not change that often, and the directory costs five requests.
final class RosterCache: @unchecked Sendable {
    static let shared = RosterCache()

    private let lock = NSLock()
    private var entries: [String: (roster: [TraeWire.Entry], at: Date)] = [:]
    private let lifetime: TimeInterval = 10 * 60

    // Swift-only types: Objective-C cannot carry `TraeWire.Entry`, so these
    // stay plain (AGENTS.md ▸ Hard rules).
    func roster(for origin: String) -> [TraeWire.Entry]? {
        lock.withLock {
            guard let entry = entries[origin], Date().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.roster
        }
    }

    func store(_ roster: [TraeWire.Entry], for origin: String) {
        lock.withLock { entries[origin] = (roster, Date()) }
    }
}

// MARK: - Provider

/// Trae's chat, over `OpenAICompletionsProvider`: its frames are rewritten
/// into OpenAI chunks on the way through the client, so the body shaping and
/// the stream decoding stay kwwk's.
public struct TraeProvider: APIProvider {
    public let api = "openai-completions"
    public let site: TraeSite
    private let completions: OpenAICompletionsProvider

    public init(
        site: TraeSite,
        origin: String,
        functions: [String: String] = [:],
        client: HTTPClient = URLSessionHTTPClient(),
    ) {
        self.site = site
        var headers = TraeWire.clientHeaders()
        headers["Accept"] = "text/event-stream"
        let url = TraeWire.chatURL(origin: origin) ?? URL(string: site.remoteBase)!
        completions = OpenAICompletionsProvider(
            client: TraeChatClient(inner: client),
            defaultBaseURL: url,
            extraHeaders: headers,
            urlBuilder: { _, _, fallback in fallback },
            bodyDecorator: { root, model, _, _ in
                let function = functions[model.id] ?? TraeWire.function(for: model.id)
                TraeWire.mending(&root, function: function)
            },
        )
    }

    public func stream(model: Model, context: Context, options: StreamOptions?) -> AssistantMessageStream {
        completions.stream(model: model, context: context, options: options)
    }
}

/// Trae's transport: passes the shaped body through and rewrites the frame
/// stream into the OpenAI one `OpenAICompletionsProvider` reads.
struct TraeChatClient: HTTPClient {
    let inner: HTTPClient

    func stream(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        cancellation: CancellationHandle?,
    ) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let (response, upstream) = try await inner.stream(
            url: url,
            method: method,
            headers: headers,
            body: body,
            cancellation: cancellation,
        )
        // A refusal is kwwk's `ProviderFailure` to read, in the wire's own
        // shape; only a stream is rewritten.
        guard response.statusCode < 400 else { return (response, upstream) }
        return (response, Self.rewritten(upstream))
    }

    /// Reads Trae's SSE and yields OpenAI data lines. A stream that ends
    /// without its `done` frame still gets a finish reason, so an answer cut
    /// short reads as `length` rather than as a finished one.
    static func rewritten(_ upstream: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var answered = false
                var ended = false
                do {
                    for try await message in parseSSE(bytes: upstream) {
                        let data = message.data.trimmingCharacters(in: .whitespaces)
                        if data.isEmpty { continue }
                        if data == "[DONE]" { ended = true; break }
                        let frame = TraeWire.translated(event: message.event, data: data)
                        for line in frame.lines {
                            continuation.yield(line)
                        }
                        // A turn with text, thinking or calls in it is an
                        // answer even when the close frame never arrives.
                        if frame.answers { answered = true }
                        if frame.ends { ended = true }
                        if frame.failed || frame.finished { break }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                if !ended {
                    continuation.yield(
                        answered
                            ? TraeWire.finishFrame("length")
                            : TraeWire.errorFrame("Trae ended the stream without an answer."),
                    )
                }
                continuation.yield(TraeWire.doneFrame)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Registration

/// Trae's model roster as the app sees it: the directory's live one, and the
/// standing one when the directory will not answer.
public enum TraeModels {
    /// The models offered before (or instead of) a live roster.
    public static var fallback: [String] { TraeWire.fallbackModels.map(\.id) }

    /// The account's live roster, nil when the directory gave none.
    public static func live(site: TraeSite, credentials: OAuthCredentials) async -> [String]? {
        let store = TraeTokenStore(site: site, credential: TraeCredential(credentials))
        guard let token = try? await store.current() else { return nil }
        let roster = await TraeWire.roster(
            origin: site.origin(base: TraeCredential.base(in: credentials)),
            token: token,
        )
        return roster.isEmpty ? nil : roster.map(\.id)
    }
}

/// Registers Trae for account verification and session requests.
///
/// Neither build is a kwwk login, so this is Apelin's own registration, the
/// way DeepSeek's is: the credential is read through kwwk's manager, the
/// provider is registered under the site's id, and the token rides to the
/// wire in the request's headers rather than as a bearer.
enum TraeRegistration {
    static func resolve(
        site: TraeSite,
        credentials: OAuthCredentials,
        modelOverride: String? = nil,
    ) async -> ResolvedAuth {
        let base = TraeCredential.base(in: credentials)
        let origin = site.origin(base: base)
        let store = TraeTokenStore(site: site, credential: TraeCredential(credentials))
        var roster: [TraeWire.Entry] = []
        if let token = try? await store.current() {
            roster = await TraeWire.roster(origin: origin, token: token)
        }
        let entries = roster.isEmpty ? TraeWire.fallbackModels : roster
        let id = modelOverride
            ?? TraeCredential.extra("defaultModel", in: credentials)
            ?? entries.first?.id
            ?? TraeWire.defaultModel
        let entry = entries.first { $0.id == id }
        var model = Model(
            id: id,
            name: id,
            api: "openai-completions",
            provider: site.id,
            baseURL: TraeWire.chatURL(origin: origin)?.absoluteString ?? "",
            reasoning: entry?.reasoning ?? false,
        )
        model.contextWindow = entry?.contextWindow ?? 200_000
        model.maxTokens = entry?.maxTokens ?? 64_000
        let functions = Dictionary(entries.map { ($0.id, $0.function) }, uniquingKeysWith: { first, _ in first })
        await APIRegistry.shared.register(
            TraeProvider(site: site, origin: origin, functions: functions),
            scope: site.id,
        )
        return ResolvedAuth(model: model, modelLabel: "\(id) · \(site.name)", authResolver: { _, _ in
            do {
                let token = try await store.current()
                return ResolvedProviderAuth(
                    token: nil,
                    scheme: .none,
                    headers: TraeWire.accountHeaders(
                        token: token.value,
                        userID: token.userID,
                        machineID: token.machineID,
                        deviceID: token.deviceID,
                    ),
                )
            } catch {
                throw ApelinError(.denied, error.localizedDescription)
            }
        })
    }
}
