import ApelinCore
import ApelinProtocol
import Foundation

/// The registered toolchains (`Environment/Toolchains/registry.json`).
/// A record is written only after the installed bytes passed self-test; a
/// project binds a toolchain by ID and is never moved to a new default.
///
/// A record that does not decode stays in the file as it was
/// (`PreservedList`), and a file that does not read at all is set aside
/// (`UnreadableFile`) before anything is written in its place: one bad
/// record never unregisters the others.
public struct ToolchainRegistry: Codable, Sendable, Equatable {
    public var toolchains: [ToolchainRecord] = []
    public var defaultID: String?
    /// Records this version could not read, written back as they were.
    private var unreadable: [JSONValue] = []
    /// Set when the file did not read and could not be set aside: saving
    /// would replace it, so `save` refuses.
    private var blocked = false

    public init(toolchains: [ToolchainRecord] = [], defaultID: String? = nil) {
        self.toolchains = toolchains
        self.defaultID = defaultID
    }

    private enum CodingKeys: String, CodingKey {
        case toolchains, defaultID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let list = try container.decodeIfPresent(PreservedList<ToolchainRecord>.self, forKey: .toolchains)
            ?? PreservedList()
        toolchains = list.items
        unreadable = list.unreadable
        defaultID = try container.decodeIfPresent(String.self, forKey: .defaultID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // the unreadable records follow the readable ones in the same array
        try container.encode(PreservedList(toolchains, unreadable: unreadable), forKey: .toolchains)
        try container.encodeIfPresent(defaultID, forKey: .defaultID)
    }

    public static func == (lhs: ToolchainRegistry, rhs: ToolchainRegistry) -> Bool {
        lhs.toolchains == rhs.toolchains && lhs.defaultID == rhs.defaultID && lhs.unreadable == rhs.unreadable
    }

    /// The registry with each path under the bootstrap root as it is now
    /// (`BootstrapRootPath`): roothide renames its root on a reboot, and the
    /// tree moves with it.
    static func load(_ layout: EnvironmentLayout) -> ToolchainRegistry {
        let url = layout.toolchainRegistry
        guard let data = FileManager.default.contents(atPath: url.path) else { return ToolchainRegistry() }
        var registry: ToolchainRegistry
        do {
            registry = try JSONCoding.decode(ToolchainRegistry.self, from: data)
        } catch {
            registry = ToolchainRegistry()
            registry.blocked = UnreadableFile.setAside(url) == nil
        }
        for index in registry.toolchains.indices {
            registry.toolchains[index].path = registry.toolchains[index].path.map {
                BootstrapRootPath.rebased($0, onto: layout.installRoot)
            }
        }
        return registry
    }

    func save(_ layout: EnvironmentLayout) throws {
        guard !blocked else {
            throw ApelinError(.internal, "the toolchain registry does not read and could not be set aside; nothing was written over it")
        }
        try layout.make(layout.toolchains)
        try JSONFile.write(self, to: layout.toolchainRegistry)
    }
}
