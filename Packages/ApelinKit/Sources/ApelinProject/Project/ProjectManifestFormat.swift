import ApelinCore
import ApelinProtocol
import Foundation

/// How Apelin writes `apelin-project.json` (Documents/Schemas/README.md ▸
/// Written form): two spaces a level, one member or element a line,
/// members in the order they were written, strings with only the escapes
/// JSON requires, `\n` line ends and one after the document. Every writer
/// of the file writes this, and a build puts a file written otherwise into
/// it (`formatFile(in:)`), so the file reads in a diff and on GitHub. Only
/// the text changes, never a value or an order, and so never a digest:
/// `ApprovalDigests` are taken over the parsed document's canonical JSON.
/// Byte for byte the reference implementation's `manifest_text`.
public enum ProjectManifestFormat {
    /// `document` in the written form.
    public static func data(_ document: JSONDocument) -> Data {
        Data((JSONWriter.indented(document) + "\n").utf8)
    }

    /// `data` in the written form, the same bytes when it already is; nil
    /// when it does not read strictly (`StrictJSON`), which leaves a file
    /// as it is. What it answers reads back as the very document `data`
    /// held, member order included; otherwise it answers nil.
    public static func formatted(_ data: Data) -> Data? {
        guard let document = try? StrictJSON.parse(data) else { return nil }
        let text = Self.data(document)
        guard let again = try? StrictJSON.parse(text), JSONWriter.compact(again) == JSONWriter.compact(document) else {
            return nil
        }
        return text
    }

    /// The largest manifest the other readers of the file take (the agent's
    /// and the host's): one past it is left as it is.
    public static let maximumBytes = 1024 * 1024

    /// The manifest of the project folder `root` put into the written form
    /// when it reads strictly and is not in it yet: replaced relative to
    /// the opened folder, never through a link — the folder itself is no
    /// link (`Projects/<name>` pointing elsewhere is refused) —, its mode
    /// and owner kept (`ProjectManifestFile`; one whose owner cannot be kept
    /// is `denied`). True when it was rewritten; a file already in the form,
    /// one that does not read, or one past `maximumBytes` is not written.
    public static func formatFile(in root: URL) throws -> Bool {
        guard let path = CanonicalPath.resolve(root.path),
              let parent = CanonicalPath.resolve(root.deletingLastPathComponent().path),
              path == (parent as NSString).appendingPathComponent(root.lastPathComponent)
        else {
            throw ApelinError(.notFound, "The project folder is no longer available.")
        }
        ProjectManifestFile.lock.lock()
        defer { ProjectManifestFile.lock.unlock() }
        let file = try ProjectManifestFile(root: path)
        guard file.original.count <= maximumBytes,
              let text = formatted(file.original), text != file.original else { return false }
        guard try file.replace(with: text, ownerRequired: true) else {
            throw ApelinError(.conflict, "apelin-project.json changed while it was being formatted.")
        }
        return true
    }
}
