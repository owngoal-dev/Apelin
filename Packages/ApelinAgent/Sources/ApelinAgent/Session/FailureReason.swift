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

    /// The reason for `failure`, nil where its own words say it best: a
    /// refusal, a request the provider would not take, a stop.
    /// `hasRoute`: whether the device has a route to the network now.
    public static func of(_ failure: ProviderFailure, hasRoute: Bool) -> ApelinError.Reason? {
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
