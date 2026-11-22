import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// A project deleted for good (`projectDelete`), as mobile: the real
/// folder directly under `Projects/` whose `apelin-project.json` names the
/// id asked for, removed by `DataFolder.removeProject`, the app's own
/// Delete, so a link inside it is removed and never followed, and the
/// user's custom instructions for it with it. The session host has closed
/// the project's conversations first; the app takes their histories away
/// when it sees the folder gone.
public enum ProjectDeletion {
    private static let maximumManifestBytes = 1 << 20

    public static func delete(_ request: ProjectDeleteRequest, in folder: DataFolder) throws -> ProjectDeleteResponse {
        let name = try request.projectName ?? ProjectStore(dataFolder: folder).root(of: request.projectID).name
        guard ProjectName.validate(name) == nil else {
            throw ApelinError(.badRequest, "“\(name)” is not a project folder; nothing was deleted.")
        }
        guard let root = CanonicalPath.resolve(folder.root.path),
              let projects = CanonicalPath.resolve(folder.projects.path), projects == root + "/Projects"
        else {
            throw ApelinError(.notFound, "There is no Projects folder; nothing was deleted.")
        }
        guard try projectID(of: name, in: projects) == request.projectID else {
            throw ApelinError(.conflict, "Projects/\(name) holds another project now; nothing was deleted.")
        }
        do {
            try folder.removeProject(named: name)
        } catch {
            throw ApelinError(.internal, "Projects/\(name) could not be removed whole: \(error.localizedDescription)")
        }
        // the user's custom instructions for it go with it; one left behind
        // is taken by the app's next sweep (`removeGoneProjects`)
        try? CustomInstructionsStore(root: folder.root).removeProject(request.projectID)
        return ProjectDeleteResponse(projectID: request.projectID, projectName: name)
    }

    /// The id `Projects/<name>` carries, read without following a link:
    /// neither the folder nor its manifest may be one.
    private static func projectID(of name: String, in projects: String) throws -> String? {
        let directory = open(projects + "/" + name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            if errno == ENOENT {
                throw ApelinError(.notFound, "The project “\(name)” is no longer available.")
            }
            throw ApelinError(.badRequest, "Projects/\(name) is not a project folder: a link is never followed; nothing was deleted.")
        }
        defer { close(directory) }
        let descriptor = openat(directory, ProjectStore.projectFileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw ApelinError(.badRequest, "Projects/\(name) has no \(ProjectStore.projectFileName) of its own; nothing was deleted.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumManifestBytes,
              let data = try handle.readToEnd(), let document = try? StrictJSON.parse(data)
        else {
            throw ApelinError(.badRequest, "Projects/\(name)/\(ProjectStore.projectFileName) does not read; nothing was deleted.")
        }
        return document["projectID"]?.stringValue
    }
}
