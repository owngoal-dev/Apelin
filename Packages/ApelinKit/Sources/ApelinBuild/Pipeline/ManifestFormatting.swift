import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation

/// Every build puts the project's `apelin-project.json` into its written
/// form before its first step (`ProjectManifestFormat.formatFile`), so a
/// file written on one line, by Apelin before or by hand, is tidied once and
/// a formatted one is left alone. Only the text changes, so the digests the
/// check took and the host approved are the same after it.
enum ManifestFormatting {
    /// The build log's line about it; nil when there was nothing to do. A
    /// manifest that could not be written is left as it is and the build
    /// goes on: the file reads as before. So is one the check digested as
    /// a file of the build or the package (`checkedFiles`, a project that
    /// packages its own manifest): those bytes are what was approved and
    /// what the package must carry.
    static func run(projectRoot: URL, checkedFiles: [String: String]? = nil) -> String? {
        if let checkedFiles, digests(manifestOf: projectRoot, among: Array(checkedFiles.keys)) {
            return "apelin-project.json was left as it is: the build or the package takes it as a file"
        }
        do {
            guard try ProjectManifestFormat.formatFile(in: projectRoot) else { return nil }
            return "formatted apelin-project.json: two spaces a level, one member a line; no value changed"
        } catch {
            let reason = (error as? ApelinError)?.message ?? error.localizedDescription
            return "apelin-project.json was left as it is: \(reason)"
        }
    }

    /// Whether one of `paths`, relative to the project, is its manifest
    /// once links are resolved.
    static func digests(manifestOf projectRoot: URL, among paths: [String]) -> Bool {
        let manifest = projectRoot.appendingPathComponent(ProjectStore.projectFileName)
        guard let canonical = CanonicalPath.resolve(manifest.path) else { return false }
        return paths.contains { path in
            CanonicalPath.resolve(projectRoot.appendingPathComponent(path).path) == canonical
        }
    }
}
