import Foundation

/// JSON Schema draft 2020-12, the subset `apelin-project.schema.json` and
/// `extension-manifest.schema.json` use, ported from the reference
/// implementation's `Validator` with its error messages word for word (the
/// fixtures' `expectations.json` match on them). An unknown keyword is an
/// error, never silently passed.
public final class SchemaValidator: @unchecked Sendable {
    private let root: JSONDocument
    @objc private dynamic var patterns: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    private static let annotations: Set<String> = [
        "$schema", "$id", "title", "description", "default", "$comment", "examples", "then", "else", "$defs",
    ]

    public init(schema: JSONDocument) {
        root = schema
    }

    public func errors(_ instance: JSONDocument) -> [String] {
        var out: [String] = []
        check(instance, root, "", &out)
        return out
    }

    private func resolve(_ ref: String) -> JSONDocument {
        precondition(ref.hasPrefix("#/"), "only local references are supported: \(ref)")
        var node = root
        for part in ref.dropFirst(2).split(separator: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = node[key] else { preconditionFailure("unresolvable reference \(ref)") }
            node = next
        }
        return node
    }

    @objc private dynamic func at(_ where: String) -> String {
        `where`.isEmpty ? "/" : `where`
    }

    private func sub(_ value: JSONDocument, _ schema: JSONDocument, _ where: String) -> [String] {
        var out: [String] = []
        check(value, schema, `where`, &out)
        return out
    }

    private func check(_ value: JSONDocument, _ schema: JSONDocument, _ where: String, _ out: inout [String]) {
        if case let .bool(flag) = schema {
            if !flag {
                out.append("\(at(`where`)): not allowed")
            }
            return
        }
        guard case let .object(keywords) = schema else { return }
        for (keyword, argument) in keywords.entries where !Self.annotations.contains(keyword) {
            apply(keyword, argument, keywords, value, `where`, &out)
        }
    }

