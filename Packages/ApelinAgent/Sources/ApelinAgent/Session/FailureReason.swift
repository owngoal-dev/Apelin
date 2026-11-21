import ApelinProtocol
import Foundation
import KWWKAI

/// Why a model request failed, for the reader: kwwk's own reading of the
/// failure (`ProviderFailure.category`) as the reason an `error` event
/// carries (ApelinProtocol's `AgentFailure.swift`). The provider's words
/// stay the event's message; the app says the reason in a line of its own.
public enum FailureReason {
    /// URLSession's own codes for a device that is not on the network: not
    /// connected, cellular data off for the app, roaming off.
    private static let offlineCodes = [
        NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
    ]

    /// kwwk's own words when the conversation does not fit the model's
    /// window even after compacting it, before a request is sent. It says so
    /// with no status or provider code, in words meant for a log ("compaction
    /// left 51590 tokens, above the recovery target of 39000"): a single
    /// tool result larger than the window has room for, under a small
    /// window the user set (#68).
    private static let contextTooLarge = [
        "context is too large and compaction failed",
        "context is too large and could not be compacted",
        "input token budget even after compaction",
    ]

    /// The reason for `failure`, nil where its own words say it best: a
    /// refusal, a request the provider would not take, a stop.
    /// `hasRoute`: whether the device has a route to the network now.
    public static func of(_ failure: ProviderFailure, hasRoute: Bool) -> ApelinError.Reason? {
        // a spent allowance kwwk reads as a rate limit is the quota all the
        // same (`SpentAllowance`)
        if SpentAllowance.isSpent(failure) {
            return .quota
        }
        if failure.httpStatus == nil, failure.providerCode == nil,
           contextTooLarge.contains(where: failure.message.contains)
        {
            return .contextOverflow
        }
        switch failure.category {
        case .transport:
            let saysOffline = failure.transportDomain == NSURLErrorDomain
                && offlineCodes.contains(failure.transportCode ?? 0)
            return saysOffline || !hasRoute ? .offline : .network
        case .timeout:
            return hasRoute ? .timeout : .offline
        case .authentication: return .authentication
        case .quota: return .quota
        case .rateLimit: return .rateLimit
        case .server: return .server
        case .contextOverflow: return .contextOverflow
        case .invalidRequest:
            // kwwk never asks a failed handshake again, and so does not
            // count it as the connection's failure; for the reader it is
            return NetworkRecovery.isFailedHandshake(failure) ? .network : nil
        case .cancelled, .refusal, .unknown:
            return nil
        }
    }

    /// The reason for an error a request threw rather than answered with,
    /// as kwwk captures it.
    public static func of(_ error: any Error, hasRoute: Bool) -> ApelinError.Reason? {
        of(ProviderFailure.capture(error), hasRoute: hasRoute)
    }
}
