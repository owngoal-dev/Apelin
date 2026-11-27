import ApelinProtocol
import Foundation

/// App-side preference cleanup when a retired provider is removed on launch
/// (`EnabledModels.forgetRetiredProviders`, `ModelLimitsStore.remove(forName:)`,
/// and `ComposerModelSelection.forgetRetiredProvider`).
func checkRetiredProviderCleanup() {
    let suite = "wiki.qaq.apelin.test.retired-provider-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    // 1. Seed retired Antigravity keys + active OpenAI keys + legacy embedded effort/tier.
    defaults.set(["gemini-4-neon-high"], forKey: "enabledModels.antigravity")
    defaults.set(["custom-agy"], forKey: "customModels.antigravity")
    defaults.set(["hidden-agy"], forKey: "hiddenModels.antigravity")
    defaults.set(["gemini-4-neon-high": ["contextWindow": 200_000]], forKey: "modelLimits.antigravity")
    defaults.set("corrupt", forKey: "modelLimits.antigravity.unreadable")

    defaults.set(["gpt-5"], forKey: "enabledModels.openAI")
    defaults.set(["custom-openai"], forKey: "customModels.openAI")
    defaults.set(["hidden-openai"], forKey: "hiddenModels.openAI")
    defaults.set(["gpt-5": ["contextWindow": 400_000]], forKey: "modelLimits.openAI")
    defaults.set("keep-aside", forKey: "modelLimits.openAI.unreadable")

    let legacyRetiredSelection = Data(
        #"{"provider":"antigravity","model":"gemini-4-neon-high","supportedEfforts":["low","high"],"effort":"high","tier":"priority"}"#
            .utf8,
    )
    defaults.set(legacyRetiredSelection, forKey: "composer.modelSelection")

    EnabledModels.forgetRetiredProviders(in: defaults)

    // Retired keys are removed.
    for key in [
        "enabledModels.antigravity",
        "customModels.antigravity",
        "hiddenModels.antigravity",
        "modelLimits.antigravity",
        "modelLimits.antigravity.unreadable",
        "composer.modelSelection",
    ] {
        precondition(defaults.object(forKey: key) == nil, "retired key \(key) was not removed")
    }

    // Legacy effort and tier embedded in the retired selection were adopted first.
    precondition(defaults.string(forKey: "composer.reasoningEffort") == AgentReasoningEffort.high.rawValue)
    precondition(defaults.string(forKey: "composer.serviceTier") == AgentServiceTier.priority.rawValue)

    // Active provider keys stay untouched.
    precondition(defaults.stringArray(forKey: "enabledModels.openAI") == ["gpt-5"])
    precondition(defaults.stringArray(forKey: "customModels.openAI") == ["custom-openai"])
    precondition(defaults.stringArray(forKey: "hiddenModels.openAI") == ["hidden-openai"])
    precondition(defaults.dictionary(forKey: "modelLimits.openAI") != nil)
    precondition(defaults.string(forKey: "modelLimits.openAI.unreadable") == "keep-aside")

    // 2. An active provider's composer selection and corrupt non-JSON data are left intact.
    let activeSelection = Data(
        #"{"provider":"openAI","model":"gpt-5","supportedEfforts":["high"]}"#.utf8,
    )
    defaults.set(activeSelection, forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.data(forKey: "composer.modelSelection") == activeSelection)

    let corrupt = Data("not-json".utf8)
    defaults.set(corrupt, forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.data(forKey: "composer.modelSelection") == corrupt)

    // 3. Re-running when clean is a no-op.
    defaults.removeObject(forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.object(forKey: "composer.modelSelection") == nil)

    print("ok: retired-provider preference cleanup clears Antigravity keys, adopts legacy picks and leaves active providers intact")
}
