import Foundation
import KWWKAgent
import KWWKAI

/// kwwk's native compaction, except that a reply with no summary in it
/// falls back to kwwk's own summary instead of failing the compaction.
///
/// Anthropic's compaction can answer 200, stop reason `compaction`, with a
/// `compaction` block whose content is null: its documentation names a tool
/// called in place of the summary. kwwk keeps that an error ("Anthropic
/// compaction returned no summary"), and before 0.1.127 it did not
/// summarise itself, so a chat whose context had filled stopped with
/// "context is too large and compaction failed". A route that cannot
/// compact natively answers nil and kwwk summarises; this answers nil for a
/// reply that brought nothing back too. From 0.1.127 kwwk also summarises
/// after a native compaction that failed in any way but a refused sign-in
/// or a cancellation, so this is what it was before for a reply with no
/// summary, and every other failure passes as it came, but for a spent
/// allowance kwwk would wait out as a rate limit (`SpentAllowance`): that
/// is marked not to be asked again, so the native step gives up at once
/// and the summary, asked of the same account, ends on its first answer.
enum NativeCompactionFallback {
    static func compact(_ native: @escaping NativeCompactionFn = compactNative) -> NativeCompactionFn {
        { model, context, instructions, options in
            do {
                return try await native(model, context, instructions, options)
            } catch let error where returnedNoSummary(error) {
                return nil
            } catch {
                let failure = ProviderFailure.capture(error)
                let settled = SpentAllowance.settled(failure)
                throw settled == failure ? error : settled
            }
        }
    }

    /// A failure kwwk made of a reply that came back without a summary —
    /// none in it, or not the compaction asked for: no HTTP status, no
    /// transport or provider code, nothing it reads as a refusal or a limit
    /// (its own "Invalid …" wording reads as a bad request), and nothing it
    /// would retry.
    static func returnedNoSummary(_ error: any Error) -> Bool {
        guard let failure = error as? ProviderFailure else { return false }
        return failure.httpStatus == nil && failure.transportDomain == nil && failure.transportCode == nil
            && failure.providerCode == nil && [.unknown, .invalidRequest].contains(failure.category)
            && !failure.isRetryable
    }

    /// The compaction a session runs, on its own as the context fills and
    /// when the app asks: kwwk's defaults, with this in front of its native
    /// compaction.
    static var configuration: AgentContextCompactionConfig {
        AgentContextCompactionConfig(nativeCompaction: compact())
    }
}