    private func apply(
        _ keyword: String,
        _ argument: JSONDocument,
        _ schema: JSONObject,
        _ value: JSONDocument,
        _ where: String,
        _ out: inout [String],
    ) {
        switch keyword {
        case "$ref":
            check(value, resolve(argument.stringValue ?? ""), `where`, &out)
        case "type":
            let names = argument.arrayValue?.compactMap(\.stringValue) ?? [argument.stringValue ?? ""]
            if !names.contains(where: { Self.typeMatches(value, $0) }) {
                out.append("\(at(`where`)): expected \(names.joined(separator: "/"))")
            }
        case "enum":
            let options = argument.arrayValue ?? []
            if !options.contains(where: { $0 == value }) {
                out.append("\(at(`where`)): \(JSONWriter.python(value)) is not one of \(JSONWriter.python(argument))")
            }
        case "const":
            if value != argument {
                out.append("\(at(`where`)): must be \(JSONWriter.python(argument))")
            }
        case "properties":
            guard case let .object(object) = value, case let .object(properties) = argument else { return }
            for (key, subschema) in properties.entries {
                if let member = object[key] {
                    check(member, subschema, "\(`where`)/\(key)", &out)
                }
            }
        case "patternProperties":
            guard case let .object(object) = value, case let .object(properties) = argument else { return }
            for (pattern, subschema) in properties.entries {
                for (key, member) in object.entries where search(pattern, key) {
                    check(member, subschema, "\(`where`)/\(key)", &out)
                }
            }
        case "additionalProperties":
            guard case let .object(object) = value else { return }
            let known = schema["properties"]?.objectValue?.keys ?? []
            let patternKeys = schema["patternProperties"]?.objectValue?.keys ?? []
            for (key, member) in object.entries {
                if known.contains(where: { JSONObject.same($0, key) })
                    || patternKeys.contains(where: { search($0, key) })
                {
                    continue
                }
                if argument == .bool(false) {
                    out.append("\(`where`)/\(key): unknown member")
                } else {
                    check(member, argument, "\(`where`)/\(key)", &out)
                }
            }
        case "propertyNames":
            guard case let .object(object) = value else { return }
            for key in object.keys where !sub(.string(key), argument, "\(`where`)/\(key)").isEmpty {
                out.append("\(`where`)/\(key): member name not allowed")
            }
        case "required":
            guard case let .object(object) = value else { return }
            for name in argument.arrayValue?.compactMap(\.stringValue) ?? [] where !object.contains(name) {
                out.append("\(at(`where`)): missing \(name)")
            }
        case "minProperties":
            if case let .object(object) = value, let n = argument.integerValue, object.count < n {
                out.append("\(at(`where`)): needs at least \(n) members")
            }
        case "maxProperties":
            if case let .object(object) = value, let n = argument.integerValue, object.count > n {
                out.append("\(at(`where`)): allows at most \(n) members")
            }
        case "items":
            guard case let .array(items) = value else { return }
            for (index, item) in items.enumerated() {
                check(item, argument, "\(`where`)/\(index)", &out)
            }
        case "minItems":
            if case let .array(items) = value, let n = argument.integerValue, items.count < n {
                out.append("\(at(`where`)): needs at least \(n) items")
            }
        case "maxItems":
            if case let .array(items) = value, let n = argument.integerValue, items.count > n {
                out.append("\(at(`where`)): allows at most \(n) items")
            }
        case "uniqueItems":
            guard argument == .bool(true), case let .array(items) = value else { return }
            for i in items.indices {
                for j in 0 ..< i where items[i] == items[j] {
                    out.append("\(`where`)/\(i): duplicate item")
                }
            }
        case "contains":
            guard case let .array(items) = value else { return }
            if !items.contains(where: { sub($0, argument, `where`).isEmpty }) {
                out.append("\(at(`where`)): no item matches the required shape")
            }
        case "minLength":
            if case let .string(text) = value, let n = argument.integerValue, text.unicodeScalars.count < n {
                out.append("\(at(`where`)): shorter than \(n)")
            }
        case "maxLength":
            if case let .string(text) = value, let n = argument.integerValue, text.unicodeScalars.count > n {
                out.append("\(at(`where`)): longer than \(n)")
            }
        case "pattern":
            if case let .string(text) = value, let pattern = argument.stringValue, !search(pattern, text) {
                out.append("\(at(`where`)): \(JSONWriter.python(value)) does not match \(pattern)")
            }
        case "minimum":
            if case let .integer(number) = value, let n = argument.integerValue, number < n {
                out.append("\(at(`where`)): below \(n)")
            }
        case "maximum":
            if case let .integer(number) = value, let n = argument.integerValue, number > n {
                out.append("\(at(`where`)): above \(n)")
            }
        case "allOf":
            for subschema in argument.arrayValue ?? [] {
                check(value, subschema, `where`, &out)
            }
        case "anyOf":
            let results = (argument.arrayValue ?? []).map { sub(value, $0, `where`) }
            if results.allSatisfy({ !$0.isEmpty }) {
                out.append("\(at(`where`)): matches none of the allowed shapes (\(Self.shortest(results)))")
            }
        case "oneOf":
            let results = (argument.arrayValue ?? []).map { sub(value, $0, `where`) }
            let passing = results.filter(\.isEmpty).count
            if passing == 0 {
                out.append("\(at(`where`)): matches none of the allowed shapes (\(Self.shortest(results)))")
            } else if passing > 1 {
                out.append("\(at(`where`)): matches more than one shape")
            }
        case "not":
            if sub(value, argument, `where`).isEmpty {
                out.append("\(at(`where`)): matches a forbidden shape")
            }
        case "if":
            if sub(value, argument, `where`).isEmpty {
                if let then = schema["then"] {
                    check(value, then, `where`, &out)
                }
            } else if let otherwise = schema["else"] {
                check(value, otherwise, `where`, &out)
            }
        default:
            preconditionFailure("unsupported keyword \(keyword) at \(at(`where`))")
        }
    }

    /// The first error of the shortest list, as `min(results, key=len)[0]`.
    @objc private static dynamic func shortest(_ results: [[String]]) -> String {
        var best: [String]?
        for result in results where best == nil || result.count < best!.count {
            best = result
        }
        return best?.first ?? ""
    }

    private static func typeMatches(_ value: JSONDocument, _ name: String) -> Bool {
        switch (name, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null):
            true
        case ("integer", .integer), ("number", .integer): true
        default: false
        }
    }

    /// `re.search`: unanchored unless the pattern anchors itself.
    @objc private dynamic func search(_ pattern: String, _ text: String) -> Bool {
        lock.lock()
        let expression: NSRegularExpression
        if let cached = patterns[pattern] {
            expression = cached
        } else {
            expression = try! NSRegularExpression(pattern: Self.endAnchored(pattern))
            patterns[pattern] = expression
        }
        lock.unlock()
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// ECMA-262's `$`, which matches only at the end of input, as
    /// `_pattern_matches` spells it: ICU's `$` also matches before a final
    /// line terminator, so "x\n" would pass `^[a-z]+$`. An anchor `$` (not
    /// escaped, not in a character class) becomes `\z`.
    @objc private static dynamic func endAnchored(_ pattern: String) -> String {
        var translated = ""
        var escaped = false
        var inClass = false
        for character in pattern {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "[" {
                inClass = true
            } else if character == "]" {
                inClass = false
            } else if character == "$", !inClass {
                translated += "\\z"
                continue
            }
            translated.append(character)
        }
        return translated
    }
}
