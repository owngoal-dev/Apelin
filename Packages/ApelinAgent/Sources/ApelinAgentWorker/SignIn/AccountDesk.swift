import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI

/// Where a sign-in's events go: the host's task, as `WorkerContext` sends
/// them. A test records them instead.
public struct SignInReporter: Sendable {
    public var emit: @Sendable (TaskID, String, ApelinCore.JSONValue?) -> Void
    public var finish: @Sendable (TaskID, TaskState, String?) -> Void

    public init(
        emit: @escaping @Sendable (TaskID, String, ApelinCore.JSONValue?) -> Void,
        finish: @escaping @Sendable (TaskID, TaskState, String?) -> Void,
    ) {
        self.emit = emit
        self.finish = finish
    }

    public init(context: WorkerContext) {
        self.init(
            emit: { context.emit($0, $1, $2) },
            finish: { context.finish($0, $1, message: $2) },
        )
    }
}

/// apelin-agent's accounts: the `credential-import` instance signs in,
/// lists and signs out here, against the keychain the sessions read.
///
/// A sign-in is kwwk's own flow (`SignInLogin`), run in this process with
/// callbacks that turn what the user must see into task events — a device
/// code, a page to open, the fields of a key — and nothing else. What comes
/// back from the provider, and what the user types, goes into the store and
/// is never emitted or logged. Only the app's explicit configuration editor
/// can read a saved API key back through `apiConfiguration`. One sign-in runs at a time: a new
/// one ends the old one `cancelled` first, so a loopback port is free again.
public actor AccountDesk {
    private let store: any CredentialSource
    private let login: SignInLogin
    private let listener: OAuthLoopbackFactory
    private let timeoutSeconds: Double
    private let verifyKey: @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void
    private var keyVerification: (run: SignInRun, task: Task<Void, Error>)?
    private var running: SignInRun?

    public init(
        store: any CredentialSource,
        login: @escaping SignInLogin = KWWKSignIn.login,
        listener: @escaping OAuthLoopbackFactory = AccountDesk.nioListener,
        timeoutSeconds: Double = Double(AgentSignInRequest.timeoutSeconds),
        verifyKey: @escaping @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void = ProviderKeyVerification.verify,
    ) {
        self.store = store
        self.login = login
        self.listener = listener
        self.timeoutSeconds = timeoutSeconds
        self.verifyKey = verifyKey
    }

    /// kwwk's NIO listener with Apelin's own pages.
    public static let nioListener: OAuthLoopbackFactory = { host, port, path in
        try OAuthCallbackServer(
            port: port,
            path: path,
            successHTML: PasteableLoopback.successPage,
            errorHTML: PasteableLoopback.errorPage,
            redirectHost: host,
            surfacesProviderErrors: true,
        )
    }

    // MARK: - Accounts

    public func list() async -> AgentAccountListResponse {
        let stored = await Set(store.providerIds())
        var accounts: [AgentAccount] = []
        for provider in AgentProvider.signInOrder {
            let others = Array(provider.signInMethods.dropFirst())
            var account = AgentAccount(
                provider: provider,
                method: provider.signInMethod,
                alternativeMethods: others.isEmpty ? nil : others,
                signedIn: stored.contains(provider.storeID),
            )
            // An item that does not decode is still signed in: Sign Out is
            // how it goes away.
            if account.signedIn, let credentials = try? await store.credentials(for: provider.storeID) {
                account.account = Self.accountLabel(provider, credentials)
                account.expiresAt = Self.lapses(credentials)
                account.models = ProviderModels.list(provider, credentials: credentials)
                account.reasoningEfforts = ProviderModels.reasoningEfforts(provider, credentials: credentials)
                account.serviceTiers = ProviderModels.serviceTiers(provider, credentials: credentials)
                account.usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: credentials) ? true : nil
            }
            accounts.append(account)
        }
        return AgentAccountListResponse(accounts: accounts)
    }

    /// The explicit app-only editor reads the saved key directly; no task is
    /// created and neither account listings nor sign-in events expose it.
    public func apiConfiguration(for provider: AgentProvider) async throws -> AgentAPIConfigurationResponse {
        guard let credentials = try await store.credentials(for: provider.storeID) else {
            throw ApelinError(.notFound, "No saved API configuration was found. Sign in to the provider first.")
        }
        guard ProviderModels.usesAPIKey(provider, credentials: credentials) else {
            throw ApelinError(.denied, "This account does not use an editable API key.")
        }
        var values: [String: String] = [:]
        for field in provider.keyFields {
            if field.field == .apiKey {
                values[field.field.rawValue] = credentials.access
            } else if case let .string(value)? = credentials.extras[field.field.rawValue] {
                values[field.field.rawValue] = value
            } else if let value = field.defaultValue {
                values[field.field.rawValue] = value
            }
        }
        return AgentAPIConfigurationResponse(values: values)
    }

    public func signOut(_ provider: AgentProvider) async throws {
        do {
            try await store.remove(provider.storeID)
        } catch {
            throw ApelinError(
                .internal,
                "Unable to remove the saved sign-in: \(error.localizedDescription). Try again.",
            )
        }
    }

    /// A typed key's endpoint host — the one it was given, else its form's
    /// default — which tells two keys apart and is no secret. A
    /// subscription carries no account name kwwk keeps, and a key a browser
    /// sign-in minted (OpenRouter's, Z.ai's) names no endpoint.
    static func accountLabel(_ provider: AgentProvider, _ credentials: OAuthCredentials) -> String? {
        if case let .string(base)? = credentials.extras[AgentSignInField.baseURL.rawValue] {
            return URLComponents(string: base)?.host
        }
        guard provider.signInMethod == .apiKey,
              let base = provider.keyFields.first(where: { $0.field == .baseURL })?.defaultValue
        else { return nil }
        return URLComponents(string: base)?.host
    }

    /// Only a sign-in that cannot renew itself lapses for the user: a
    /// refresh token renews it, and an API key is stored as never expiring.
    static func lapses(_ credentials: OAuthCredentials) -> Date? {
        guard credentials.refresh.isEmpty, credentials.expires != .max else { return nil }
        return Date(timeIntervalSince1970: Double(credentials.expires) / 1000)
    }

    // MARK: - Signing in

    /// Accepts the task and starts the flow; its events and final `state`
    /// follow the reply. A method the provider does not offer is refused
    /// before anything starts, and the sign-in still running goes on.
    public func start(_ request: AgentSignInRequest, taskID: TaskID, reporter: SignInReporter) async throws {
        let method = request.method ?? request.provider.signInMethod
        guard request.provider.signInMethods.contains(method) else {
            throw ApelinError(
                .badRequest,
                "\(request.provider.rawValue) does not support \(method.rawValue) sign-in. Choose another method.",
            )
        }
        await stopRunning()
        let run = SignInRun(taskID: taskID, provider: request.provider, method: method)
        running = run
        run.work = Task { [weak self] in
            await self?.perform(run, reporter: reporter)
        }
    }

    public func cancel(_ taskID: TaskID) -> Bool {
        guard let running, running.taskID == taskID else { return false }
        keyVerification?.task.cancel()
        running.cancel()
        return true
    }

    /// What the user supplied, for the sign-in that asked for it. A value
    /// that will not do is refused naming the field; the flow goes on
    /// waiting for a better one.
    public func respond(_ request: AgentSignInRespondRequest) async throws {
        guard let run = running, run.taskID == request.taskID else {
            throw ApelinError(
                .notFound,
                "Sign-in \(request.taskID) is no longer waiting for a response. Start signing in again.",
            )
        }
        var values: [AgentSignInField: String] = [:]
        for (key, value) in request.values {
            guard let field = AgentSignInField(rawValue: key) else {
                throw ApelinError(.badRequest, "\(key) is not a sign-in field")
            }
            values[field] = value
        }
        switch run.method {
        case .deviceCode:
            throw ApelinError(
                .badRequest,
                "Complete sign-in on the provider’s website. No response is needed in Apelin.",
            )
        case .browser:
            guard values.count == 1, let text = values[.callbackURL] else {
                throw ApelinError(.badRequest, "a browser sign-in takes only \(AgentSignInField.callbackURL.rawValue)")
            }
            guard let loopback = run.loopback else {
                throw ApelinError(.conflict, "\(run.provider.rawValue) is not waiting for a pasted address")
            }
            try loopback.paste(text)
        case .apiKey:
            guard keyVerification == nil else {
                throw ApelinError(.conflict, "Provider verification is already running.")
            }
            let accepted = try Self.validated(
                values,
                for: run.provider,
                requiresDefaultModel: request.verifyModel != false,
            )
            guard request.verifyModel != false else {
                try run.deliver(accepted)
                return
            }
            let credentials = Self.apiKeyCredentials(accepted)
            let work = Task { try await verifyKey(run.provider, credentials, nil) }
            keyVerification = (run, work)
            defer {
                if keyVerification?.run === run {
                    keyVerification = nil
                }
            }
            try await work.value
            guard running === run, !run.isCancelled else { throw CancellationError() }
            try run.deliver(accepted)
        }
    }

    public func models(for provider: AgentProvider) async throws -> AgentModelListResponse {
        guard let credentials = try await store.credentials(for: provider.storeID) else {
            throw ApelinError(.notFound, "Sign in to the provider first.")
        }
        return try await AgentModelListResponse(models: ProviderModels.fetch(provider, credentials: credentials))
    }

    public func activateModels(
        _ request: AgentModelActivateRequest,
        taskID: TaskID,
        reporter: SignInReporter,
    ) async throws {
        guard !request.models.isEmpty, request.models.count <= 64,
              request.models.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(where: \.isNewline) })
        else { throw ApelinError(.badRequest, "Select between 1 and 64 valid model IDs.") }
        guard let credentials = try await store.credentials(for: request.provider.storeID) else {
            throw ApelinError(.notFound, "Sign in to the provider first.")
        }
        let usesAPIKey = ProviderModels.usesAPIKey(request.provider, credentials: credentials)
        guard usesAPIKey || request.provider == .githubCopilot else {
            throw ApelinError(.badRequest, "This OAuth provider does not require model verification.")
        }
        await stopRunning()
        let run = SignInRun(taskID: taskID, provider: request.provider, method: .apiKey)
        running = run
        run.work = Task { [weak self, verifyKey] in
            var currentModel = ""
            do {
                for model in request.models {
                    currentModel = model
                    try Task.checkCancellation()
                    if usesAPIKey {
                        try await verifyKey(request.provider, credentials, model)
                    } else {
                        try await KWWKSignIn.enableCopilotModels(credentials, models: [model])
                    }
                    try Task.checkCancellation()
                    reporter.emit(taskID, "modelVerified", .object(["model": .string(model)]))
                }
                reporter.finish(taskID, .succeeded, nil)
            } catch {
                reporter.finish(
                    taskID,
                    run.isCancelled ? .cancelled : .failed,
                    run.isCancelled ? nil : "Unable to verify model \(currentModel). Check the model ID and provider access, then try again.",
                )
            }
            await self?.clear(run)
        }
    }

    private func clear(_ run: SignInRun) {
        if running === run {
            running = nil
        }
    }

    private func stopRunning() async {
        guard let previous = running else { return }
        previous.cancel()
        if let verification = keyVerification {
            verification.task.cancel()
            _ = await verification.task.result
        }
        await previous.work?.value
    }

    /// The key and its extras, each checked on its own and refused by name
    /// alone: an error never quotes what was typed.
    static func validated(
        _ values: [AgentSignInField: String],
        for provider: AgentProvider,
        requiresDefaultModel: Bool = true,
    ) throws -> [AgentSignInField: String] {
        let fields = provider.keyFields
        for field in values.keys where !fields.contains(where: { $0.field == field }) {
            throw ApelinError(.badRequest, "\(provider.rawValue) does not ask for \(field.rawValue)")
        }
        var accepted: [AgentSignInField: String] = [:]
        for field in fields {
            let value = (values[field.field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                if field.required, field.field != .defaultModel || requiresDefaultModel {
                    throw ApelinError(.badRequest, Self.missing(field.field))
                }
                continue
            }
            switch field.field {
            case .apiKey:
                guard value.count <= 4096, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw ApelinError(.badRequest, "Enter a valid API key without spaces or line breaks.")
                }
            case .baseURL:
                guard value.count <= 2048, let url = URLComponents(string: value),
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      url.host?.isEmpty == false, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil
                else {
                    throw ApelinError(.badRequest, "Enter a valid HTTP or HTTPS address.")
                }
            case .defaultModel:
                guard value.count <= 256, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw ApelinError(.badRequest, "Enter a valid model ID without spaces or line breaks.")
                }
            case .callbackURL:
                throw ApelinError(.badRequest, "\(provider.rawValue) does not ask for \(field.field.rawValue)")
            }
            accepted[field.field] = value
        }
        return accepted
    }

    /// The refusal for an empty required field, which names it.
    private static func missing(_ field: AgentSignInField) -> String {
        switch field {
        case .apiKey: "Enter an API key."
        case .baseURL: "Enter the endpoint address."
        case .defaultModel: "Enter a model ID."
        case .callbackURL: "Paste the address the browser opened."
        }
    }

    private static func isSpaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }

    /// kwwk's API-key shape (KWWKCli's `apiKeyCredentials`): the key as
    /// `access`, no refresh token, never expiring, the rest as extras.
    static func apiKeyCredentials(_ values: [AgentSignInField: String]) -> OAuthCredentials {
        var credentials = OAuthCredentials(access: values[.apiKey] ?? "", refresh: "", expires: .max)
        for field in [AgentSignInField.baseURL, .defaultModel] {
            if let value = values[field] {
                credentials.extras[field.rawValue] = .string(value)
            }
        }
        return credentials
    }

    /// What kwwk's login gets beside its callbacks: for Kimi, either site,
    /// the device id that site's stored sign-in recorded, so signing in
    /// again keeps the device Kimi knows (`KimiIdentity`).
    private func options(for provider: AgentProvider) async -> SignInOptions {
        guard provider == .kimiCoding || provider == .kimiCodingGlobal else { return SignInOptions() }
        let previous = try? await store.credentials(for: provider.storeID)
        return SignInOptions(kimiIdentity: KimiIdentity.identity(recordedIn: previous))
    }

    private func perform(_ run: SignInRun, reporter: SignInReporter) async {
        let taskID = run.taskID
        do {
            let options = await options(for: run.provider)
            // Not named `credentials`: Swift 6.2 reads the call in the closure
            // as the variable it initialises.
            var signedIn = try await Self.withDeadline(timeoutSeconds) { [self] in
                try await credentials(for: run, options: options, reporter: reporter)
            }
            if run.provider == .openRouter, run.method == .apiKey {
                signedIn.extras[ProviderModels.signInMethodExtra] = .string(run.method.rawValue)
            }
            try Task.checkCancellation()
            do {
                try await store.store(signedIn, for: run.provider.storeID)
            } catch {
                // A store error names a status, never the secret.
                throw ApelinError(.internal, "Unable to save your sign-in: \(error.localizedDescription). Try again.")
            }
            reporter.finish(taskID, .succeeded, "You are signed in.")
        } catch {
            reporter.finish(taskID, run.isCancelled ? .cancelled : Self.state(of: error), Self.message(error))
        }
        clear(run)
    }

    /// A cancel — the app's, a newer sign-in's, the user's "deny" on the
    /// provider's page — ends `cancelled`; everything else `failed`.
    static func state(of error: Error) -> TaskState {
        switch error {
        case is CancellationError: .cancelled
        case let error as OAuthLoginError where error == .cancelled: .cancelled
        default: .failed
        }
    }

    /// What the user reads: kwwk's own words for what went wrong, cut short
    /// — a provider's error body names the failure, and a failed exchange
    /// has no token to show.
    static func message(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "Sign-in was cancelled."
        case let error as OAuthLoginError where error == .cancelled: return "Sign-in was declined or cancelled."
        case OAuthLoginError.timedOut, SignInDeadline.passed:
            return "Sign-in timed out. Try again."
        case let error as ApelinError: return error.message
        default: break
        }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    private nonisolated func credentials(
        for run: SignInRun,
        options: SignInOptions,
        reporter: SignInReporter,
    ) async throws -> OAuthCredentials {
        let taskID = run.taskID
        switch run.method {
        case .apiKey:
            reporter.emit(taskID, "input", .object(["fields": .array(run.provider.keyFields.map { field in
                var entry: [String: ApelinCore.JSONValue] = [
                    "key": .string(field.field.rawValue),
                    "required": .bool(field.required),
                    "secure": .bool(field.secure),
                ]
                if let value = field.defaultValue {
                    entry["defaultValue"] = .string(value)
                }
                if let value = field.placeholder {
                    entry["placeholder"] = .string(value)
                }
                return .object(entry)
            })]))
            return try await Self.apiKeyCredentials(run.waitForKeys())
        case .deviceCode, .browser:
            let listener = listener
            let callbacks = OAuthLogin.Callbacks(
                onDeviceCode: { code in
                    run.announcedDeviceCode()
                    reporter.emit(taskID, "deviceCode", .object([
                        "code": .string(code.code),
                        "verificationURL": .string(code.verificationURL.absoluteString),
                        "pageHoldsCode": .bool(code.pageHoldsCode),
                    ]))
                },
                browser: SignInPresenter(signIn: run, reporter: reporter),
                loopback: { host, port, path in
                    let loopback = try PasteableLoopback(inner: listener(host, port, path))
                    run.loopback = loopback
                    return loopback
                },
            )
            return try await login(run.provider, callbacks, options)
        }
    }

    /// Runs `body` for at most `seconds`; past that it throws
    /// `SignInDeadline.passed`. The clock's child answers whether it fired
    /// (nil), so a clock cancelled because the work ended is never read as
    /// the deadline.
    static func withDeadline<T: Sendable>(
        _ seconds: Double,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let value = first else { throw SignInDeadline.passed }
            return value
        }
    }
}

