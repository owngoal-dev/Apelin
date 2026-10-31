/// What became of a project's `apelin-project.json` when a repository's tree
/// came into its folder (issue #32): a clone into a new workspace, or a
/// reset to a remote. The repository's file is the project's description;
/// the identity in it is settled so a project never takes another's.
public enum GitProjectFile: String, Codable, Sendable, Equatable {
    /// The repository's, as it is: the project has its `projectID` now.
    case repository
    /// The repository's, with the project's own `projectID` in place of the
    /// one it carried, nothing else changed: the file shows as changed in
    /// git, and goes into the next commit.
    case repositoryWithProjectID
    /// The project's own: the repository has none, so it is kept, out of
    /// the repository through `.git/info/exclude`.
    case project
}
