@testable import ApelinAgentWorker
import ApelinAgent
import CryptoKit
import Foundation
import KWWKAI
import Network
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Trae's browser sign-in, both builds: the page's URL, the redirect it
/// answers with, and the exchange that turns that into a credential.
///
/// The constants are the clients' own, so these tests pin the things that
/// fail silently when they are wrong — `client_id` snake_case on the page
/// and `ClientID` PascalCase in the exchange body, the parameters a page
/// needs before it calls back at all, and the device block the service
/// validates.
@Suite(.timeLimit(.minutes(1)))
struct TraeOAuthTests {
    // MARK: - The sign-in page

    @Test
    func `the China page carries the client's parameters in its order`() throws {
        let pkce = PKCE(verifier: "verifier", challenge: "challenge")
        let url = try TraeOAuth.loginURL(
            loginHost: "https://www.trae.cn",
            redirect: "http://127.0.0.1:53692/authorize",
            machineID: String(repeating: "a", count: 64),
            deviceID: "2996599860772203",
            loginTraceID: "trace-1",
            pkce: pkce,
            profile: .china,
        )
        #expect(url.absoluteString.hasPrefix("https://www.trae.cn/authorization?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.map(\.name) == [
            "login_version", "auth_from", "login_channel", "plugin_version", "auth_type",
            "client_id", "redirect", "login_trace_id", "auth_callback_url", "machine_id",
            "device_id", "x_device_id", "x_machine_id", "x_device_brand", "x_device_type",
            "x_os_version", "x_env", "x_app_version", "x_app_type", "code_challenge",
            "code_challenge_method", "channel_name",
        ])
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        // snake_case here: the page reads `get("client_id")` and a page that
        // cannot find it shows "authenticating" for ever.
        #expect(values["client_id"] == "ono9krqynydwx5")
        #expect(values["clientID"] == nil)
        // Each of these, missing, is a page that neither errors nor calls back.
        #expect(values["auth_type"] == "local")
        #expect(values["login_channel"] == "native_ide")
        #expect(values["login_version"] == "1")
        #expect(values["plugin_version"] == "2.3.83560")
        #expect(values["x_app_version"] == "3.3.100")
        // `S256`, not `SHA-256`: the page compares the literal.
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"] == "challenge")
        #expect(values["auth_callback_url"] == "http://127.0.0.1:53692/authorize")
        #expect(values["redirect"] == "0")
        #expect(values["channel_name"] == "common")
        #expect(values["device_id"] == values["x_device_id"])
        #expect(values["machine_id"] == values["x_machine_id"])
    }

    /// The international build's page differs where its client differs: the
    /// plugin version is `local`, the app version is the one it is built as,
    /// the device it describes is `unknown`, and its `device_id` is the
    /// constant the client sends rather than a generated one.
    @Test
    func `the international page carries that build's values`() throws {
        let pkce = PKCE(verifier: "verifier", challenge: "challenge")
        let url = try TraeOAuth.loginURL(
            loginHost: "www.trae.ai",
            redirect: "http://127.0.0.1:53692/authorize",
            machineID: "0f8b2a4c-1d3e-4a5b-9c7d-2e1f0a3b4c5d",
            deviceID: "0",
            loginTraceID: "trace-1",
            pkce: pkce,
            profile: .international,
        )
        // The host it was told to open is the one it opens, bare host and all.
        #expect(url.absoluteString.hasPrefix("https://www.trae.ai/authorization?"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(values["plugin_version"] == "local")
        #expect(values["x_app_version"] == "3.5.54")
        #expect(values["x_device_brand"] == "unknown")
        #expect(values["x_device_type"] == "unknown")
        #expect(values["x_os_version"] == "unknown")
        #expect(values["device_id"] == "0")
        #expect(values["machine_id"] == "0f8b2a4c-1d3e-4a5b-9c7d-2e1f0a3b4c5d")
        // It sends no channel name, and the China one does.
        #expect(values["channel_name"] == nil)
        #expect(values["client_id"] == "ono9krqynydwx5")
        #expect(values["code_challenge_method"] == "S256")
    }

    @Test
    func `the device id is sixteen decimal digits and the machine id is 64 hex`() {
        for _ in 0 ..< 20 {
            let device = TraeOAuth.randomDeviceID()
            #expect(device.count == 16)
            #expect(device.allSatisfy { $0.isNumber })
            let machine = PKCE.randomHex(bytes: 32)
            #expect(machine.count == 64)
            #expect(machine.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: - The sign-in host

    @Test
    func `the China build's page is fixed and the international one is asked for`() throws {
        // The China build does not ask: its page is the one it publishes.
        #expect(TraeOAuth.Profile.china.fixedLoginHost == "https://www.trae.cn")
        #expect(TraeOAuth.Profile.china.guidanceURLs.isEmpty)
        // The international build does, and has no fixed page.
        #expect(TraeOAuth.Profile.international.fixedLoginHost == nil)
        #expect(!TraeOAuth.Profile.international.guidanceURLs.isEmpty)

        // A gate that answers names the page, in either spelling.
        let answer = Data(#"{"Result":{"LoginHost":"https://www.trae.ai"}}"#.utf8)
        let root = try #require((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])
        #expect(TraeOAuth.guidanceHost(root) == "https://www.trae.ai")
        #expect(TraeOAuth.guidanceHost(["loginHost": "www.trae.ai"]) == "www.trae.ai")
        #expect(TraeOAuth.guidanceHost(["Result": ["loginUrl": "https://www.trae.ai"]]) == "https://www.trae.ai")
        #expect(TraeOAuth.guidanceHost(["nothing": 1]) == nil)
    }

    // MARK: - The callback

    @Test
    func `the callback is read from authCodeInfo, with the user block beside it`() throws {
        let callback = try TraeOAuth.callbackPayload([
            "authCodeInfo": #"{"AuthCode":"code-1","ExpireAt":1790801493459}"#,
            "userInfo": #"{"UserID":"user-1","ScreenName":"someone"}"#,
            "loginTraceID": "trace-1",
            "loginHost": "https://www.trae.ai",
        ])
        #expect(callback == TraeOAuth.Callback(
            authCode: "code-1",
            userID: "user-1",
            loginTraceID: "trace-1",
            loginHost: "https://www.trae.ai",
        ))
    }

    @Test
    func `a callback without an auth code is refused rather than half-read`() throws {
        // The page's non-PKCE branch hands back a refresh token instead; this
        // flow always asks for PKCE, so that answer is a failure to act on.
        #expect(throws: TraeOAuthError.self) {
            try TraeOAuth.callbackPayload(["refreshToken": "refresh-1"])
        }
        #expect(throws: TraeOAuthError.self) { try TraeOAuth.callbackPayload(["authCodeInfo": "not json"]) }
        #expect(throws: TraeOAuthError.self) { try TraeOAuth.callbackPayload([:]) }
    }

    @Test
    func `access_denied ends the sign-in cancelled, not failed`() throws {
        do {
            try TraeOAuth.checkCallbackError(["error": "access_denied"])
            Issue.record("a declined sign-in was accepted")
        } catch let error as OAuthLoginError {
            #expect(error == .cancelled)
        }
    }

    // MARK: - The exchange

    @Test
    func `the exchange posts the five fields and reads the bound device and expiry`() async throws {
        let answer = #"""
        {"ResponseMetadata":{},"Result":{"BoundDeviceID":"wl2k1e2endpp32","ClientID":"ono9krqynydwx5","DeviceBindStatus":"BOUND","RefreshExpireAt":1805143893459,"RefreshToken":"refresh-1","Token":"jwt-1","TokenExpireAt":1790801493459,"UserJwt":"user-jwt"}}
        """#
        let received = BodyBox()
        let server = try await StubServer { body in
            received.store(body)
            return (200, Data(answer.utf8))
        }
        defer { server.cancel() }
        let exchanged = try await TraeOAuth.exchange(
            authCode: "code-1",
            codeVerifier: "verifier",
            machineID: String(repeating: "a", count: 64),
            deviceID: "2996599860772203",
            profile: .china,
            client: URLSessionHTTPClient(),
            exchangeOrigins: [server.base],
        )
        #expect(exchanged.access == "jwt-1")
        #expect(exchanged.refresh == "refresh-1")
        #expect(exchanged.boundDeviceID == "wl2k1e2endpp32")
        #expect(exchanged.expires == 1790801493459)
        // The gate that answered is the one renewals go back to.
        #expect(exchanged.origin == server.base)

        let body = try #require(received.value)
        let object = try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
        // PascalCase in the body, where the page's query is snake_case.
        #expect((object["ClientID"] as? String) == "ono9krqynydwx5")
        #expect((object["AuthCode"] as? String) == "code-1")
        #expect((object["CodeVerifier"] as? String) == "verifier")
        #expect((object["IDEVersion"] as? String) == "3.3.100")
        // Both belong to the renewal endpoint, and this one refuses them.
        #expect(object["ClientSecret"] == nil)
        #expect(object["DeviceProof"] == nil)
        let device = try #require(object["DeviceInfo"] as? [String: Any])
        #expect(device.count == 12)
        #expect((device["DeviceID"] as? String) == "2996599860772203")
        #expect((device["MachineID"] as? String) == String(repeating: "a", count: 64))
        let key = try #require(device["DevicePublicKey"] as? String)
        // An empty one answers 400 "invalid parameter", so it must be real.
        #expect(key.hasPrefix("-----BEGIN PUBLIC KEY-----"))
        #expect((try? P256.Signing.PublicKey(pemRepresentation: key)) != nil)
    }

    /// The international build tries each gate in turn and keeps the one that
    /// answers: the first that refuses is not the end of the sign-in.
    @Test
    func `the international exchange falls through the gates to the one that answers`() async throws {
        let answer = #"""
        {"Result":{"AccessToken":"jwt-intl","RefreshToken":"refresh-intl","ExpiresAt":1790801493459}}
        """#
        // The first gate answers a refusal, the second the token.
        let first = try await StubServer { _ in
            (200, Data(#"{"Code":20101,"Message":"refresh token is invalid"}"#.utf8))
        }
        let second = try await StubServer { _ in
            (200, Data(answer.utf8))
        }
        defer {
            first.cancel()
            second.cancel()
        }
        let exchanged = try await TraeOAuth.exchange(
            authCode: "code-1",
            codeVerifier: "verifier",
            machineID: "0f8b2a4c-1d3e-4a5b-9c7d-2e1f0a3b4c5d",
            deviceID: "0",
            profile: .international,
            client: URLSessionHTTPClient(),
            exchangeOrigins: [first.base, second.base],
        )
        #expect(exchanged.access == "jwt-intl")
        #expect(exchanged.refresh == "refresh-intl")
        #expect(exchanged.origin == second.base)
    }

    /// The two builds' accounts do not cross over: a token the other build
    /// issued is named as the wrong build, not as a failed exchange.
    @Test
    func `a token from the other build is named as the wrong build`() async throws {
        let server = try await StubServer { _ in
            (200, Data(#"{"Code":20101,"Message":"refresh token is invalid"}"#.utf8))
        }
        defer { server.cancel() }
        for profile in [TraeOAuth.Profile.china, .international] {
            do {
                _ = try await TraeOAuth.exchange(
                    authCode: "code-1",
                    codeVerifier: "verifier",
                    machineID: String(repeating: "a", count: 64),
                    deviceID: "0",
                    profile: profile,
                    client: URLSessionHTTPClient(),
                    exchangeOrigins: [server.base],
                )
                Issue.record("a refusal from the other build was read as a sign-in")
            } catch let error as TraeOAuthError {
                #expect(error.message.contains("belongs to"))
            }
        }
    }

    @Test
    func `a refusal is read from the envelope and says so`() async throws {
        let server = try await StubServer { _ in
            (200, Data(#"{"Code":10101,"Message":"invalid parameter"}"#.utf8))
        }
        defer { server.cancel() }
        do {
            _ = try await TraeOAuth.exchange(
                authCode: "code-1",
                codeVerifier: "verifier",
                machineID: String(repeating: "a", count: 64),
                deviceID: "2996599860772203",
                profile: .china,
                client: URLSessionHTTPClient(),
                exchangeOrigins: [server.base],
            )
            Issue.record("a refusal was read as a sign-in")
        } catch let error as TraeOAuthError {
            #expect(error.message.contains("invalid parameter"))
        }
    }

    @Test
    func `a JWT whose callback carried no user block still names its account`() throws {
        // base64url("{"user_id":"user-1"}"), one dot on each side.
        let payload = "eyJ1c2VyX2lkIjoidXNlci0xIn0"
        #expect(TraeOAuth.jwtUserID("head.\(payload).tail") == "user-1")
        #expect(TraeOAuth.jwtUserID("not-a-jwt") == "")
    }

    // MARK: - The loopback

    @Test
    func `the loopback answers the page's redirect and ignores a probe`() async throws {
        let loopback = TraeLoopback()
        try await loopback.listen()
        defer { loopback.stop() }
        let redirect = loopback.redirectURI
        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/authorize"))

        let callback = Task {
            try await loopback.waitForCallback()
        }
        // A probe that carries nothing is answered and the flow keeps
        // waiting: a scanner must not end a sign-in the user is completing.
        let probe = try await Self.get(redirect)
        #expect(probe == 400)
        #expect(!callback.isCancelled)

        let page = redirect + "?authCodeInfo="
            + Self.percentEncoded(#"{"AuthCode":"code-1"}"#)
            + "&loginTraceID=trace-1"
        let status = try await Self.get(page)
        #expect(status == 200)
        let parameters = try await callback.value
        #expect(parameters["authCodeInfo"] != nil)
        #expect(parameters["loginTraceID"] == "trace-1")
    }

    // MARK: - Helpers

    private static func percentEncoded(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The status code one request answers with.
    private static func get(_ address: String) async throws -> Int {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 15
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

/// What the stub server was sent, for the test to read after the call.
private final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?

    func store(_ data: Data) {
        lock.withLock { body = data }
    }

    var value: Data? {
        lock.withLock { body }
    }
}

/// A one-shot HTTP server on a free loopback port, answering one POST with
/// whatever the test decides.
private final class StubServer: @unchecked Sendable {
    let base: String
    private let listener: NWListener

    init(answering answer: @escaping @Sendable (Data) -> (Int, Data)) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let (ports, ready) = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let bound = listener.port?.rawValue {
                    ready.yield(bound)
                } else {
                    ready.finish()
                }
            case .failed:
                ready.finish()
            default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue(label: "trae-stub"))
            Self.receive(connection, collected: Data(), answering: answer)
        }
        listener.start(queue: DispatchQueue(label: "trae-stub-listener"))
        var iterator = ports.makeAsyncIterator()
        guard let bound = await iterator.next() else {
            throw TraeOAuthError("The stub server could not bind a port.")
        }
        base = "http://127.0.0.1:\(bound)"
    }

    func cancel() {
        listener.cancel()
    }

    private static func receive(
        _ connection: NWConnection,
        collected: Data,
        answering answer: @escaping @Sendable (Data) -> (Int, Data),
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, ended, error in
            var collected = collected
            if let data { collected.append(data) }
            guard let separator = collected.range(of: Data("\r\n\r\n".utf8)) else {
                if ended || error != nil || collected.count > 65536 {
                    connection.cancel()
                    return
                }
                receive(connection, collected: collected, answering: answer)
                return
            }
            let head = String(decoding: collected[..<separator.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n")
                .first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
            let body = collected[separator.upperBound...]
            guard body.count >= length else {
                if ended || error != nil {
                    connection.cancel()
                    return
                }
                receive(connection, collected: collected, answering: answer)
                return
            }
            let (status, payload) = answer(Data(body.prefix(length)))
            var response = Data(
                ("HTTP/1.1 \(status) OK\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \(payload.count)\r\n"
                    + "Connection: close\r\n\r\n").utf8,
            )
            response.append(payload)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
