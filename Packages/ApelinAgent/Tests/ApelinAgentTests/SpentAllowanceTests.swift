@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// #67: a chat froze the moment the account's quota ran out. Every reply
/// here is the shape a provider sends, served by a provider on this Mac and
/// read by kwwk's own provider for that wire.
@Suite("A spent allowance ends the turn at once", .serialized)
struct SpentAllowanceTests {
    struct Shape: Sendable, CustomTestStringConvertible {
        var name: String
        var api = "openai-completions"
        var reply: StandInProvider.Reply

        var testDescription: String {
            name
        }
    }

    static let copilotAllowance = StandInProvider.Reply.error(
        429,
        #"{"error":{"message":"You have exceeded your premium request allowance. We have automatically switched you to GPT-4.1 which is included with your plan.","code":"quota_exceeded"}}"#,
    )

    /// What kwwk 0.1.126 reads as a rate limit and asks again eight times
    /// over a minute and a half.
    static let waitedOut: [Shape] = [
        Shape(name: "GitHub Copilot 429 quota_exceeded", reply: copilotAllowance),
        Shape(name: "GitHub Copilot 429 monthly limit", api: "anthropic-messages", reply: .error(
            429,
            #"{"error":{"message":"You've reached your monthly chat messages limit. Upgrade to Copilot Pro (30-day free trial) or wait for your limit to reset.","code":"quota_exceeded"}}"#,
        )),
        Shape(name: "BigModel 429 1308", reply: .error(429, #"{"error":{"code":"1308","message":"已达到 5 小时的使用上限。您的限额将在 2026-11-21 18:21:32 重置。"}}"#)),
        Shape(name: "Z.ai 429 1310", reply: .error(429, #"{"error":{"code":"1310","message":"Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-11-28 18:21:32"}}"#)),
        Shape(name: "Z.ai 429 1309", reply: .error(429, #"{"error":{"code":"1309","message":"Your GLM Coding Plan package has expired and is temporarily unavailable."}}"#)),
        Shape(name: "OpenRouter 429 free models per day", reply: .error(
            429,
            #"{"error":{"message":"Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day","code":429}}"#,
        )),
    ]

    /// What kwwk reads as spent already.
    static let spent: [Shape] = [
        Shape(name: "OpenAI 429 insufficient_quota", reply: .error(
            429,
            #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#,
        )),
        Shape(name: "OpenAI Responses 429 insufficient_quota", api: "openai-responses", reply: .error(
            429,
            #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#,
        )),
        Shape(name: "DeepSeek 402", reply: .error(402, #"{"error":{"message":"Insufficient Balance","type":"unknown_error","param":null,"code":"invalid_request_error"}}"#)),
        Shape(name: "Anthropic 400 credit", api: "anthropic-messages", reply: .error(
            400,
            #"{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#,
        )),
        Shape(name: "Anthropic 429 credit", api: "anthropic-messages", reply: .error(
            429,
            #"{"type":"error","error":{"type":"rate_limit_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}"#,
        )),
        Shape(name: "Claude subscription window", api: "anthropic-messages", reply: .error(
            429,
            #"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed your account's rate limit. Please try again later."}}"#,
            headers: ["anthropic-ratelimit-unified-status": "rejected", "anthropic-ratelimit-unified-reset": "1900000000"],
        )),
        Shape(name: "GitHub Copilot 402", reply: .error(402, #"{"error":{"message":"You have no quota left.","code":"quota_exceeded"}}"#)),
        Shape(name: "Gemini 429 RESOURCE_EXHAUSTED, billing", api: "google-generative-ai", reply: .error(
            429,
            #"{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED"}}"#,
        )),
        Shape(name: "OpenRouter 402", reply: .error(402, #"{"error":{"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits","code":402}}"#)),
        Shape(name: "Moonshot 429 exceeded_current_quota_error", reply: .error(
            429,
            #"{"error":{"message":"Your account is suspended due to insufficient balance, please recharge your account","type":"exceeded_current_quota_error"}}"#,
        )),
        Shape(name: "Kimi For Coding 403", api: "anthropic-messages", reply: .error(
            403,
            #"{"error":{"type":"permission_error","message":"You've reached your 5-hour usage limit. Quota will reset at 2026-11-21 20:00."}}"#,
        )),
        Shape(name: "BigModel 429 1113", reply: .error(429, #"{"error":{"code":"1113","message":"余额不足或无可用资源包,请充值。"}}"#)),
        Shape(name: "Codex 429 usage_limit_reached", api: "openai-responses", reply: .error(
            429,
            #"{"error":{"type":"usage_limit_reached","message":"The usage limit has been reached","resets_in_seconds":7200}}"#,
        )),
        Shape(name: "OpenRouter 402 in the stream", reply: .stream([
            #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Hello "}}]}"# + "\n\n",
            #"data: {"error":{"code":402,"message":"Insufficient credits. Add more using https://openrouter.ai/settings/credits"}}"# + "\n\n",
        ])),
    ]

    /// Limits that open again within the turn: kwwk's to wait out.
    static let bursts: [Shape] = [
        Shape(name: "Anthropic tokens per minute", api: "anthropic-messages", reply: .error(
            429,
            #"{"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization of 50,000 input tokens per minute."}}"#,
            headers: ["retry-after": "20"],
        )),
        Shape(name: "GitHub Copilot rate_limited", reply: .error(
            429,
            #"{"error":{"message":"Sorry, you have been rate-limited. Please wait a moment before trying again.","code":"rate_limited"}}"#,
        )),
        Shape(name: "Gemini resource exhausted", api: "google-generative-ai", reply: .error(
            429,
            #"{"error":{"code":429,"message":"Resource has been exhausted (e.g. check quota).","status":"RESOURCE_EXHAUSTED"}}"#,
        )),
        Shape(name: "OpenRouter free models per minute", reply: .error(
            429,
            #"{"error":{"message":"Rate limit exceeded: free-models-per-min.","code":429}}"#,
        )),
        Shape(name: "A Chinese per-minute cap", reply: .error(429, #"{"error":{"code":"1302","message":"已达到每分钟使用上限，请稍后再试。"}}"#)),
        Shape(name: "OpenAI requests per minute", reply: .error(
            429,
            #"{"error":{"message":"Rate limit reached for gpt-5 in organization org-x on requests per min (RPM): Limit 500, Used 500. Please try again in 120ms.","type":"requests","code":"rate_limit_exceeded"}}"#,
        )),
    ]

    /// One request's end as kwwk's provider reads `shape`, after the
    /// session's own judgement of it (`SpentAllowance.stream`).
    private static func attempt(_ shape: Shape) async throws -> AssistantMessage {
        let server = try #require(await StandInProvider([shape.reply]))
        defer { server.stop() }
        let model = await server.model(api: shape.api)
        let stream = SpentAllowance.stream { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        }
        let response = try await stream(model, Context(messages: [.user(UserMessage(text: "Hi"))]), nil)
        for await _ in response {}
        #expect(server.requests == 1)
        return await response.result()
    }

    @Test(arguments: waitedOut + spent)
    func `a spent allowance is the quota, and kwwk does not ask again`(shape: Shape) async throws {
        let final = try await Self.attempt(shape)
        let failure = try #require(final.providerFailure)
        #expect(final.stopReason == .error)
        #expect(!failure.isRetryable, "kwwk would wait \(ProviderRetryPolicy().delay(for: failure, attempt: 0) ?? 0) ms")
        #expect(FailureReason.of(failure, hasRoute: true) == .quota)
    }

    @Test(arguments: bursts)
    func `a limit that opens again soon stays kwwk's to wait out`(shape: Shape) async throws {
        let final = try await Self.attempt(shape)
        let failure = try #require(final.providerFailure)
        #expect(failure.isRetryable)
        #expect(FailureReason.of(failure, hasRoute: true) == .rateLimit)
    }

    @Test
    func `a failure that is not a request's says nothing of the quota`() {
        #expect(!SpentAllowance.isSpent(ProviderFailure(message: "Daily limit", httpStatus: 401)), "a refused sign-in stays one")
        #expect(!SpentAllowance.isSpent(ProviderFailure(message: "connection lost", transportDomain: NSURLErrorDomain, transportCode: -1005)))
        #expect(SpentAllowance.isSpent(ProviderFailure(message: "quota_exceeded")), "named in a stream's error")
    }

    @Test
    func `a native compaction refused for a spent allowance is not asked again`() async throws {
        let refused = ProviderFailure(message: "You have exceeded your premium request allowance.", httpStatus: 429, providerCode: "quota_exceeded")
        #expect(refused.isRetryable, "as kwwk reads it")
        let compact = NativeCompactionFallback.compact { _, _, _, _ in throw refused }
        do {
            _ = try await compact(Model(id: "m", api: "test", provider: "test"), Context(), "", nil)
            Issue.record("the compaction answered")
        } catch {
            let failure = ProviderFailure.capture(error)
            #expect(!failure.isRetryable && failure.httpStatus == 429 && failure.providerCode == "quota_exceeded")
        }
        let busy = ProviderFailure(message: "Too many requests per minute", httpStatus: 429)
        let passing = NativeCompactionFallback.compact { _, _, _, _ in throw busy }
        await #expect(throws: busy) {
            _ = try await passing(Model(id: "m", api: "test", provider: "test"), Context(), "", nil)
        }
    }

    // MARK: - In a session

    static func session(_ home: TemporaryHome, _ server: StandInProvider) async throws -> AgentSession {
        try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(server.model()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                network: NetworkPath { true },
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
    }

    /// The session's events from its start to the end of its next run.
    static func run(_ session: AgentSession, sending: () async throws -> Void) async throws -> [AgentSessionEvent] {
        let stream = try await session.events(afterSeq: 0)
        try await sending()
        var events: [AgentSessionEvent] = []
        for await record in stream {
            events.append(record.event)
            if case .finished = record.event {
                break
            }
        }
        await session.waitForIdle()
        return events
    }

    /// GitHub Copilot, the default provider: a spent premium request
    /// allowance read "Reconnecting…" for 78 to 86 s over eight requests
    /// on this Mac with 0.4.7, then "Too Many Requests".
    @Test(.timeLimit(.minutes(1)))
    func `a spent allowance ends the turn on its first answer, as the quota`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let server = try #require(await StandInProvider([Self.copilotAllowance]))
        defer { server.stop() }
        let session = try await Self.session(home, server)
        let started = Date()
        let events = try await Self.run(session) { try await session.prompt("Hi") }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(server.requests == 1)
        #expect(!events.contains(.reconnecting))
        #expect(events.contains(.error(
            message: "You have exceeded your premium request allowance. We have automatically switched you to GPT-4.1 which is included with your plan.",
            reason: .quota,
        )))
        #expect(events.last == .finished(reason: .failed))
        await session.close()
    }

    /// A burst is still waited out, and the turn goes on.
    @Test(.timeLimit(.minutes(1)))
    func `a burst is asked again, as before`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let busy = StandInProvider.Reply.error(
            429,
            #"{"error":{"message":"Sorry, you have been rate-limited. Please wait a moment before trying again.","code":"rate_limited"}}"#,
            headers: ["retry-after": "0"],
        )
        let server = try #require(await StandInProvider([busy, .completion("Hello.")]))
        defer { server.stop() }
        let session = try await Self.session(home, server)
        let events = try await Self.run(session) { try await session.prompt("Hi") }
        #expect(server.requests == 2)
        #expect(events.contains(.reconnecting))
        #expect(events.contains(.messageFinished(text: "Hello.")))
        #expect(events.last == .finished(reason: .completed))
        await session.close()
    }

    /// A message sent while the run went would start the next run, which
    /// the same allowance fails again (with 0.4.7, 200 s of "Reconnecting…"
    /// in all): it goes back to the reader instead.
    @Test(.timeLimit(.minutes(1)))
    func `a message queued behind a spent allowance goes back to the reader`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let server = try #require(await StandInProvider([Self.copilotAllowance.after(1)]))
        defer { server.stop() }
        let session = try await Self.session(home, server)
        let queued = UUID()
        let events = try await Self.run(session) {
            try await session.prompt("Hi", messageID: UUID())
            try await Task.sleep(for: .milliseconds(300))
            try await session.prompt("And this", messageID: queued)
        }
        #expect(events.contains(.queuedMessagesDropped(ids: [queued])))
        #expect(events.count(where: {
            if case .finished = $0 {
                true
            } else {
                false
            }
        }) == 1)
        // nothing more starts
        try await Task.sleep(for: .milliseconds(300))
        #expect(server.requests == 1)
        await session.close()
    }
}
