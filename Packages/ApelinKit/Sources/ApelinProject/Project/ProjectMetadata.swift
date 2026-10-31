import ApelinCore
import ApelinProtocol
import Foundation

/// Display metadata lives in the real manifest; folder and project identities
/// do not change. Build and packaging digests deliberately exclude these fields.
public enum ProjectMetadata {
    /// A new project's manifest, the template's document in the written
    /// form (`ProjectManifestFormat`), with a generated name when it has one.
    public static func initial(_ data: Data, name: String, automaticallyName: Bool) throws -> Data {
        guard automaticallyName else { return ProjectManifestFormat.formatted(data) ?? data }
        guard case var .object(document) = try StrictJSON.parse(data) else {
            throw ApelinError(.badRequest, "The project manifest is not an object.")
        }
        if document["displayName"] != nil || document["autoName"] != nil {
            document["displayName"] = .string(name)
            document["autoName"] = .bool(true)
        } else {
            // First, where a reader looks for the name. Existing templates
            // have neither optional field, so only two members are added.
            document = JSONObject([("displayName", .string(name)), ("autoName", .bool(true))] + document.entries)
        }
        return ProjectManifestFormat.data(.object(document))
    }

    public static func rename(_ request: ProjectRenameRequest, in folder: DataFolder) throws -> ProjectRenameResponse {
        guard ProjectDisplayName.isValid(request.displayName) else {
            throw ApelinError(
                .badRequest,
                "Use a project name of 1–\(ProjectDisplayName.maximumLength) characters on one line, without leading or trailing spaces.",
            )
        }
        ProjectManifestFile.lock.lock()
        defer { ProjectManifestFile.lock.unlock() }
        let located = try? ProjectStore(dataFolder: folder).root(of: request.projectID)
        guard let candidate = located?.root ?? folder.project(named: request.projectID),
              let projects = CanonicalPath.resolve(folder.projects.path),
              let root = CanonicalPath.resolve(candidate.path),
              CanonicalPath.isCanonical(root, inside: projects),
              CanonicalPath.components(root).count == CanonicalPath.components(projects).count + 1
        else {
            throw ApelinError(.notFound, "The project folder is no longer available.")
        }
        let file = try ProjectManifestFile(root: root)
        guard case var .object(document) = try StrictJSON.parse(file.original),
              let projectID = document["projectID"]?.stringValue
        else {
            throw ApelinError(.badRequest, "The project manifest has no identity.")
        }
        let current = document["displayName"]?.stringValue ?? candidate.lastPathComponent
        if request.onlyIfAutomatic, document["autoName"]?.boolValue != true || current != candidate.lastPathComponent {
            return ProjectRenameResponse(projectID: projectID, displayName: current, changed: false)
        }
        document["displayName"] = .string(request.displayName)
        document["autoName"] = .bool(false)
        // Refuse a concurrent manifest replacement or in-place edit.
        guard try file.replace(with: ProjectManifestFormat.data(.object(document)), ownerRequired: false) else {
            throw ApelinError(.conflict, "The project changed while it was being renamed. Try again.")
        }
        return ProjectRenameResponse(projectID: projectID, displayName: request.displayName, changed: true)
    }
}
