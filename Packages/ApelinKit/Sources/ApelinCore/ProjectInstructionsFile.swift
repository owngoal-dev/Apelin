import Foundation

/// The project's own instructions file, `AGENTS.md`, else `CLAUDE.md`, at
/// the project's root, as pi and kwwk read them from the working directory:
/// what a session puts in its system prompt, and what the app shows beside
/// the user's custom instructions as what a conversation loads. One reader
/// for both, so the two never disagree on which file counts.
///
/// Only a regular file whose canonical path is inside the project counts:
/// a link out of it is not followed. The file may have come with a
/// repository, from anyone.
public enum ProjectInstructionsFile {
    public static let names = ["AGENTS.md", "CLAUDE.md"]
    public static let maximumBytes = 16 * 1024
    public static let truncationNote = "\n… (truncated)"

    /// The first of `names` in the project at `root`, a canonical path, with
    /// its text trimmed and cut at `maximumBytes`; nil when there is none.
    public static func read(projectRoot root: String) -> (file: String, text: String)? {
        for file in names {
            guard let path = CanonicalPath.resolve(root + "/" + file),
                  CanonicalPath.isCanonical(path, inside: root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maximumBytes + 1)) ?? Data()
            var text = String(decoding: data.prefix(maximumBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if data.count > maximumBytes {
                text += truncationNote
            }
            return (file, text)
        }
        return nil
    }
}
