import ApelinProtocol
import Foundation

extension Notification.Name {
    static let composerModelSelectionChanged = Notification.Name("wiki.qaq.apelin.composerModelSelectionChanged")
}

/// The model every composer sends with, restored before the catalog loads.
/// Each control of the model row keeps a default of its own: this is the
/// model's, with the catalog's last word on what it offers; the reader's
/// effort and speed are `ComposerModelPreferences`, which only the reader's
/// pick changes. A model that does not offer them is sent the nearest it
/// does, and a later model that offers them gets them back.
struct ComposerModelSelection: Codable, Equatable {
    var provider: AgentProvider
    var model: String
    /// The last catalog snapshot, so the effort control also restores offline.
    var supportedEfforts: [AgentReasoningEffort]
    /// The tiers the model offers, from the same snapshot; absent in a
    /// selection saved before there were any.
    var supportedTiers: [AgentServiceTier]?

    /// The effort sent: the reader's where the model offers it, else High,
    /// else its strongest; nil for a model that offers none.
    var effort: AgentReasoningEffort? {
        if let chosen = ComposerModelPreferences.effort, supportedEfforts.contains(chosen) {
            return chosen
        }
        return supportedEfforts.contains(.high) ? .high : supportedEfforts.last
    }

    /// The tier sent: the reader's where the model offers it, else the
    /// standard one (nil).
    var tier: AgentServiceTier? {
        ComposerModelPreferences.tier.flatMap { (supportedTiers ?? []).contains($0) ? $0 : nil }
    }

    /// The context window and largest reply the reader set for this model
    /// in Model Providers (#68); nil is automatic.
    var limits: AgentModelLimits? {
        ModelLimitsStore.limits(for: provider, model: model)
    }

    static var current: Self? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        set {
            ComposerModelPreferences.adoptLegacyPicks()
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: key)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// A choice of a retired provider's model (`AgentProvider.retired`) is
    /// removed, after adopting any legacy effort/tier picks it still held.
    /// It no longer decodes, so the composer already reads it as no choice and
    /// takes another signed-in account's model, or asks for one.
    static func forgetRetiredProvider(in defaults: UserDefaults = .standard) {
        struct Named: Decodable {
            var provider: String
        }
        guard let data = defaults.data(forKey: key),
              let named = try? JSONDecoder().decode(Named.self, from: data),
              AgentProvider.retired.contains(where: { $0.name == named.provider })
        else { return }
        ComposerModelPreferences.adoptLegacyPicks(in: defaults)
        defaults.removeObject(forKey: key)
    }

    fileprivate static let key = "composer.modelSelection"
}

/// The reader's own picks on the effort and Speed controls, each kept
/// under its own key whatever model is chosen and whatever its catalog
/// lists, so a model that lacks one, or a catalog that briefly says
/// nothing, never takes it away.
enum ComposerModelPreferences {
    private static let effortKey = "composer.reasoningEffort"
    private static let tierKey = "composer.serviceTier"
    /// What `tierKey` holds for a reader who picked Standard, so the pick
    /// is told apart from a key never written.
    private static let standardTier = "standard"

    /// Nil until the reader picks one.
    static var effort: AgentReasoningEffort? {
        get {
            UserDefaults.standard.string(forKey: effortKey).flatMap(AgentReasoningEffort.init(rawValue:))
                ?? legacy?.effort
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: effortKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// Nil is the standard tier.
    static var tier: AgentServiceTier? {
        get {
            guard let saved = UserDefaults.standard.string(forKey: tierKey) else { return legacy?.tier }
            return AgentServiceTier(rawValue: saved)
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue ?? standardTier, forKey: tierKey)
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }

    /// The picks a selection saved before these keys existed held itself;
    /// read until the selection is written again, which moves them here.
    private struct Legacy: Decodable {
        var effort: AgentReasoningEffort?
        var tier: AgentServiceTier?
    }

    private static var legacy: Legacy? {
        legacy(in: .standard)
    }

    private static func legacy(in defaults: UserDefaults) -> Legacy? {
        defaults.data(forKey: ComposerModelSelection.key)
            .flatMap { try? JSONDecoder().decode(Legacy.self, from: $0) }
    }

    /// Before a new selection replaces one that still holds the picks.
    fileprivate static func adoptLegacyPicks(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: effortKey) == nil || defaults.object(forKey: tierKey) == nil,
              let legacy = legacy(in: defaults)
        else { return }
        if defaults.object(forKey: effortKey) == nil, let effort = legacy.effort {
            defaults.set(effort.rawValue, forKey: effortKey)
        }
        if defaults.object(forKey: tierKey) == nil {
            defaults.set(legacy.tier?.rawValue ?? standardTier, forKey: tierKey)
        }
    }
}
