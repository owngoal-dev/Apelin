import Foundation

/// A skill's `SKILL.md` as kwwk's loader reads it (KWWKAgent's `Skills`:
/// `parseFrontmatter`, `validateName`, `validateDescription`), for the
/// checks made before a skill goes into the skills folder: the agent's
/// apelin_skill_save, and Settings ▸ Skills ▸ From GitHub in the app, which
/// does not link kwwk. ApelinAgent's `SkillManifestTests` hold it to
/// kwwk's own loader.
///
/// The frontmatter is the flat `key: value` lines between a leading `---`
/// and the next `---` line; nothing else of YAML is read, so a description
/// written as a block (`description: >`) is that one character to kwwk.
public struct SkillManifest: Sendable, Equatable {
    /// kwwk's bounds (`Skills.maxNameLength`, `maxDescriptionLength`).
    public static let maximumNameLength = 64
    public static let maximumDescriptionLength = 1024

    /// Why a name is none kwwk takes, the first rule it breaks.
    public enum NameProblem: Sendable, Equatable {
        /// Not 1 to 64 characters.
        case length
        /// Something other than lowercase letters, digits and hyphens.
        case characters
        /// A hyphen at either end, or two in a row.
        case hyphens
    }

    /// The frontmatter's pairs, the last of a key winning, as kwwk keeps them.
    public let fields: [String: String]
    /// The Markdown after the frontmatter, trimmed; the whole text when
    /// there is none.
    public let body: String

    public init(_ text: String) {
        (fields, body) = Self.parse(text)
    }

    /// The skill's name in a folder named `folder`: the frontmatter's when
    /// it gives one, else the folder's.
    public func name(inFolderNamed folder: String) -> String {
        fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folder
    }

    /// The description a chat is offered; nil when kwwk finds none, which
    /// leaves the skill out.
    public var description: String? {
        guard let value = fields["description"], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// The description is a YAML block's marker (`>`, `|-`, `>+2`), whose
    /// lines kwwk never reads: the skill is offered with that character as
    /// its description.
    public var describesInBlock: Bool {
        guard let value = description, let first = value.first, first == ">" || first == "|" else { return false }
        return value.dropFirst().allSatisfy { "+-0123456789".contains($0) }
    }

    /// `disable-model-invocation: true`: the skill is only for typing as a
    /// command, and Apelin's catalogue leaves it out without a word.
    public var disablesModelInvocation: Bool {
        fields["disable-model-invocation"]?.lowercased() == "true"
    }

    /// Why `name` is no skill name kwwk takes, or nil. kwwk also asks a
    /// `SKILL.md`'s name to be its folder's, which the writers here see to
    /// by naming the folder for it.
    public static func nameProblem(_ name: String) -> NameProblem? {
        if name.isEmpty || name.count > maximumNameLength {
            return .length
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        if name.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return .characters
        }
        if name.hasPrefix("-") || name.hasSuffix("-") || name.contains("--") {
            return .hyphens
        }
        return nil
    }

    /// kwwk's `parseFrontmatter`, line for line, but for one case it traps
    /// on: a closing fence right after the opening one (`---\n---`), read
    /// here as no frontmatter, so no description.
    static func parse(_ content: String) -> (fields: [String: String], body: String) {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---"),
              let end = normalized.range(
                  of: "\n---",
                  range: normalized.index(normalized.startIndex, offsetBy: 3) ..< normalized.endIndex,
              )
        else {
            return ([:], normalized)
        }
        let start = normalized.index(normalized.startIndex, offsetBy: 4)
        guard start <= end.lowerBound else { return ([:], normalized) }
        var bodyStart = end.upperBound
        if let newline = normalized[bodyStart...].firstIndex(of: "\n") {
            bodyStart = normalized.index(after: newline)
        } else {
            bodyStart = normalized.endIndex
        }
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [:]
        for raw in normalized[start ..< end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty {
                continue
            }
            fields[key] = unquote(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        return (fields, body)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
