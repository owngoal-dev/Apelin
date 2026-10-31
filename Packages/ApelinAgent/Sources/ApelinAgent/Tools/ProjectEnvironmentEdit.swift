import enum ApelinProject.ProjectManifestFormat
import Foundation

/// Rewrites the binding in `apelin-project.json` in place: the four strings
/// `environment.toolchain.id`, `.digest`, `environment.sdk.id` and `.digest`
/// are replaced, and every other byte stays as the user or the template
/// wrote it. The result is read back and must differ from the original in
/// those four values alone, or nothing is written. What is written is that
/// result in the manifest's written form (`ProjectManifestFormat`), which
/// reads back as the same document; one that does not read strictly is
/// written as the edit left it.
enum ProjectEnvironmentEdit {
    static let fileName = "apelin-project.json"

    struct Result: Equatable {
        var data: Data
        /// `toolchain`, `sdk`: what the binding changed.
        var changed: [String]
    }

    static func rebind(_ data: Data, toolchain: ComponentBinding, sdk: ComponentBinding) throws -> Result {
        let wanted: [(path: String, value: String)] = [
            ("environment.toolchain.id", toolchain.id),
            ("environment.toolchain.digest", toolchain.digest),
            ("environment.sdk.id", sdk.id),
            ("environment.sdk.digest", sdk.digest),
        ]
        var scanner = Scanner(bytes: [UInt8](data), targets: Set(wanted.map(\.path)))
        try scanner.document()
        var bytes = [UInt8](data)
        var changed: Set<String> = []
        // From the end, so the earlier spans keep their offsets.
        let edits = try wanted.map { path, value -> (Range<Int>, [UInt8], String) in
            guard let found = scanner.strings[path] else {
                throw ToolArgumentError("\(fileName) has no string \(path); fix its environment with file_edit first")
            }
            if found.value != value {
                changed.insert(String(path.split(separator: ".")[1]))
            }
            return try (found.span, encoded(value), found.value)
        }.sorted { $0.0.lowerBound > $1.0.lowerBound }
        for (span, replacement, _) in edits {
            bytes.replaceSubrange(span, with: replacement)
        }
        let result = Data(bytes)
        try verify(original: data, result: result, wanted: wanted)
        return Result(
            data: ProjectManifestFormat.formatted(result) ?? result,
            changed: ["toolchain", "sdk"].filter(changed.contains),
        )
    }

    private static func encoded(_ value: String) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try [UInt8](encoder.encode(value))
    }

    /// The result parses, holds the wanted values, and is the original in
    /// everything else.
    private static func verify(original: Data, result: Data, wanted: [(path: String, value: String)]) throws {
        guard var before = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              var after = try JSONSerialization.jsonObject(with: result) as? [String: Any],
              let environment = after["environment"] as? [String: Any]
        else { throw ToolArgumentError("\(fileName) did not read back as a JSON object") }
        for (path, value) in wanted {
            let parts = path.split(separator: ".").map(String.init)
            let member = environment[parts[1]] as? [String: Any]
            guard member?[parts[2]] as? String == value else {
                throw ToolArgumentError("\(fileName) did not read back with \(path) set")
            }
        }
        guard var beforeEnvironment = before["environment"] as? [String: Any],
              var afterEnvironment = after["environment"] as? [String: Any]
        else { throw ToolArgumentError("\(fileName) has no environment") }
        for key in ["toolchain", "sdk"] {
            var beforeMember = beforeEnvironment[key] as? [String: Any] ?? [:]
            var afterMember = afterEnvironment[key] as? [String: Any] ?? [:]
            for field in ["id", "digest"] {
                beforeMember[field] = nil
                afterMember[field] = nil
            }
            beforeEnvironment[key] = beforeMember
            afterEnvironment[key] = afterMember
        }
        before["environment"] = beforeEnvironment
        after["environment"] = afterEnvironment
        guard NSDictionary(dictionary: before).isEqual(to: after) else {
            throw ToolArgumentError("rewriting \(fileName) would have changed more than its environment")
        }
    }

    /// A JSON reader that keeps where the strings at `targets` are, as byte
    /// ranges of their tokens. A target path that occurs twice is refused.
    private struct Scanner {
        let bytes: [UInt8]
        let targets: Set<String>
        var index = 0
        var strings: [String: (span: Range<Int>, value: String)] = [:]

        init(bytes: [UInt8], targets: Set<String>) {
            self.bytes = bytes
            self.targets = targets
        }

        mutating func document() throws {
            try value(path: "")
            skipWhitespace()
            guard index == bytes.count else { throw failure("text after the document") }
        }

        private func failure(_ what: String) -> ToolArgumentError {
            ToolArgumentError("\(ProjectEnvironmentEdit.fileName) is not valid JSON (\(what) at byte \(index))")
        }

        private mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        private mutating func value(path: String) throws {
            skipWhitespace()
            guard index < bytes.count else { throw failure("an unfinished value") }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                try object(path: path)
            case UInt8(ascii: "["):
                try array(path: path)
            case UInt8(ascii: "\""):
                let start = index
                let text = try string()
                if targets.contains(path) {
                    guard strings[path] == nil else { throw failure("\(path) twice") }
                    strings[path] = (start ..< index, text)
                }
            default:
                try scalar()
            }
        }

        private mutating func object(path: String) throws {
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("a member name") }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("a colon") }
                index += 1
                try value(path: path.isEmpty ? key : path + "." + key)
                skipWhitespace()
                guard index < bytes.count else { throw failure("an unfinished object") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "}") else { throw failure("a comma or brace") }
                index += 1
                return
            }
        }

        private mutating func array(path: String) throws {
            index += 1
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return
            }
            while true {
                try value(path: path + "[]")
                skipWhitespace()
                guard index < bytes.count else { throw failure("an unfinished array") }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                guard bytes[index] == UInt8(ascii: "]") else { throw failure("a comma or bracket") }
                index += 1
                return
            }
        }

        /// The string token at `index`, decoded; `index` ends past it.
        private mutating func string() throws -> String {
            let start = index
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw failure("an unfinished string") }
            index += 1
            let token = Data(bytes[start ..< index])
            guard let text = try? JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String else {
                throw failure("a bad string")
            }
            return text
        }

        private mutating func scalar() throws {
            let start = index
            while index < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
            guard index > start else { throw failure("a value") }
        }
    }
}
