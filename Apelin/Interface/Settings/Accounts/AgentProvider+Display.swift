import ApelinProtocol
import UIKit

/// How Settings shows each provider: its name, its mark and the one line
/// that says what signing in to it means. Marks live in `Provider*.imageset`;
/// DeepSeek's is the unmodified official whale SVG:
/// https://api-docs.deepseek.com/img/favicon.svg and OpenCode Go's is the
/// unmodified official favicon SVG: https://opencode.ai/favicon.svg
/// Which providers there are, and in
/// what order, is apelin-agent's answer, not this file's.
extension AgentProvider {
    var displayName: String {
        switch self {
        case .githubCopilot: String(localized: "GitHub Copilot")
        case .anthropicOAuth: String(localized: "Claude Code")
        case .anthropic: String(localized: "Anthropic API")
        case .openAICompatible: String(localized: "OpenAI-Compatible API")
        case .openAICodex: String(localized: "ChatGPT Codex")
        case .cursor: String(localized: "Cursor")
        case .devin: String(localized: "Devin")
        case .kiro: String(localized: "Kiro")
        case .qoder: String(localized: "Qoder")
        case .qoderCN: String(localized: "Qoder CN")
        case .workBuddy: String(localized: "WorkBuddy")
        case .workBuddyAI: String(localized: "WorkBuddy AI")
        case .kimiCoding: String(localized: "Kimi For Coding")
        case .xai: String(localized: "Grok")
        case .zai: String(localized: "Z.ai Coding Plan")
        case .zaiCodingCN: String(localized: "BigModel Coding Plan")
        case .openRouter: String(localized: "OpenRouter")
        case .openAI: String(localized: "OpenAI API")
        case .google: String(localized: "Google AI Studio")
        case .deepSeek: String(localized: "DeepSeek")
        case .openCodeGo: String(localized: "OpenCode Go")
        }
    }

    var icon: UIImage? {
        switch self {
        case .githubCopilot: UIImage(named: "ProviderGitHubCopilot")
        case .anthropicOAuth: UIImage(named: "ProviderClaude")
        case .anthropic: UIImage(named: "ProviderAnthropicAPI")
        case .openAICompatible: UIImage(named: "ProviderOpenAICompatible")
        case .openAICodex: UIImage(named: "ProviderChatGPTCodex")
        case .cursor: UIImage(named: "ProviderCursor")
        case .devin: UIImage(named: "ProviderDevin")
        case .kiro: UIImage(named: "ProviderKiro")
        case .qoder: UIImage(named: "ProviderQoder")
        case .qoderCN: UIImage(named: "ProviderQoderCN")
        case .workBuddy: UIImage(named: "ProviderWorkBuddy")
        case .workBuddyAI: UIImage(named: "ProviderWorkBuddyAI")
        case .kimiCoding: UIImage(named: "ProviderKimi")
        case .xai: UIImage(named: "ProviderGrok")
        case .zai: UIImage(named: "ProviderZai")
        case .zaiCodingCN: UIImage(named: "ProviderBigModel")
        case .openRouter: UIImage(named: "ProviderOpenRouter")
        case .openAI: UIImage(named: "ProviderOpenAIAPI")
        case .google: UIImage(named: "ProviderGoogleAI")
        case .deepSeek: UIImage(named: "ProviderDeepSeek")
        case .openCodeGo: UIImage(named: "ProviderOpenCodeGo")
        }
    }

    /// Under the mark at the top of the sign-in page.
    var signInSummary: String {
        switch self {
        case .githubCopilot:
            String(localized: "Sign in with the GitHub account that has your Copilot subscription.")
        case .anthropicOAuth:
            String(localized: "Sign in with your Claude Pro or Max plan.")
        case .anthropic:
            String(localized: "Use an API key from the Anthropic Console.")
        case .openAICompatible:
            String(localized: "Use an endpoint that supports the OpenAI Chat Completions API.")
        case .openAICodex:
            String(localized: "Sign in with your ChatGPT Plus or Pro plan.")
        case .cursor:
            String(localized: "Sign in with your Cursor subscription.")
        case .devin:
            String(localized: "Sign in with your Devin or Windsurf subscription.")
        case .kiro:
            String(localized: "Sign in to Kiro with AWS Builder ID, Google or GitHub.")
        case .qoder:
            String(localized: "Sign in with your qoder.com subscription.")
        case .qoderCN:
            String(localized: "Sign in with your qoder.cn subscription.")
        case .workBuddy:
            String(localized: "Sign in to WorkBuddy with your CodeBuddy China plan.")
        case .workBuddyAI:
            String(localized: "Sign in to WorkBuddy AI with your CodeBuddy international plan.")
        case .kimiCoding:
            String(localized: "Sign in with your Kimi coding plan.")
        case .xai:
            String(localized: "Sign in with your SuperGrok or X Premium subscription.")
        case .zai:
            String(localized: "Sign in to Z.ai to get an API key for your GLM Coding Plan.")
        case .zaiCodingCN:
            String(localized: "Sign in to bigmodel.cn to get an API key for your GLM Coding Plan.")
        case .openRouter:
            String(localized: "Sign in to OpenRouter for a new key, or use a key you have.")
        case .openAI:
            String(localized: "Use an API key from the OpenAI platform.")
        case .google:
            String(localized: "Use a Gemini API key from Google AI Studio.")
        case .deepSeek:
            String(localized: "Use an API key from the DeepSeek platform.")
        case .openCodeGo:
            String(localized: "Use an API key from the OpenCode Console with a Go subscription.")
        }
    }
}

extension AgentSignInMethod {
    /// The row that switches a sign-in page to this method.
    var switchTitle: String {
        switch self {
        case .apiKey: String(localized: "Use API Key")
        case .browser: String(localized: "Use Web Sign-In")
        case .deviceCode: String(localized: "Use Sign-In Code")
        }
    }
}

extension AgentSignInField {
    var title: String {
        switch self {
        case .apiKey: String(localized: "API Key")
        case .baseURL: String(localized: "Base URL")
        case .defaultModel: String(localized: "Model")
        case .callbackURL: String(localized: "Redirect Address")
        }
    }
}
