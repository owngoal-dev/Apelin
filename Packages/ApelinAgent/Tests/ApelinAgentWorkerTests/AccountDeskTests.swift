import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

/// What a sign-in told the host, in order.
final class SignInRecorder: @unchecked Sendable {
    struct Event: Equatable {
        var kind: String
        var payload: ApelinCore.JSONValue?
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var ended: (TaskState, String?)?

    var reporter: SignInReporter {
        SignInReporter(
            emit: { [self] _, kind, payload in lock.withLock { recorded.append(Event(kind: kind, payload: payload)) } },
            finish: { [self] _, state, message in lock.withLock { ended = (state, message) } },
        )
    }

    var events: [Event] {
        lock.withLock { recorded }
    }

    var state: TaskState? {
        lock.withLock { ended?.0 }
    }

    var message: String? {
        lock.withLock { ended?.1 }
    }

    /// Everything the host was told, as one string, for "no secret in it".
    var transcript: String {
        lock.withLock {
            let lines = recorded.map { event -> String in
                let payload = event.payload.flatMap { try? JSONCoding.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                return "\(event.kind) \(payload ?? "")"
            }
            return (lines + [ended?.1 ?? ""]).joined(separator: "\n")
        }
    }

    func waitFor(_ condition: @escaping (SignInRecorder) -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition(self) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting; events \(events.map(\.kind)), state \(String(describing: state))")
    }
}

/// A loopback that never hears from a browser: the paste is the only way in.
/// Its wait ends when its task is cancelled, as kwwk's listener's does,
/// even when the cancel came first: a wait that starts after the sign-in
/// was cancelled or the paste won must not keep the sign-in alive.
final class SilentListener: OAuthLoopbackListener, @unchecked Sendable {
    let redirectURI: String
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private(set) var stopped = false

    init(host: String, port: UInt16, path: String) {
        redirectURI = "http://\(host):\(port)\(path)"
    }

    func listen() async throws {}

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Decided under the lock the cancel handler takes: a cancel
                // that ran before this found no waiter to resume.
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled {
                        return true
                    }
                    waiter = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
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

    func stop() {
        lock.withLock { stopped = true }
    }
}

@Suite("Sign-in: kwwk's flows in apelin-agent, nothing secret on the wire", .timeLimit(.minutes(1)))
struct AccountDeskTests {
    static let silent: OAuthLoopbackFactory = { SilentListener(host: $0, port: $1, path: $2) }

    /// What a provider hands back: the strings no event may carry.
    static let issued = OAuthCredentials(access: "tok-access-SECRET", refresh: "tok-refresh-SECRET", expires: 4_102_444_800_000)

    /// GitHub's device flow as kwwk runs it, against nobody: the code, then
    /// the page, then the poll that answers once `approve` is called.
    static func deviceFlow(_ approval: AsyncStream<Void>) -> SignInLogin {
        { provider, callbacks, _ in
            #expect(provider == .githubCopilot)
            let code = OAuthLogin.DeviceCode(
                code: "ABCD-1234",
                verificationURL: URL(string: "https://github.com/login/device")!,
                pageHoldsCode: false,
            )
            await callbacks.onDeviceCode?(code)
            return try await callbacks.browser!.run(code.verificationURL) {
                for await _ in approval {
                    return issued
                }
                throw CancellationError()
            }
        }
    }

    /// Anthropic's PKCE flow as kwwk runs it: a loopback on the registered
    /// port, the authorize page, the redirect's state checked.
    static let browserFlow: SignInLogin = { provider, callbacks, _ in
        #expect(provider == .anthropicOAuth)
        let listener = try callbacks.loopback("localhost", 53692, "/callback")
        try await listener.listen()
        defer { listener.stop() }
        let page = URL(string: "https://claude.ai/oauth/authorize?state=s1&redirect_uri=\(listener.redirectURI)")!
        let parameters = try await callbacks.browser!.run(page) { try await listener.waitForCallback() }
        guard parameters["state"] == "s1", parameters["code"] == "c1" else {
            throw OAuthError.invalidResponse("anthropic OAuth state mismatch")
        }
        return issued
    }

    static let neverCalled: SignInLogin = { _, _, _ in
        Issue.record("an API-key sign-in ran a kwwk flow")
        throw CancellationError()
    }

