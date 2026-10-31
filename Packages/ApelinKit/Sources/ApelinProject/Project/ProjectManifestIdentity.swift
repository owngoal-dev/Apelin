import ApelinCore
import Foundation

/// The identity in an `apelin-project.json`, read and given another without
/// touching any other byte of the file: how a transferred project gets an ID
/// of its own here, and how a repository's file that comes into a project
/// folder keeps the project's.
public enum ProjectManifestIdentity {
    /// The members a new workspace's manifest has (`ProjectStore.createEmpty`):
    /// its identity and its name, nothing that describes a build.
    static let workspaceIdentityMembers: Set<String> = [
        "schemaVersion", "projectID", "kind", "buildSystem", "displayName", "autoName",
    ]

    /// The `projectID` of `data`, or nil when it does not read as a project's
    /// manifest: a JSON object with a non-empty string `projectID`.
    public static func projectID(in data: Data) -> String? {
        guard case let .object(members)? = try? StrictJSON.parse(data),
              let id = members["projectID"]?.stringValue, !id.isEmpty
        else { return nil }
        return id
    }

    /// `data` with its one quoted occurrence of `old` replaced by `new` and
    /// nothing else changed; nil when `old` is not in it exactly once, or the
    /// result does not carry `new` as its `projectID`.
    public static func replacing(_ old: String, with new: String, in data: Data) -> Data? {
        let text = String(decoding: data, as: UTF8.self)
        let quoted = CanonicalJSON.quote(old)
        guard text.components(separatedBy: quoted).count == 2 else { return nil }
        let rewritten = Data(text.replacingOccurrences(of: quoted, with: CanonicalJSON.quote(new)).utf8)
        return projectID(in: rewritten) == new ? rewritten : nil
    }

    /// Whether `id` is shaped as Apelin makes one, a lowercase UUID, and so
    /// is safe to name folders and records by.
    public static func isApelinID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil && id == id.lowercased()
    }

    /// Whether `data` is a workspace's manifest that holds nothing but its
    /// identity and name, as a new workspace's does: no build declared, no
    /// description, nothing a repository's own file would take away.
    public static func isBareWorkspace(_ data: Data) -> Bool {
        guard case let .object(members)? = try? StrictJSON.parse(data),
              members["kind"]?.stringValue == "workspace"
        else { return false }
        return Set(members.keys).isSubset(of: workspaceIdentityMembers)
    }
}
