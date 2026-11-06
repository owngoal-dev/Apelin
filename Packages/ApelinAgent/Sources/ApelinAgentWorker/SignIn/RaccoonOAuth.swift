import ApelinAgent
import Foundation
import KWWKAI

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Raccoon's sign-in: the web-authorisation flow its own desktop client runs.
///
/// Raccoon (`xiaohuanxiong.com`) is SenseTime's application, apart from its
/// model platform (`token.sensenova.cn`): its own accounts, its own gate, its
/// own credits. The desktop client signs in by opening the portal's authorisation
/// page and taking back an authorisation code through a custom URL scheme:
///
/// 1. `GET https://xiaohuanxiong.com/code/authorize?login_source=desktop&appname=<client name>&state=<state>`
///    answers `307` to `/authorize`, the page that signs the account in;
/// 2. the page signs the account in — a phone number, WeChat, or a QR code,
///    its choice — and redirects to `office-raccoon://auth/callback?code=…&state=…`;
/// 3. `POST /api/web/auth/v1/login_with_authorization_code` with
///    `{authorization_code}` answers the access token, its refresh token, and
///    the office identity, name and role that gate the account's calls.
///
/// The custom scheme is why this flow keeps no listener: the page redirects to
/// an address nothing here can bind, so the redirect is read back the way a
/// pasted one is — Safari shows it in its address bar after the page has done
/// its work, and the sheet offers to take it. `AccountDesk` already wires that
/// path for every browser flow (`PasteableLoopback`), so this flow reuses it
/// rather than binding a port the page will never call.
///
/// Values a capture established, each of which fails silently when wrong:
/// `login_source` is `desktop` (the page chooses its client by it), `appname`
/// is the client's own Chinese name and must be percent-encoded, and the
/// callback's scheme, host and path are compared one by one rather than by
/// prefix — `office-raccoon://auth/callback@evil.example` would pass a prefix
/// test and take the code elsewhere.
enum RaccoonOAuth {
    // MARK: - The client's own values

    static let origin = "https://xiaohuanxiong.com"
    static let authorizePath = "/code/authorize"
    /// The web-auth family: sign-in by authorisation code, and renewal.
    static let authBase = "https://xiaohuanxiong.com/api/web/auth/v1"
    static let loginSource = "desktop"
    /// The name the page reports this client as. The desktop client's own.
    static let appName = "办公小浣熊客户端"
    /// The address the page redirects to; nothing here binds it.
    static let callbackScheme = "office-raccoon"
    static let callbackHost = "auth"
    static let callbackPath = "/callback"

    /// The credential's extras, read back by `RaccoonCredential`.
    static let officeIdentityExtra = "officeIdentity"
    static let officeOrgNameExtra = "officeOrgName"
    static let officeOrgRoleExtra = "officeOrgRole"

    // MARK: - The sign-in

    /// Runs the whole flow, ending with the credential to store.
    ///
    /// The redirect is read through `callbacks.loopback`'s paste path, which
    /// `AccountDesk` wraps for every browser flow: this binds a listener it
    /// never receives a call on, so a flow that is only ever reached by a pasted
    /// address still has one object to wait on.
    static func login(
        callbacks: OAuthLogin.Callbacks,
        client: HTTPClient = URLSessionHTTPClient(),
    ) async throws -> OAuthCredentials {
        let state = try randomState()
        let listener = try callbacks.loopback("127.0.0.1", 0, callbackPath)
        try await listener.listen()
        defer { listener.stop() }

        let page = try authorizeURL(state: state)
        callbacks.onProgress("Sign in to Raccoon in the browser, then paste the address it opens.")
        let parameters = try await present(page, callbacks: callbacks) {
            try await listener.waitForCallback()
        }
        try checkCallbackError(parameters)

        let code = try callbackCode(parameters, expectedState: state)
        let exchanged = try await exchange(authCode: code, client: client)

        var credentials = OAuthCredentials(
            access: exchanged.access,
            refresh: exchanged.refresh,
            expires: exchanged.expires,
        )
        if !exchanged.officeIdentity.isEmpty {
            credentials.extras[officeIdentityExtra] = .string(exchanged.officeIdentity)
        }
        if !exchanged.officeOrgName.isEmpty {
            credentials.extras[officeOrgNameExtra] = .string(exchanged.officeOrgName)
        }
        if !exchanged.officeOrgRole.isEmpty {
            credentials.extras[officeOrgRoleExtra] = .string(exchanged.officeOrgRole)
        }
        return credentials
    }

    /// `https://xiaohuanxiong.com/code/authorize?login_source=desktop&appname=…&state=…`
    ///
    /// The page answers `307` to `/authorize`; the redirect is left to the
    /// browser, since the page it lands on is the one that signs the account in.
    /// `appname` is Chinese and must be percent-encoded: built through
    /// `URLComponents` rather than a string, which encodes it and the callback
    /// address's own `://` correctly.
    static func authorizeURL(state: String) throws -> URL {
        var components = URLComponents(string: origin + authorizePath)
        components?.queryItems = [
            URLQueryItem(name: "login_source", value: loginSource),
            URLQueryItem(name: "appname", value: appName),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw RaccoonOAuthError("The Raccoon sign-in address could not be built.")
        }
        return url
    }