    @Test
    func `a device flow shows its code and page, stores what GitHub issued, and says nothing secret`() async throws {
        let (approval, approve) = AsyncStream<Void>.makeStream()
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.deviceFlow(approval), listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .githubCopilot), taskID: TaskID("t1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events == [SignInRecorder.Event(kind: "deviceCode", payload: .object([
            "code": .string("ABCD-1234"),
            "verificationURL": .string("https://github.com/login/device"),
            "pageHoldsCode": .bool(false),
        ]))])

        // A device flow takes nothing from the app.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t1"), fields: [.apiKey: "x"]))
        }

        approve.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "github-copilot") == Self.issued)
        #expect(!recorder.transcript.contains("SECRET"))

        let listed = await desk.list().accounts
        #expect(listed.map(\.provider) == AgentProvider.signInOrder)
        #expect(listed.first { $0.provider == .githubCopilot }?.signedIn == true)
        #expect(listed.first { $0.provider == .githubCopilot }?.models?.isEmpty == false)
        #expect(listed.filter(\.signedIn).map(\.provider) == [.githubCopilot])
    }

    @Test
    func `a browser flow names its page, and a pasted redirect finishes it when the loopback hears nothing`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.browserFlow, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t2"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.map(\.kind) == ["authorize"])
        #expect(recorder.events[0].payload?["acceptsCallbackURL"] == .bool(true))
        #expect(recorder.events[0].payload?["url"]?.stringValue?.hasPrefix("https://claude.ai/oauth/authorize") == true)

        // Not a redirect: refused, and the sign-in goes on waiting.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t2"), fields: [.callbackURL: "hello"]))
        }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t2"), fields: [.apiKey: "k"]))
        }
        #expect(recorder.state == nil)

        try await desk.respond(AgentSignInRespondRequest(
            taskID: TaskID("t2"),
            fields: [.callbackURL: "http://localhost:53692/callback?code=c1&state=s1"],
        ))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic") == Self.issued)
        #expect(!recorder.transcript.contains("SECRET"))
        #expect(!recorder.transcript.contains("c1&"))
    }

    @Test
    func `an API key is asked for by field, checked by name alone, and stored in kwwk's shape`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        let task = TaskID("t3")
        try await desk.start(AgentSignInRequest(provider: .openAICompatible), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.map(\.kind) == ["input"])
        let fields = recorder.events[0].payload?["fields"]
        #expect(fields == .array([
            .object(["key": .string("apiKey"), "required": .bool(true), "secure": .bool(true)]),
            .object(["key": .string("baseUrl"), "required": .bool(true), "secure": .bool(false), "placeholder": .string("https://…")]),
            .object(["key": .string("defaultModel"), "required": .bool(true), "secure": .bool(false)]),
        ]))

        // Each refusal names the field and never what was typed.
        let refusals: [[AgentSignInField: String]] = [
            [.apiKey: "sk-SECRET", .baseURL: "https://example.invalid"],
            [.apiKey: "sk-SECRET", .baseURL: "ftp://example.invalid", .defaultModel: "m"],
            [.apiKey: "sk-SECRET", .baseURL: "https://user:pw@example.invalid", .defaultModel: "m"],
            [.apiKey: "sk SECRET", .baseURL: "https://example.invalid", .defaultModel: "m"],
            [.apiKey: "sk-SECRET", .baseURL: "https://example.invalid", .defaultModel: "m", .callbackURL: "x"],
        ]
        for values in refusals {
            do {
                try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: values))
                Issue.record("accepted \(values.keys.map(\.rawValue))")
            } catch let error as ApelinError {
                #expect(error.code == .badRequest)
                #expect(!error.message.contains("SECRET"))
            }
        }
        #expect(recorder.state == nil)

        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: " sk-SECRET\n", .baseURL: "https://llm.example.invalid/v1", .defaultModel: "test-model",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let stored = try #require(try await store.credentials(for: "openai-compatible"))
        #expect(stored.access == "sk-SECRET")
        #expect(stored.refresh.isEmpty && stored.expires == .max)
        #expect(stored.extras["baseUrl"] == .string("https://llm.example.invalid/v1"))
        #expect(stored.extras["defaultModel"] == .string("test-model"))
        #expect(!recorder.transcript.contains("SECRET"))

        let account = await desk.list().accounts.first { $0.provider == .openAICompatible }
        #expect(account?.signedIn == true)
        #expect(account?.account == "llm.example.invalid")
        #expect(account?.models == ["test-model"])

        // A second answer to an ended sign-in finds nothing waiting.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "again"]))
        }

        try await desk.signOut(.openAICompatible)
        #expect(try await store.credentials(for: "openai-compatible") == nil)
        #expect(await desk.list().accounts.allSatisfy { !$0.signedIn })
        // Signing out of nothing is no error.
        try await desk.signOut(.openAICompatible)
    }

    @Test
    func `Anthropic's key needs no endpoint, and its default is the account label`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: TaskID("t4"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events[0].payload?["fields"] == .array([
            .object([
                "key": .string("apiKey"), "required": .bool(true), "secure": .bool(true),
                "placeholder": .string("sk-ant-api03-…"),
            ]),
            .object([
                "key": .string("baseUrl"), "required": .bool(false), "secure": .bool(false),
                "defaultValue": .string("https://api.anthropic.com"),
            ]),
        ]))
        try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t4"), fields: [.apiKey: "sk-ant-SECRET", .baseURL: ""]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.extras.isEmpty == true)
        let account = await desk.list().accounts.first { $0.provider == .anthropic }
        #expect(account?.account == "api.anthropic.com")
        #expect(account?.expiresAt == nil)
    }

    @Test
    func `a candidate key is saved only after its model answers`() async throws {
        let store = DeliveredCredentialSource()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (reply, answer) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { provider, credentials, _ in
            #expect(provider == .anthropic)
            #expect(credentials.access == "candidate")
            didStart.yield()
            for await _ in reply {
                return
            }
            throw CancellationError()
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-waits")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        let response = Task { try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"])) }
        for await _ in started {
            break
        }
        #expect(await store.providerIds().isEmpty)
        #expect(recorder.state == nil)
        answer.yield()
        try await response.value
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.access == "candidate")
        #expect(!recorder.transcript.contains("candidate"))
    }

    @Test
    func `failed verification preserves the saved key and the form accepts another answer`() async throws {
        let old = OAuthCredentials(access: "previous", refresh: "", expires: .max)
        let store = DeliveredCredentialSource(["anthropic-api-key": old])
        let desk = AccountDesk(store: store, verifyKey: { _, credentials, _ in
            if credentials.access == "rejected" {
                throw ApelinError(.unavailable, "Verification failed.")
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-retry")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "rejected"]))
        }
        #expect(recorder.state == nil)
        #expect(try await store.credentials(for: "anthropic-api-key") == old)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "accepted"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.access == "accepted")
    }

    @Test
    func `cancelling a verification never saves its late reply`() async throws {
        let store = DeliveredCredentialSource()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (reply, answer) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in
            didStart.yield()
            for await _ in reply {
                return
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-cancel")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        let response = Task { try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"])) }
        for await _ in started {
            break
        }
        #expect(await desk.cancel(task))
        answer.yield()
        await #expect(throws: CancellationError.self) { try await response.value }
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(await store.providerIds().isEmpty)
    }

    @Test
    func `a cancel ends the sign-in cancelled and stores nothing`() async throws {
        let (approval, _) = AsyncStream<Void>.makeStream()
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.deviceFlow(approval), listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .githubCopilot), taskID: TaskID("t5"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(await desk.cancel(TaskID("other")) == false)
        #expect(await desk.cancel(TaskID("t5")))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(await store.providerIds().isEmpty)
    }

    @Test
    func `the app configuration editor receives saved API fields without adding secrets to account listings`() async throws {
        let credentials = OAuthCredentials(access: "test-saved-key", refresh: "", expires: .max,
                                           extras: ["baseUrl": .string("https://custom.example/v1"), "defaultModel": .string("saved-model")])
        let store = DeliveredCredentialSource(["anthropic-api-key": credentials, "github-copilot": Self.issued])
        let desk = AccountDesk(store: store)
        let configuration = try await desk.apiConfiguration(for: .anthropic)
        #expect(configuration.values == ["apiKey": "test-saved-key", "baseUrl": "https://custom.example/v1"])
        let listing = try await JSONCoding.encode(desk.list())
        #expect(!String(decoding: listing, as: UTF8.self).contains("test-saved-key"))
        await #expect(throws: ApelinError.self) { try await desk.apiConfiguration(for: .githubCopilot) }
        await #expect(throws: ApelinError.self) { try await desk.apiConfiguration(for: .openAI) }
        let defaultDesk = AccountDesk(store: DeliveredCredentialSource([
            "anthropic-api-key": OAuthCredentials(access: "test-default-key", refresh: "", expires: .max),
        ]))
        let defaults = try await defaultDesk.apiConfiguration(for: .anthropic)
        #expect(defaults.values["baseUrl"] == "https://api.anthropic.com")
    }

    @Test
    func `model activation probes the selected custom IDs and reports a refusal without secrets`() async throws {
        let credentials = OAuthCredentials(access: "SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource(["anthropic-api-key": credentials])
        let desk = AccountDesk(store: store, verifyKey: { provider, value, model in
            #expect(provider == .anthropic)
            #expect(value.access == "SECRET")
            if model == "denied-model" {
                throw ApelinError(.unavailable, "SECRET response")
            }
            #expect(model == "custom-model")
        })
        let recorder = SignInRecorder()
        try await desk.activateModels(AgentModelActivateRequest(provider: .anthropic, models: ["custom-model", "denied-model"]), taskID: TaskID("selected-models"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .failed)
        #expect(recorder.events.map(\.kind) == ["modelVerified"])
        #expect(recorder.message?.contains("denied-model") == true)
        #expect(!recorder.transcript.contains("SECRET"))
        #expect(await store.credentials(for: "anthropic-api-key") == credentials)
    }

    @Test
    func `cancelling model activation stops before accepting a late model response`() async throws {
        let store = DeliveredCredentialSource(["anthropic-api-key": Self.issued])
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (replies, reply) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in
            signal.yield()
            for await _ in replies {
                return
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("cancel-models")
        try await desk.activateModels(AgentModelActivateRequest(provider: .anthropic, models: ["custom"]), taskID: task, reporter: recorder.reporter)
        for await _ in started {
            break
        }
        #expect(await desk.cancel(task))
        reply.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(recorder.events.isEmpty)
    }

    @Test
    func `API-key setup can defer probing until the selected models are saved`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in Issue.record("setup probed an unselected default model") })
        let recorder = SignInRecorder()
        let task = TaskID("deferred-probe")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"], verifyModel: false))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(await desk.list().accounts.first { $0.provider == .anthropic }?.isAPIKeyAccount == true)
    }

    @Test
    func `a new sign-in ends the one still waiting, which frees its loopback`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.browserFlow, listener: Self.silent, verifyKey: { _, _, _ in })
        let first = SignInRecorder()
        let second = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t6"), reporter: first.reporter)
        try await first.waitFor { !$0.events.isEmpty }
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t7"), reporter: second.reporter)
        #expect(first.state == .cancelled)
        try await second.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(
                taskID: TaskID("t6"),
                fields: [.callbackURL: "http://localhost:53692/callback?code=c1&state=s1"],
            ))
        }
        #expect(await desk.cancel(TaskID("t7")))
        try await second.waitFor { $0.state != nil }
        #expect(second.state == .cancelled)
    }

    @Test
    func `a sign-in left alone ends failed at its deadline`() async throws {
        let desk = AccountDesk(store: DeliveredCredentialSource(), login: Self.neverCalled, listener: Self.silent, timeoutSeconds: 0.2, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: TaskID("t8"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .failed)
        #expect(recorder.message?.contains("in time") == true)
    }

    @Test
    func `a sign-in only lapses when nothing renews it`() {
        #expect(AccountDesk.lapses(Self.issued) == nil)
        #expect(AccountDesk.lapses(OAuthCredentials(access: "k", refresh: "", expires: .max)) == nil)
        #expect(AccountDesk.lapses(OAuthCredentials(access: "k", refresh: "", expires: 1000)) == Date(timeIntervalSince1970: 1))
    }

    @Test
    func `every provider maps to the store id its session reads`() {
        #expect(Set(AgentProvider.allCases.map(\.storeID)) == CredentialInbox.knownProviders)
        #expect(Set(AgentProvider.allCases.map(\.storeID)).count == AgentProvider.allCases.count)
        #expect(Set(AgentProvider.signInOrder) == Set(AgentProvider.allCases))
        #expect(AgentProvider.signInOrder.count == AgentProvider.allCases.count)
    }

    // MARK: - Every login kwwk offers

    @Test
    func `DeepSeek signs in with a key alone and signs out independently`() async throws {
        let other = OAuthCredentials(access: "other-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: other])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { provider, key, _ in
            #expect(provider == .deepSeek)
            #expect(key.access == "deepseek-SECRET")
        })
        let recorder = SignInRecorder()
        let task = TaskID("deepseek-sign-in")
        try await desk.start(AgentSignInRequest(provider: .deepSeek), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(AgentProvider.deepSeek.keyFields.first { $0.field == .baseURL }?.defaultValue == DeepSeekProvider.baseURL)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "deepseek-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let account = try #require(await desk.list().accounts.first { $0.provider == .deepSeek })
        #expect(account.signedIn)
        #expect(account.account == "api.deepseek.com")
        #expect(account.models?.contains("deepseek-flash") == true)
        #expect(!recorder.transcript.contains("SECRET"))
        try await desk.signOut(.deepSeek)
        #expect(try await store.credentials(for: CredentialProviderID.deepSeek) == nil)
        #expect(try await store.credentials(for: CredentialProviderID.openAICompatible) == other)
    }

    @Test
    func `OpenCode Go signs in with a key alone and lists its catalog models`() async throws {
        let other = OAuthCredentials(access: "other-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: other])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { provider, key, _ in
            #expect(provider == .openCodeGo)
            #expect(key.access == "opencode-go-SECRET")
        })
        let recorder = SignInRecorder()
        let task = TaskID("opencode-go-sign-in")
        try await desk.start(AgentSignInRequest(provider: .openCodeGo), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.first?.kind == "input")
        #expect(AgentProvider.openCodeGo.keyFields.count == 1)
        #expect(AgentProvider.openCodeGo.keyFields.first?.field == .apiKey)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "opencode-go-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let account = try #require(await desk.list().accounts.first { $0.provider == .openCodeGo })
        #expect(account.signedIn)
        #expect(account.models?.contains("glm-5.2") == true)
        #expect(account.models?.contains("claude-haiku-5-5") == true)
        #expect(account.reasoningEfforts?["glm-5.2"]?.contains(.high) == true)
        #expect(!recorder.transcript.contains("SECRET"))
        try await desk.signOut(.openCodeGo)
        #expect(try await store.credentials(for: CredentialProviderID.openCodeGo) == nil)
        #expect(try await store.credentials(for: CredentialProviderID.openAICompatible) == other)
    }

    /// The test that fails when kwwk gains a login: every subscription
    /// `OAuthSubscriptions.login` runs has a provider here that signs in by
    /// a flow (not a typed key). Display order is Apelin's own.
    @Test
    func `every kwwk subscription has a provider`() {
        for subscription in OAuthSubscriptions.providers {
            let provider = AgentProvider.allCases.first { $0.storeID == subscription.id }
            #expect(provider != nil, "kwwk signs in to \(subscription.id), which AgentProvider lacks")
            #expect(provider.map { $0.signInMethod != .apiKey } == true, "\(subscription.id) is a kwwk flow, not a key")
        }
        #expect(Array(AgentProvider.signInOrder.prefix(4)) == [.openAICodex, .anthropicOAuth, .githubCopilot, .cursor])
        #expect(AgentProvider.signInOrder.filter { $0.signInMethod == .apiKey }
            == [.openAI, .deepSeek, .openCodeGo, .google, .anthropic, .openAICompatible])
    }

    /// Every login kwwk can store and register for a session
    /// (`providerDirectory`, the list `registerStored` serves) has a
    /// provider here; Apelin's own registration adds DeepSeek and OpenCode Go.
    @Test
    func `every stored provider is registered by kwwk or Apelin`() {
        let kwwk = Set(providerDirectory.map(\.storeId))
        let apelin = Set(AgentProvider.allCases.map(\.storeID))
        #expect(kwwk.subtracting(apelin).isEmpty, "kwwk stores \(kwwk.subtracting(apelin).sorted()) with no provider")
        #expect(apelin.subtracting(kwwk) == [CredentialProviderID.deepSeek, CredentialProviderID.openCodeGo])
        // A store id kwwk keeps as a typed key and does not sign in to is
        // a key form here.
        let subscriptions = Set(OAuthSubscriptions.providers.map(\.id))
        for descriptor in providerDirectory where descriptor.formTitle != nil && !subscriptions.contains(descriptor.storeId) {
            let provider = AgentProvider.allCases.first { $0.storeID == descriptor.storeId }
            #expect(provider?.signInMethods.contains(.apiKey) == true, "\(descriptor.storeId) has no key form")
        }
    }

    /// KWWKCli's API-key forms, as mirrored: the key first and secure, each
    /// form only the fields `agentSignInRespond` knows.
    @Test
    func `each key form asks for a key first, as KWWKCli's does`() {
        #expect(SignInKeyForms.all.map(\.provider) == [.anthropic, .openAI, .google, .deepSeek, .openCodeGo, .openRouter, .openAICompatible])
        for form in SignInKeyForms.all {
            #expect(form.fields.first == KeyField(field: .apiKey, required: true, placeholder: form.fields.first?.placeholder))
            #expect(form.fields.filter(\.secure).count == 1)
            #expect(!form.fields.contains { $0.field == .callbackURL })
        }
        for provider in AgentProvider.allCases where provider.signInMethods.contains(.apiKey) {
            #expect(!provider.keyFields.isEmpty, "\(provider) takes a key but has no form")
        }
    }

    /// A device flow whose page arrives with the code (Kimi, xAI): the code
    /// is shown to check, not to type; Kimi's login is handed the device id
    /// the last Kimi sign-in recorded, never kwwk's file.
    @Test
    func `Kimi's device flow keeps the device the stored sign-in recorded`() async throws {
        let seen = SignInRecorder()
        let login: SignInLogin = { provider, callbacks, options in
            #expect(provider == .kimiCoding)
            let identity = try #require(options.kimiIdentity)
            seen.reporter.emit(TaskID("seen"), identity.deviceId, nil)
            let code = OAuthLogin.DeviceCode(
                code: "KIMI-0001",
                verificationURL: URL(string: "https://www.kimi.com/code/authorize_device?user_code=KIMI-0001")!,
                pageHoldsCode: true,
            )
            await callbacks.onDeviceCode?(code)
            return try await callbacks.browser!.run(code.verificationURL) {
                var issued = Self.issued
                issued.extras[KimiIdentity.deviceIDExtra] = .string(identity.deviceId)
                return issued
            }
        }
        let previous = OAuthCredentials(access: "old-SECRET", refresh: "old-refresh-SECRET", expires: 1, extras: [
            KimiIdentity.deviceIDExtra: .string("0123456789abcdef0123456789abcdef"),
        ])
        let store = DeliveredCredentialSource(["kimi-coding": previous])
        let desk = AccountDesk(store: store, login: login, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .kimiCoding), taskID: TaskID("k1"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(recorder.events.map(\.kind) == ["deviceCode"])
        #expect(recorder.events[0].payload?["pageHoldsCode"] == .bool(true))
        #expect(seen.events.map(\.kind) == ["0123456789abcdef0123456789abcdef"])
        let stored = try #require(try await store.credentials(for: "kimi-coding"))
        #expect(stored.extras[KimiIdentity.deviceIDExtra] == .string("0123456789abcdef0123456789abcdef"))
        #expect(!recorder.transcript.contains("SECRET"))

        // With nothing stored, a new id in kwwk's format.
        let fresh = KimiIdentity.identity(recordedIn: nil).deviceId
        #expect(fresh.count == 32 && fresh.allSatisfy(\.isHexDigit) && fresh == fresh.lowercased())
    }

    /// A page the flow polls the provider for (Cursor, Qoder, WorkBuddy,
    /// Z.ai) or a listener kwwk binds itself (Kiro): the page is named with
    /// no paste offered, and a pasted address is refused.
    @Test
    func `a polled browser flow names its page and takes no pasted address`() async throws {
        let (approval, approve) = AsyncStream<Void>.makeStream()
        let login: SignInLogin = { provider, callbacks, options in
            #expect(provider == .cursor)
            #expect(options == SignInOptions())
            return try await callbacks.browser!.run(URL(string: "https://cursor.com/loginDeepControl?uuid=u")!) {
                for await _ in approval {
                    return Self.issued
                }
                throw CancellationError()
            }
        }
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: login, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .cursor), taskID: TaskID("c1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events == [SignInRecorder.Event(kind: "authorize", payload: .object([
            "url": .string("https://cursor.com/loginDeepControl?uuid=u"),
            "acceptsCallbackURL": .bool(false),
        ]))])
        do {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("c1"), fields: [.callbackURL: "http://localhost:1/x?code=c"]))
            Issue.record("a polled flow took a pasted address")
        } catch let error as ApelinError {
            #expect(error.code == .conflict)
        }
        approve.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "cursor") == Self.issued)
        let account = await desk.list().accounts.first { $0.provider == .cursor }
        #expect(account?.signedIn == true)
        #expect(account?.method == .browser)
    }

    /// OpenRouter both ways under one store id: its browser sign-in by
    /// default, its key form when asked for; any other method is refused
    /// before the task starts.
    @Test
    func `OpenRouter signs in by browser or by key, and nothing else`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let listed = await desk.list().accounts.first { $0.provider == .openRouter }
        #expect(listed?.method == .browser)
        #expect(listed?.alternativeMethods == [.apiKey])
        #expect(await desk.list().accounts.filter { $0.alternativeMethods != nil }.map(\.provider) == [.openRouter])

        let recorder = SignInRecorder()
        await #expect(throws: ApelinError.self) {
            try await desk.start(AgentSignInRequest(provider: .openRouter, method: .deviceCode), taskID: TaskID("o0"), reporter: recorder.reporter)
        }
        await #expect(throws: ApelinError.self) {
            try await desk.start(AgentSignInRequest(provider: .cursor, method: .apiKey), taskID: TaskID("o0"), reporter: recorder.reporter)
        }
        #expect(recorder.events.isEmpty && recorder.state == nil)

        try await desk.start(AgentSignInRequest(provider: .openRouter, method: .apiKey), taskID: TaskID("o1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events[0].payload?["fields"] == .array([
            .object([
                "key": .string("apiKey"), "required": .bool(true), "secure": .bool(true),
                "placeholder": .string("sk-or-v1-…"),
            ]),
            .object([
                "key": .string("defaultModel"), "required": .bool(false), "secure": .bool(false),
                "placeholder": .string("anthropic/claude-sonnet-5"),
            ]),
        ]))
        // OpenRouter's form has no endpoint to give.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("o1"), fields: [.apiKey: "sk-or-SECRET", .baseURL: "https://x.invalid"]))
        }
        try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("o1"), fields: [.apiKey: "sk-or-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "openrouter")?.access == "sk-or-SECRET")
        #expect(try await store.credentials(for: "openrouter")?.extras["apelinSignInMethod"] == .string("apiKey"))
        #expect(!recorder.transcript.contains("SECRET"))
    }

    /// The keys kwwk's CLI asks for beyond the first four: OpenAI's and
    /// Google's, each with its own default endpoint as the label.
    @Test
    func `OpenAI's and Google's keys are stored under kwwk's ids with their endpoints as labels`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        for (provider, id, host) in [
            (AgentProvider.openAI, "openai-api-key", "api.openai.com"),
            (.google, "google-api-key", "generativelanguage.googleapis.com"),
        ] {
            let recorder = SignInRecorder()
            try await desk.start(AgentSignInRequest(provider: provider), taskID: TaskID("k-\(id)"), reporter: recorder.reporter)
            try await recorder.waitFor { !$0.events.isEmpty }
            guard case let .array(fields)? = recorder.events.first?.payload?["fields"], fields.count == 2 else {
                Issue.record("\(provider) asked for \(String(describing: recorder.events.first?.payload))")
                continue
            }
            #expect(fields[1]["key"] == .string("baseUrl"))
            #expect(fields[1]["defaultValue"] == .string("https://\(host)"))
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("k-\(id)"), fields: [.apiKey: "key-SECRET"]))
            try await recorder.waitFor { $0.state != nil }
            #expect(recorder.state == .succeeded)
            #expect(try await store.credentials(for: id)?.access == "key-SECRET")
            #expect(await desk.list().accounts.first { $0.provider == provider }?.account == host)
            #expect(!recorder.transcript.contains("SECRET"))
        }
    }

    /// kwwk's refreshers for the sessions, with Kimi's given an identity:
    /// every login that renews itself, and Devin's.
    @Test
    func `sessions refresh every renewing login without kwwk's files`() {
        let ids = Set(KimiIdentity.refreshers().map(\.id))
        #expect(ids.isSuperset(of: OAuthSubscriptions.refreshedIds))
        #expect(ids.contains("devin"))
    }
}
