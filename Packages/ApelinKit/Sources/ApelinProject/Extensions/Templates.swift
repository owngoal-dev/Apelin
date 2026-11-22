import Foundation

/// A template parameter's type, as the placeholder rules see it.
public struct ParameterType: Sendable, Equatable {
    public var type: String
    public var values: [String]?
    public var maxLength: Int?
    public var defaultValue: JSONDocument?

    public init(type: String, values: [String]? = nil, maxLength: Int? = nil, defaultValue: JSONDocument? = nil) {
        self.type = type
        self.values = values
        self.maxLength = maxLength
        self.defaultValue = defaultValue
    }
}

public struct TemplateError: Error, CustomStringConvertible, Equatable, Sendable {
    public var description: String
    public init(_ description: String) {
        self.description = description
    }
}

/// Placeholders, their types and where each may appear, typed values and
/// how each file format escapes them (Documents/Schemas/README.md ▸
/// Placeholders). Ported from the reference implementation: the same
/// tables, the same checks, the same escaping, the same messages.
public enum TemplateParameters {
    /// Built-in parameters the IDE always supplies; not redeclarable.
    public static let builtin: [String: String] = [
        "projectName": "projectName",
        "projectID": "uuid",
        "bundleID": "bundleID",
        "packageID": "packageID",
        "deploymentTarget": "deploymentTarget",
        "architectures": "architectureMap",
        "templateExtensionID": "packageID",
        "templateID": "identifierDashed",
        "templateVersion": "version",
        "templateDigest": "digest",
        "toolchainID": "registrationID",
        "toolchainDigest": "digest",
        "sdkID": "registrationID",
        "sdkDigest": "digest",
    ]

    static let typePatterns: [String: String] = [
        "projectName": #"^[^/\x00-\x1f\x7f.][^/\x00-\x1f\x7f]{0,63}$"#,
        "identifier": #"^[A-Za-z_][A-Za-z0-9_]{0,63}$"#,
        "identifierDashed": #"^[a-z][a-z0-9-]{0,63}$"#,
        "bundleID": #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#,
        "packageID": #"^[a-z0-9][a-z0-9+.-]+$"#,
        "version": #"^[0-9][0-9A-Za-z.+~-]{0,63}$"#,
        "deploymentTarget": #"^(1[5-9]|[2-9][0-9])\.[0-9]{1,2}(\.[0-9]{1,2})?$"#,
        "uuid": #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
        "digest": #"^sha256:[0-9a-f]{64}$"#,
        "registrationID": #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$"#,
        "string": #"^[^\x00-\x08\x0b\x0c\x0e-\x1f\x7f]*$"#,
    ]

    static let listItemPatterns: [String: String] = [
        "bundleIDList": typePatterns["bundleID"]!,
        "executableList": #"^[A-Za-z0-9_][A-Za-z0-9_.+ -]{0,63}$"#,
    ]

    static let safeTypes: Set<String> = [
        "identifier", "identifierDashed", "bundleID", "packageID", "version", "deploymentTarget", "uuid", "digest",
        "registrationID", "enum",
    ]
    static let pathTypes: Set<String> = ["identifier", "identifierDashed", "bundleID", "packageID", "version"]
    static let textTypes: Set<String> = ["projectName", "string"]
    static let structuredTypes: Set<String> = ["bundleIDList", "executableList", "architectureMap", "bool"]

    static let token = try! NSRegularExpression(pattern: #"\{\{([a-z][A-Za-z0-9]*)\}\}"#)

    /// Every parameter a template's files may name: the built-ins, then its own.
    public static func types(for template: ExtensionManifest.Template) -> [String: ParameterType] {
        var types = builtin.mapValues { ParameterType(type: $0) }
        for parameter in template.parameters {
            types[parameter.name] = ParameterType(
                type: parameter.type,
                values: parameter.values,
                maxLength: parameter.maxLength,
                defaultValue: parameter.default?.value,
            )
        }
        return types
    }

    struct Token {
        var name: String
        var range: Range<String.Index>
    }

    static func tokens(in text: String) -> [Token] {
        token.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let whole = Range(match.range, in: text),
                  let name = Range(match.range(at: 1), in: text) else { return nil }
            return Token(name: String(text[name]), range: whole)
        }
    }

