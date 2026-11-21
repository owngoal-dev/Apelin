import Foundation
import KWWKAgent
import KWWKAI

/// A provider saying the account's allowance is spent, where kwwk reads a
/// rate limit it waits out (#67).
///
/// kwwk tries a rate-limited request eight times over a minute and a half
/// (`ProviderRetryPolicy`), and longer where the provider asks it to wait.
/// That is right for a burst, and wrong for a spent plan or balance, which
/// no wait in a turn brings back: GitHub Copilot's 429 `quota_exceeded`
/// for a spent premium request allowance, Z.ai's and BigModel's 429 for a
/// spent five-hour, weekly or monthly window or an expired plan, a daily
/// limit. The chat read "Reconnecting…" for all that time and then said
/// "Too Many Requests", and the reader sent again into the same wait.
///
/// Around the requests a session's agent makes, an attempt that failed so
/// is marked not to be asked again (`ProviderFailure.shouldRetry`), so the
/// turn ends at once, and `FailureReason` says it is the quota. A failure
/// kwwk already reads as spent credit is its own; a rate limit that names
/// a window of seconds or minutes stays one, and kwwk waits it out.
enum SpentAllowance {
    /// Provider codes that name a spent allowance whatever the status.
    private static let codes: Set<String> = ["quota_exceeded"]

    /// Words that name a spent allowance, a plan's window or an expired
    /// plan, lowercased. Each says so on its own, never a busy moment.
    private static let words = [
        // GitHub Copilot
        "quota_exceeded", "premium request", "monthly chat messages limit",
        // Z.ai and BigModel (codes 1308, 1309, 1310), Kimi
        "limit will reset", "limit exhausted", "package has expired", "plan has expired",
        "reached your usage limit", "reached your monthly", "reached your weekly", "reached your daily",
        "quota will reset", "quota will be refreshed",
        // a day's allowance (OpenRouter's free models, a provider's requests per day)
        "per day", "per-day", "daily limit",
        // the same in Chinese
        "使用上限", "限额将在", "额度已用", "额度用尽", "额度已耗尽", "额度不足", "配额已用", "套餐已过期", "套餐已到期",
    ]

    /// A window short enough to wait out: a limit per second or minute.
    private static let shortWindow = #"\b(?:per|a|each|/)\s?(?:second|sec|minute|min)\b|\b(?:rpm|tpm|rps)\b|每分钟|每秒"#

    /// Whether `failure` says the account's allowance is spent: kwwk's own
    /// reading, or one of the words above on a failure it reads as a rate
    /// limit or does not name.
    static func isSpent(_ failure: ProviderFailure) -> Bool {
        switch failure.category {
        case .quota:
            return true
        case .rateLimit, .unknown:
            if codes.contains(failure.providerCode?.lowercased() ?? "") {
                return true
            }
            let text = [failure.providerCode, failure.message, failure.upstreamMessage]
                .compactMap(\.self)
                .joined(separator: " ")
                .lowercased()
            guard text.range(of: shortWindow, options: .regularExpression) == nil else { return false }
            return words.contains(where: text.contains)
        default:
            return false
        }
    }

    /// `failure` as kwwk should take it: not to be asked again when it says
    /// the allowance is spent and kwwk would ask again.
    static func settled(_ failure: ProviderFailure) -> ProviderFailure {
        guard failure.isRetryable, isSpent(failure) else { return failure }
        var settled = failure
        settled.shouldRetry = false
        return settled
    }

    /// `inner` with each attempt that ended on a spent allowance marked
    /// not to be asked again; anything else passes as it came.
    static func stream(_ inner: @escaping StreamFn) -> StreamFn {
        { model, context, options in
            let attempt: AssistantMessageStream
            do {
                attempt = try await inner(model, context, options)
            } catch let failure as ProviderFailure {
                throw settled(failure)
            }
            let (stream, out) = AssistantMessageStream.makeStream()
            Task {
                var ending: AssistantMessageEvent?
                for await event in attempt {
                    switch event {
                    case .done, .error:
                        ending = event
                    default:
                        out.push(event)
                    }
                }
                var final = await attempt.result()
                if final.stopReason == .error, let failure = final.providerFailure {
                    let settled = settled(failure)
                    if settled != failure {
                        final.failure = settled
                        ending = .error(reason: .error, error: final)
                    }
                }
                if let ending {
                    out.push(ending)
                }
                out.end(final)
            }
            return stream
        }
    }
}
