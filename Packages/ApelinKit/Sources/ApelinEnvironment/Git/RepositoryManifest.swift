import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import Foundation

/// A repository's `apelin-project.json` coming into a project folder that
/// has one of its own (issue #32). The repository's is the project's
/// description and wins; what is settled is the identity in it, so a
/// project never takes an ID another project, conversation, build or
/// memory already has, and an established project never loses its own.
///
/// A file that does not read as a project's manifest — a JSON object with
/// a `projectID` — is refused, and nothing changes. Nothing in it runs and
/// nothing is recorded as approved: the host's ledger holds no digest of an
/// imported description, so a Strict build of it asks.
final class RepositoryManifest {
    static let fileName = ProjectStore.projectFileName

    /// The project's own ID, nil when its manifest has none.
    let ownID: String?
    /// Whether the project may take the repository's ID instead: a new
    /// workspace nothing names yet, or a project with no ID of its own.
    let mayTakeTheirs: Bool
    private let projects: ProjectLocator
    private let root: URL

    /// What the file is once the repository's tree is in; `project` until
    /// the repository is found to have one.
    private(set) var file: GitProjectFile = .project
    /// The ID the project has then.
    private(set) var projectID: String?

    init(ownID: String?, mayTakeTheirs: Bool, root: URL, projects: ProjectLocator) {
        self.ownID = ownID
        self.mayTakeTheirs = mayTakeTheirs
        self.root = root
        self.projects = projects
        projectID = ownID
    }

    /// For a clone into the workspace at `root`: nil unless its manifest
    /// holds nothing but a new workspace's identity, the one case the
    /// repository's file takes its place. Its ID gives way to the
    /// repository's only while nothing names it.
    static func forImport(into root: URL, projects: ProjectLocator) -> RepositoryManifest? {
        guard let data = try? ProjectFiles.read(fileName, in: root), ProjectManifestIdentity.isBareWorkspace(data),
              let id = ProjectManifestIdentity.projectID(in: data)
        else { return nil }
        let named = ProjectReferences(data: projects.layout.data).names(id)
        return RepositoryManifest(ownID: id, mayTakeTheirs: !named, root: root, projects: projects)
    }

    /// The clone's replacement of the workspace's file by the repository's.
    var replacement: GitClone.Replacement {
        GitClone.Replacement(path: Self.fileName) { [self] theirs in try settle(theirs) }
    }

    /// The bytes the folder keeps of the repository's `theirs`: as they are
    /// when the project may take their ID and nothing else has it, else
    /// with the project's own ID (a fresh one for a project with none) put
    /// in its one quoted place.
    func settle(_ theirs: Data) throws -> Data {
        guard let theirID = ProjectManifestIdentity.projectID(in: theirs) else {
            throw ApelinError(
                .badRequest,
                "The repository's \(Self.fileName) does not read as a project's: it is not a JSON object with a projectID. Fix it in the repository, or use a branch without it.",
            )
        }
        if theirID == ownID || mayTakeTheirs && isFree(theirID) {
            file = .repository
            projectID = theirID
            return theirs
        }
        let id = ownID ?? UUID().uuidString.lowercased()
        guard let ours = ProjectManifestIdentity.replacing(theirID, with: id, in: theirs) else {
            throw ApelinError(
                .badRequest,
                "The repository's \(Self.fileName) has its projectID in more than one place, so it cannot be given this project's.",
            )
        }
        file = .repositoryWithProjectID
        projectID = id
        return ours
    }

    /// Whether `id` is Apelin's shape of ID and nothing on this device has
    /// it: no other project's folder, conversation, build or memory.
    private func isFree(_ id: String) -> Bool {
        guard ProjectManifestIdentity.isApelinID(id) else { return false }
        let others = projects.all().filter { $0.root.standardizedFileURL.path != root.standardizedFileURL.path }
        guard !others.contains(where: { $0.projectID == id }) else { return false }
        return !ProjectReferences(data: projects.layout.data).names(id)
    }
}
