import ApelinProtocol
import Foundation
import KWWKAI

/// The loopback a browser sign-in redirects to, through kwwk's own seam
/// (`OAuthLogin.Callbacks.loopback`): kwwk's NIO listener on the port the
/// provider registered, which Safari on the same device reaches, raced
/// against the address the user pastes when it does not — Safari left on
/// "cannot connect" still shows the redirect, code and state in its
/// address bar. Whichever answers first is the redirect; kwwk's flow checks
/// its state and exchanges the code as it would for its own listener.
final class PasteableLoopback: OAuthLoopbackListener, @unchecked Sendable {
    private let inner: any OAuthLoopbackListener
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    @objc private dynamic var pasted: [String: String]?
    @objc private dynamic var stopped = false

    init(inner: any OAuthLoopbackListener) {
        self.inner = inner
    }

    @objc dynamic var redirectURI: String {
        inner.redirectURI
    }

    func listen() async throws {
        try await inner.listen()
    }

    func waitForCallback() async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.inner.waitForCallback() }
            group.addTask { try await self.waitForPaste() }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    @objc dynamic func stop() {
        inner.stop()
        let waiter = lock.withLock { () -> CheckedContinuation<[String: String], Error>? in
            stopped = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    /// The redirect as the user pasted it. Its query is what the listener
    /// would have read; anything without a code or a provider error is not
    /// a redirect, and the sign-in goes on waiting.
    @objc dynamic func paste(_ text: String) throws {
        let parameters = try Self.parameters(of: text)
        let waiter = lock.withLock { () -> CheckedContinuation<[String: String], Error>? in
            if let waiter = self.waiter {
                self.waiter = nil
                return waiter
            }
            pasted = parameters
            return nil
        }
        waiter?.resume(returning: parameters)
    }

    @objc static dynamic func parameters(of text: String) throws -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let items = components.queryItems else {
            throw ApelinError(
                .badRequest,
                "This is not the address Safari showed after sign-in. Copy the full address from Safari and paste it again.",
            )
        }
        var parameters: [String: String] = [:]
        for item in items {
            if let value = item.value {
                parameters[item.name] = value
            }
        }
        // What kwwk's listener takes for a redirect: the authorization code,
        // Trae's `authCodeInfo` in its place, or a provider error.
        let isRedirect = ["code", "authCodeInfo", "error"].contains { parameters[$0]?.isEmpty == false }
        guard isRedirect else {
            throw ApelinError(
                .badRequest,
                "This address does not contain a sign-in code. Copy the full address from Safari and paste it again.",
            )
        }
        return parameters
    }

    private func waitForPaste() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: String], Error>) in
                let early = lock.withLock { () -> Result<[String: String], Error>? in
                    if let pasted {
                        return .success(pasted)
                    }
                    if stopped || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    waiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<[String: String], Error>? in
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

extension PasteableLoopback {
    /// What Safari shows once the listener has the redirect.
    static let successPage = """
    <!doctype html>
    <html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>Signed In</title>
    <style>body{font:17px -apple-system,system-ui;padding:3em 1.5em;max-width:30em;margin:0 auto;color:#222}
    @media (prefers-color-scheme:dark){body{background:#000;color:#eee}}</style></head>
    <body><h1>Signed in</h1><p>Return to Apelin. It finishes signing in by itself.</p></body></html>
    """

    static let errorPage = """
    <!doctype html>
    <html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>Sign-In Failed</title>
    <style>body{font:17px -apple-system,system-ui;padding:3em 1.5em;max-width:30em;margin:0 auto;color:#222}
    @media (prefers-color-scheme:dark){body{background:#000;color:#eee}}</style></head>
    <body><h1>Unable to Sign In</h1><p>Return to Apelin and try again.</p></body></html>
    """
}
