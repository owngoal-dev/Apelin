import struct ApelinProtocol.AgentModelLimits
import struct ApelinToolCore.ToolManifestPolicy
import Foundation
import KWWKAgent
import KWWKAI

/// How a session is opened. The host fills it from the app's settings and
/// the project record; the agent cannot change any of it.
public struct AgentSessionConfiguration: Sendable {
    /// A UUID string; also the session folder's name.
    public var id: String
    public var project: ProjectIdentity
    public var temporaryID: String?
    public var provider: ProviderConfiguration
    public var approval: ApprovalPolicy
    public var dataRoot: ApelinDataRoot
    public var mcpServers: [MCPServerConfiguration]
    public var thinking: ThinkingLevel
    /// The processing tier its requests ask for; nil is the provider's default.
    public var serviceTier: ServiceTier?
    /// The model's context window and largest reply as the user set them;
    /// nil, or a field of it, is what the model resolves with.
    public var modelLimits: AgentModelLimits?
    /// Hard cap on assistant turns per run; nil for none.
    public var maxTurns: Int?
    /// The install root the session host derived from its own path, which
    /// the system prompt names with the bootstrap; nil where there is none
    /// (the Mac tests).
    public var installRoot: String?
    /// The device's language and clock, which each message's
    /// `<system-state>` names.
    public var systemState: SystemStateSource
    /// Whether the device has a route, which a model request the network
    /// failed waits for (`NetworkRecovery`).
    public var network: NetworkPath
    /// The session host started since this conversation last ran, as the
    /// host decides (`AgentOpenRequest.hostRestarted`): when it has history,
    /// the next message's `<system-state>` says its paths may be stale.
    public var hostRestarted: Bool
    /// Whom the agent tool extensions under the install root must belong
    /// to for their tools to be offered: root, as the package manager
    /// installs them and the host requires; the tests' own user.
    public var toolExtensionPolicy: ToolManifestPolicy

    public init(
        id: String = UUID().uuidString,
        project: ProjectIdentity,
        temporaryID: String? = nil,
        provider: ProviderConfiguration,
        approval: ApprovalPolicy,
        dataRoot: ApelinDataRoot = .current,
        mcpServers: [MCPServerConfiguration] = [],
        thinking: ThinkingLevel = .off,
        serviceTier: ServiceTier? = nil,
        modelLimits: AgentModelLimits? = nil,
        maxTurns: Int? = nil,
        installRoot: String? = nil,
        systemState: SystemStateSource = .device,
        network: NetworkPath = .system,
        hostRestarted: Bool = false,
        toolExtensionPolicy: ToolManifestPolicy = ToolManifestPolicy(),
    ) {
        self.id = id
        self.project = project
        self.temporaryID = temporaryID
        self.provider = provider
        self.approval = approval
        self.dataRoot = dataRoot
        self.mcpServers = mcpServers
        self.thinking = thinking
        self.serviceTier = serviceTier
        self.modelLimits = modelLimits
        self.maxTurns = maxTurns
        self.installRoot = installRoot
        self.systemState = systemState
        self.network = network
        self.hostRestarted = hostRestarted
        self.toolExtensionPolicy = toolExtensionPolicy
    }
}
