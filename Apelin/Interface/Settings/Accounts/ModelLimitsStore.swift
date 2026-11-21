import ApelinProtocol
import Foundation

/// The context window and largest reply the user set for a model of an
/// API-key account (#68): a device preference beside `EnabledModels`, kept
/// per provider (`AgentProvider.rawValue`, so each OpenAI-compatible
/// endpoint has its own) and model ID, never a secret, and cleared with
/// the provider's sign-in. A field the user left empty is automatic.
///
/// Each model's entry is read by itself: one that does not read is
/// automatic, and is written back as it was with the others.
enum ModelLimitsStore {
    private static let contextWindowKey = "contextWindow"
    private static let maxOutputKey = "maxOutputTokens"

    private static func key(_ provider: AgentProvider) -> String {
        "modelLimits.\(provider.rawValue)"
    }

    /// What the user set for `model`; nil when every field is automatic.
    static func limits(for provider: AgentProvider, model: String) -> AgentModelLimits? {
        guard let entry = UserDefaults.standard.dictionary(forKey: key(provider))?[model] as? [String: Any] else {
            return nil
        }
        let limits = AgentModelLimits(
            contextWindow: entry[contextWindowKey] as? Int,
            maxOutputTokens: entry[maxOutputKey] as? Int,
        )
        return limits.isAutomatic ? nil : limits
    }

    /// Sets `model`'s limits; nil, or limits with every field automatic,
    /// takes its entry away.
    static func save(_ limits: AgentModelLimits?, for provider: AgentProvider, model: String) {
        let defaults = UserDefaults.standard
        if let unreadable = defaults.object(forKey: key(provider)), !(unreadable is [String: Any]) {
            // never written over: set aside where it can still be found
            defaults.set(unreadable, forKey: key(provider) + ".unreadable")
        }
        var entries = defaults.dictionary(forKey: key(provider)) ?? [:]
        if let limits, !limits.isAutomatic {
            var entry: [String: Int] = [:]
            entry[contextWindowKey] = limits.contextWindow
            entry[maxOutputKey] = limits.maxOutputTokens
            entries[model] = entry
        } else {
            entries[model] = nil
        }
        // read again with each message: nothing needs telling
        defaults.set(entries.isEmpty ? nil : entries, forKey: key(provider))
    }

    /// Every model's, on sign-out.
    static func remove(for provider: AgentProvider) {
        UserDefaults.standard.removeObject(forKey: key(provider))
    }
}