    static func matches(_ pattern: String, _ text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Whether an odd number of unescaped quotes precede the token on its line.
    static func insideString(_ linePrefix: Substring) -> Bool {
        var count = 0
        var escaped = false
        for character in linePrefix.unicodeScalars {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                count += 1
            }
        }
        return count % 2 == 1
    }

    /// True when the token sits in character data, not inside a tag.
    static func plistTextContext(_ text: String, _ start: String.Index) -> Bool {
        let before = text[..<start]
        let open = before.lastIndex(of: "<")
        let close = before.lastIndex(of: ">")
        switch (open, close) {
        case (nil, _): return true
        case (_?, nil): return false
        case let (o?, c?): return o <= c
        }
    }

    public static func checkText(
        _ text: String,
        format: String,
        types: [String: ParameterType],
        where location: String,
    ) -> [String] {
        var errors: [String] = []
        guard format != "copy" else { return errors }
        for match in tokens(in: text) {
            let name = match.name
            guard let kind = types[name]?.type else {
                errors.append("\(location): {{\(name)}} names no parameter")
                continue
            }
            let lineStart = text[..<match.range.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) } ?? text.startIndex
            let inString = insideString(text[lineStart ..< match.range.lowerBound])
            switch format {
            case "c", "objc", "swift":
                if textTypes.contains(kind), !inString {
                    errors.append("\(location): {{\(name)}} (\(kind)) may only appear inside a string literal")
                } else if structuredTypes.subtracting(["bool"]).contains(kind) {
                    errors.append("\(location): {{\(name)}} (\(kind)) cannot appear in source code")
                }
            case "json":
                if structuredTypes.contains(kind), inString {
                    errors.append("\(location): {{\(name)}} (\(kind)) is a JSON value and must not be quoted")
                } else if !structuredTypes.contains(kind), !inString {
                    errors.append("\(location): {{\(name)}} (\(kind)) must appear inside a JSON string")
                }
            case "plist-xml":
                if !plistTextContext(text, match.range.lowerBound) {
                    errors.append("\(location): {{\(name)}} may only appear in plist character data")
                }
                if kind == "architectureMap" {
                    errors.append("\(location): {{\(name)}} (\(kind)) cannot appear in a plist")
                }
            case "shell":
                if !safeTypes.contains(kind) {
                    errors.append("\(location): {{\(name)}} (\(kind)) cannot appear in a shell script")
                }
            case "deb-control":
                if structuredTypes.subtracting(["bool"]).contains(kind) {
                    errors.append("\(location): {{\(name)}} (\(kind)) cannot appear in a control file")
                }
            case "text":
                if structuredTypes.subtracting(["bool"]).contains(kind) {
                    errors.append("\(location): {{\(name)}} (\(kind)) cannot appear in text")
                }
            default:
                break
            }
        }
        return errors
    }

    public static func checkPath(_ path: String, types: [String: ParameterType], where location: String) -> [String] {
        tokens(in: path).compactMap { match in
            guard let kind = types[match.name]?.type else { return "\(location): {{\(match.name)}} names no parameter" }
            return pathTypes.contains(kind)
                ? nil
                : "\(location): {{\(match.name)}} (\(kind)) cannot appear in a file name"
        }
    }

    public static func validate(_ name: String, _ parameter: ParameterType, _ value: JSONDocument) throws {
        let kind = parameter.type
        if kind == "bool" {
            guard case .bool = value else { throw TemplateError("\(name): expected true or false") }
            return
        }
        if kind == "architectureMap" {
            guard case let .object(map) = value, !map.isEmpty,
                  map.keys.allSatisfy({ $0 == "rootless" || $0 == "roothide" })
            else {
                throw TemplateError("\(name): expected an object keyed by rootless and/or roothide")
            }
            for (_, archs) in map.entries {
                guard case let .array(list) = archs, !list.isEmpty, Set(list).count == list.count,
                      list.allSatisfy({ $0 == .string("arm64") || $0 == .string("arm64e") })
                else { throw TemplateError("\(name): architectures are arm64 and arm64e, each at most once") }
            }
            return
        }
        if let itemPattern = listItemPatterns[kind] {
            guard case let .array(items) = value, !items.isEmpty, items.count <= 32 else {
                throw TemplateError("\(name): expected a list of 1 to 32 items")
            }
            for item in items {
                guard case let .string(text) = item, matches(itemPattern, text) else {
                    throw TemplateError("\(name): \(item) is not valid")
                }
            }
            return
        }
        guard case let .string(text) = value else { throw TemplateError("\(name): expected a string") }
        if kind == "enum" {
            guard (parameter.values ?? []).contains(text) else {
                throw TemplateError("\(name): \(CanonicalJSON.quote(text)) is not one of \(parameter.values ?? [])")
            }
            return
        }
        guard let pattern = typePatterns[kind], matches(pattern, text) else {
            throw TemplateError("\(name): \(CanonicalJSON.quote(text)) is not a valid \(kind)")
        }
        let limit = parameter.maxLength ?? 200
        if text.unicodeScalars.count > limit {
            throw TemplateError("\(name): longer than \(limit)")
        }
        if kind == "projectName", text == "." || text == ".." {
            throw TemplateError("\(name): not a usable folder name")
        }
    }

    static func escape(_ value: JSONDocument, kind: String, format: String) throws -> String {
        if kind == "bool" {
            let flag = value.boolValue ?? false
            switch format {
            case "c", "objc": return flag ? "1" : "0"
            case "plist-xml": return flag ? "<true/>" : "<false/>"
            default: return flag ? "true" : "false"
            }
        }
        if kind == "architectureMap" {
            let map = value.objectValue ?? JSONObject()
            let ordered = JSONObject(["rootless", "roothide"].compactMap { key in map[key].map { (key, $0) } })
            return JSONWriter.python(.object(ordered))
        }
        if listItemPatterns[kind] != nil {
            if format == "json" {
                return JSONWriter.python(value)
            }
            if format == "plist-xml" {
                return (value.arrayValue ?? []).map { "<string>\(xml($0.stringValue ?? ""))</string>" }.joined()
            }
            throw TemplateError("\(kind) cannot be written in \(format)")
        }
        let text = value.stringValue ?? ""
        switch format {
        case "c", "objc", "swift":
            var out = ""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\\": out += "\\\\"
                case "\"": out += "\\\""
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default: out.unicodeScalars.append(scalar)
                }
            }
            return out
        case "json":
            return String(CanonicalJSON.quote(text).dropFirst().dropLast())
        case "plist-xml":
            return xml(text)
        case "deb-control", "text":
            if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
                throw TemplateError("a control-file or text value must be a single line")
            }
            return text
        case "shell":
            guard matches(#"^[A-Za-z0-9._+:-]+$"#, text), !text.contains("\n") else {
                throw TemplateError("\(CanonicalJSON.quote(text)) is not shell-safe")
            }
            return text
        default:
            throw TemplateError("no substitution in \(format)")
        }
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    public static func substitute(
        _ text: String,
        format: String,
        types: [String: ParameterType],
        values: [String: JSONDocument],
    ) throws -> String {
        var out = ""
        var cursor = text.startIndex
        for match in tokens(in: text) {
            out += text[cursor ..< match.range.lowerBound]
            guard let value = values[match.name], let kind = types[match.name]?.type else {
                throw TemplateError("{{\(match.name)}}: no value")
            }
            out += try escape(value, kind: kind, format: format)
            cursor = match.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// A path's tokens replaced by their raw values (path types only).
    static func substitutePath(_ path: String, values: [String: JSONDocument]) throws -> String {
        var out = ""
        var cursor = path.startIndex
        for match in tokens(in: path) {
            out += path[cursor ..< match.range.lowerBound]
            guard let value = values[match.name]?.stringValue else {
                throw TemplateError("{{\(match.name)}}: no value")
            }
            out += value
            cursor = match.range.upperBound
        }
        out += path[cursor...]
        return out
    }
}

/// The template digest (README ▸ Template digest): SHA-256 over JCS of the
/// file list, taken over the files before substitution.
public enum TemplateDigest {
    public static func compute(templateRoot: URL, files: [ExtensionManifest.TemplateFile]) throws -> String {
        let sorted = files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var entries: [JSONDocument] = []
        for file in sorted {
            let data = try ProjectFiles.read(file.path, in: templateRoot)
            var item = JSONObject([
                ("path", .string(file.path)),
                ("format", .string(file.format)),
                ("sha256", .string(CanonicalJSON.sha256Hex(data))),
            ])
            if let mode = file.mode {
                item["mode"] = .string(mode)
            }
            entries.append(.object(item))
        }
        return CanonicalJSON.digest(.object(JSONObject([
            ("description", .string("apelin.template")),
            ("version", .integer(1)),
            ("files", .array(entries)),
        ])))
    }
}