enum SignInDeadline: Error {
    case passed
}

/// kwwk's page presenter: says what to open, once, and lets the flow's own
/// waiting run. A device flow has said it already, code and page together.
/// A flow that polls the provider (Cursor, Qoder, WorkBuddy, Z.ai) or binds
/// its own listener (Kiro) has no loopback of Apelin's, so nothing pasted
/// can stand in for its redirect.
private struct SignInPresenter: OAuthBrowserPresenter {
    let signIn: SignInRun
    let reporter: SignInReporter

    func run<Outcome: Sendable>(
        _ url: URL,
        while work: @escaping @Sendable () async throws -> Outcome,
    ) async throws -> Outcome {
        if !signIn.hasAnnouncedDeviceCode {
            reporter.emit(signIn.taskID, "authorize", .object([
                "url": .string(url.absoluteString),
                "acceptsCallbackURL": .bool(signIn.loopback != nil),
            ]))
        }
        return try await work()
    }
}

/// One sign-in in flight: its flow, the loopback it opened and, for a key,
/// what the user typed once it has been accepted.
final class SignInRun: @unchecked Sendable {
    let taskID: TaskID
    let provider: AgentProvider
    let method: AgentSignInMethod
    var work: Task<Void, Never>?

    private let lock = NSLock()
    private var keyWaiter: CheckedContinuation<[AgentSignInField: String], Error>?
    private var keys: [AgentSignInField: String]?
    private var cancelled = false
    private var deviceCode = false
    private var listener: PasteableLoopback?