    // MARK: - The callback

    /// The authorisation code the page redirected with.
    ///
    /// The state is compared when the page sent one: a redirect that names
    /// another state is not this sign-in's, and taking its code would sign
    /// the account in to a flow it did not start. A redirect that omits the
    /// state is taken, since some clients drop it, and the code itself is
    /// single-use.
    static func callbackCode(_ parameters: [String: String], expectedState: String) throws -> String {
        let code = (parameters["code"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            throw RaccoonOAuthError("The Raccoon page did not return a sign-in code. Sign in again.")
        }
        if let state = parameters["state"], !state.isEmpty, state != expectedState {
            throw RaccoonOAuthError("The Raccoon page returned another sign-in's code. Sign in again.")
        }
        return code
    }

    // MARK: - The exchange

    struct Exchanged: Sendable {
        var access: String
        var refresh: String
        var officeIdentity: String
        var officeOrgName: String
        var officeOrgRole: String
        /// Unix ms of the access token's expiry; `.max` when it says none.
        var expires: Int64
    }

    /// `POST {authBase}/login_with_authorization_code`, the body one field.
    ///
    /// `200035` is the code having been spent already; any other non-zero
    /// code is the gate's own refusal, reported in its words.
    static func exchange(
        authCode: String,
        client: HTTPClient = URLSessionHTTPClient(),
        authBase: String = RaccoonOAuth.authBase,
    ) async throws -> Exchanged {
        guard let url = URL(string: authBase + "/login_with_authorization_code") else {
            throw RaccoonOAuthError("The Raccoon token address could not be read.")
        }
        let body: [String: Any] = ["authorization_code": authCode]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            throw RaccoonOAuthError("The Raccoon sign-in request could not be built.")
        }
        let (response, answer) = try await client.request(
            url: url,
            method: "POST",
            headers: ["Accept": "application/json", "Content-Type": "application/json"],
            body: data,
        )
        guard answer.count <= 1024 * 1024,
              let root = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        else {
            throw RaccoonOAuthError("The Raccoon sign-in answer could not be read (HTTP \(response.statusCode)).")
        }
        if let failure = envelopeError(root) {
            throw RaccoonOAuthError(failure == "200035"
                ? "This Raccoon sign-in code was already used. Sign in again."
                : "The Raccoon sign-in was refused: \(failure)")
        }
        guard response.statusCode == 200 else {
            throw RaccoonOAuthError("The Raccoon sign-in failed (HTTP \(response.statusCode)).")
        }
        let result = (root["data"] ?? root["Data"]) as? [String: Any] ?? root
        guard let access = firstString(result, ["access_token", "accessToken"]), !access.isEmpty else {
            throw RaccoonOAuthError("The Raccoon sign-in returned no token. Sign in again.")
        }
        return Exchanged(
            access: access,
            refresh: firstString(result, ["refresh_token", "refreshToken"]) ?? "",
            officeIdentity: firstString(result, ["office_identity", "officeIdentity"]) ?? "",
            officeOrgName: firstString(result, ["office_org_name", "officeOrgName"]) ?? "",
            officeOrgRole: firstString(result, ["office_org_role", "officeOrgRole"]) ?? "",
            expires: expiry(result["expires_at"] ?? result["expiresAt"]),
        )
    }

    // MARK: - Small helpers

    /// Sixteen random bytes as thirty-two hexadecimal digits.
    static func randomState() throws -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255, using: &generator)) }.joined()
    }

    /// `code` is a number on this gate's envelopes; `0` is success.
    static func envelopeError(_ root: [String: Any]) -> String? {
        for key in ["code", "Code"] {
            guard let value = root[key] else { continue }
            let code: Int? = if let number = value as? NSNumber {
                number.intValue
            } else if let text = value as? String {
                Int(text)
            } else {
                nil
            }
            guard let code, code != 0 else { continue }
            return String(code)
        }
        return nil
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

    /// The user leaving the page ends the sign-in `cancelled`, as everywhere
    /// else.
    static func checkCallbackError(_ parameters: [String: String]) throws {
        guard let error = parameters["error"], !error.isEmpty else { return }
        if error == "access_denied" { throw OAuthLoginError.cancelled }
        let description = parameters["error_description"].map { ": \($0)" } ?? ""
        throw OAuthLoginError.denied("Raccoon \(error)\(description)")
    }

    /// kwwk's `OAuthLogin.present`, which is internal to its module: the
    /// host's presenter when it has one, otherwise the URL to the host and
    /// the work beside it.
    static func present<Outcome: Sendable>(
        _ url: URL,
        callbacks: OAuthLogin.Callbacks,
        while work: @escaping @Sendable () async throws -> Outcome,
    ) async throws -> Outcome {
        if let browser = callbacks.browser {
            return try await browser.run(url, while: work)
        }
        callbacks.onAuthURL(url)
        return try await work()
    }
}

/// One failure of the Raccoon sign-in, in words the user can act on.
struct RaccoonOAuthError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
