import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
enum EnabledModels {
    private static func key(_ provider: AgentProvider) -> String {
        "enabledModels.\(provider.rawValue)"
    }

    static func ids(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(provider)) ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for provider: AgentProvider) {
        UserDefaults.standard.set(models.sorted(), forKey: key(provider))
        UserDefaults.standard.set(custom.sorted(), forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.set(hidden.sorted(), forKey: "hiddenModels.\(provider.rawValue)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for provider: AgentProvider) {
        UserDefaults.standard.removeObject(forKey: key(provider))
        UserDefaults.standard.removeObject(forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.removeObject(forKey: "hiddenModels.\(provider.rawValue)")
        ModelLimitsStore.remove(for: provider)
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func customIDs(for provider: AgentProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "customModels.\(provider.rawValue)") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenModels.\(provider.rawValue)") ?? [])
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            let ids = ids(for: account.provider).subtracting(hiddenIDs(for: account.provider))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