    init(taskID: TaskID, provider: AgentProvider, method: AgentSignInMethod) {
        self.taskID = taskID
        self.provider = provider
        self.method = method
    }

    var loopback: PasteableLoopback? {
        get { lock.withLock { listener } }
        set { lock.withLock { listener = newValue } }
    }

    var hasAnnouncedDeviceCode: Bool {
        lock.withLock { deviceCode }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func announcedDeviceCode() {
        lock.withLock { deviceCode = true }
    }

    func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
            cancelled = true
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(throwing: CancellationError())
        loopback?.stop()
        work?.cancel()
    }

    /// Hands the accepted key to the flow, once.
    func deliver(_ values: [AgentSignInField: String]) throws {
        let waiter = try lock.withLock { () throws -> CheckedContinuation<[AgentSignInField: String], Error>? in
            guard keys == nil, !cancelled else { throw ApelinError(.conflict, "the sign-in has its key already") }
            keys = values
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(returning: values)
    }

    func waitForKeys() async throws -> [AgentSignInField: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentSignInField: String], Error>) in
                let early = lock.withLock { () -> Result<[AgentSignInField: String], Error>? in
                    if let keys {
                        return .success(keys)
                    }
                    if cancelled || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    keyWaiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
                defer { keyWaiter = nil }
                return keyWaiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
