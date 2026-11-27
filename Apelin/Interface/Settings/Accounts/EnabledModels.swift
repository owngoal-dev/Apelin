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
        forget(provider.rawValue)
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    /// The enabled, custom, hidden and limited models kept for the provider of
    /// this wire name.
    private static func forget(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "enabledModels.\(name)")
        defaults.removeObject(forKey: "customModels.\(name)")
        defaults.removeObject(forKey: "hiddenModels.\(name)")
        ModelLimitsStore.remove(forName: name, in: defaults)
    }

    static func customIDs(for provider: AgentProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "customModels.\(provider.rawValue)") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenModels.\(provider.rawValue)") ?? [])
    }

    /// What a provider Apelin no longer offers left here
    /// (`AgentProvider.retired`): its enabled, custom, hidden and limited
    /// models, which nothing reads or signs out of any more, and a composer
    /// choice of one of them. At each launch; once they are gone it changes
    /// nothing.
    static func forgetRetiredProviders(in defaults: UserDefaults = .standard) {
        for name in Set(AgentProvider.retired.map(\.name)) {
            forget(name, in: defaults)
        }
        ComposerModelSelection.forgetRetiredProvider(in: defaults)
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
