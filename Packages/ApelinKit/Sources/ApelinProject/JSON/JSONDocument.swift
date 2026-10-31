import Foundation

/// A JSON value exactly as an Apelin document may hold it
/// (Documents/Schemas/README.md ▸ Common rules): integers only, within
/// ±(2^53−1), and object members kept in the order they were written with
/// their names compared as Unicode scalars — `JSONValue` keeps numbers as
/// doubles and Swift's `String ==` folds canonically equivalent spellings,
/// and either would make two different documents the same one.
public indirect enum JSONDocument: Sendable, Hashable, CustomStringConvertible {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([JSONDocument])
    case object(JSONObject)

    public static let maximumInteger: Int64 = 9_007_199_254_740_991

    public subscript(key: String) -> JSONDocument? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self {
            return value
        }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self {
            return value
        }
        return nil
    }

    public var integerValue: Int64? {
        if case let .integer(value) = self {
            return value
        }
        return nil
    }

    public var arrayValue: [JSONDocument]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    public var objectValue: JSONObject? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    /// Compact JSON, member order as stored. Not the canonical form:
    /// `CanonicalJSON` is what digests are taken over.
    public var description: String {
        String(decoding: JSONWriter.compact(self), as: UTF8.self)
    }

    /// Equality as the reference implementation's `_json_equal`: a boolean
    /// never equals a number, objects compare by members regardless of order.
    public static func == (lhs: JSONDocument, rhs: JSONDocument) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.integer(a), .integer(b)): a == b
        case let (.string(a), .string(b)): a.unicodeScalars.elementsEqual(b.unicodeScalars)
        case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        case let (.object(a), .object(b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case let .bool(value): hasher.combine(value)
        case let .integer(value): hasher.combine(value)
        case let .string(value): hasher.combine(Array(value.unicodeScalars.map(\.value)))
        case let .array(value): hasher.combine(value)
        case let .object(value): hasher.combine(value.count)
        }
    }
}

/// An object's members in written order. Names are compared scalar by
/// scalar; the parser refuses a duplicate.
public struct JSONObject: Sendable, Hashable {
    public private(set) var entries: [(key: String, value: JSONDocument)]

    public init(_ entries: [(key: String, value: JSONDocument)] = []) {
        self.entries = entries
    }

    public var count: Int {
        entries.count
    }

    public var keys: [String] {
        entries.map(\.key)
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }

    public subscript(key: String) -> JSONDocument? {
        get { entries.first { Self.same($0.key, key) }?.value }
        set {
            if let index = entries.firstIndex(where: { Self.same($0.key, key) }) {
                if let newValue {
                    entries[index].value = newValue
                } else {
                    entries.remove(at: index)
                }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }

    public func contains(_ key: String) -> Bool {
        entries.contains { Self.same($0.key, key) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.entries.allSatisfy { entry in rhs[entry.key].map { $0 == entry.value } ?? false }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(count)
    }
}

/// Why a document did not parse. The message names the rule broken.
public struct JSONDocumentError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// The strict reader every Apelin document goes through before any schema:
/// UTF-8 without a byte order mark, no duplicate member names, no
/// non-integer number (`1.0`, `1e3`, `NaN` all refused), integers within
/// ±(2^53−1), no raw control character in a string, no lone surrogate.
public enum StrictJSON {
    public static func parse(_ data: Data) throws -> JSONDocument {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw JSONDocumentError("a byte order mark is not allowed")
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw JSONDocumentError("not UTF-8")
        }
        var parser = Parser(bytes: bytes)
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.at == bytes.count else {
            throw JSONDocumentError("extra data after the document at byte \(parser.at)")
        }
        return value
    }

    public static func parse(contentsOf url: URL) throws -> JSONDocument {
        try parse(Data(contentsOf: url))
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) {
                at += 1
            }
        }

        func fail(_ what: String) -> JSONDocumentError {
            JSONDocumentError("\(what) at byte \(at)")
        }

        mutating func value(depth: Int) throws -> JSONDocument {
            guard depth < 256 else { throw fail("nested too deeply") }
            guard at < bytes.count else { throw fail("unexpected end") }
            switch bytes[at] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return try .string(string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"): return try number()
            default: throw fail("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            guard bytes[at...].starts(with: word.utf8) else { throw fail("unexpected character") }
            at += word.utf8.count
        }

        mutating func number() throws -> JSONDocument {
            let start = at
            if bytes[at] == UInt8(ascii: "-") {
                at += 1
            }
            guard at < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[at]) else {
                throw fail("bad number")
            }
            if bytes[at] == UInt8(ascii: "0") {
                at += 1
            } else {
                while at < bytes.count, (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(bytes[at]) {
                    at += 1
                }
            }
            if at < bytes.count, [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E")].contains(bytes[at]) {
                throw JSONDocumentError("non-integer number \(String(decoding: bytes[start ..< min(at + 1, bytes.count)], as: UTF8.self))… is not allowed")
            }
            let text = String(decoding: bytes[start ..< at], as: UTF8.self)
            guard let value = Int64(text), abs(value) <= JSONDocument.maximumInteger else {
                throw JSONDocumentError("integer \(text) is outside ±(2^53-1)")
            }
            return .integer(value)
        }

        mutating func string() throws -> String {
            at += 1
            var scalars = String.UnicodeScalarView()
            var raw: [UInt8] = []
            func flush() throws {
                guard !raw.isEmpty else { return }
                guard let text = String(bytes: raw, encoding: .utf8) else { throw fail("not UTF-8") }
                scalars.append(contentsOf: text.unicodeScalars)
                raw.removeAll(keepingCapacity: true)
            }
            while true {
                guard at < bytes.count else { throw fail("unterminated string") }
                let byte = bytes[at]
                if byte == UInt8(ascii: "\"") {
                    at += 1
                    try flush()
                    return String(scalars)
                }
                if byte < 0x20 {
                    throw fail("control character in a string")
                }
                if byte != UInt8(ascii: "\\") {
                    raw.append(byte)
                    at += 1
                    continue
                }
                try flush()
                at += 1
                guard at < bytes.count else { throw fail("unterminated string") }
                let escape = bytes[at]
                at += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{8}")
                case UInt8(ascii: "f"): scalars.append("\u{C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let first = try hex4()
                    if (0xD800 ... 0xDBFF).contains(first) {
                        guard bytes[at...].starts(with: [UInt8(ascii: "\\"), UInt8(ascii: "u")]) else {
                            throw fail("lone surrogate")
                        }
                        at += 2
                        let second = try hex4()
                        guard (0xDC00 ... 0xDFFF).contains(second) else { throw fail("lone surrogate") }
                        let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                        scalars.append(Unicode.Scalar(combined)!)
                    } else if (0xDC00 ... 0xDFFF).contains(first) {
                        throw fail("lone surrogate")
                    } else {
                        scalars.append(Unicode.Scalar(first)!)
                    }
                default:
                    throw fail("bad escape")
                }
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard at + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[at ..< at + 4], as: UTF8.self), radix: 16)
            else {
                throw fail("bad \\u escape")
            }
            at += 4
            return value
        }

        mutating func array(depth: Int) throws -> JSONDocument {
            at += 1
            var items: [JSONDocument] = []
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "]") {
                at += 1
                return .array(items)
            }
            while true {
                skipSpace()
                try items.append(value(depth: depth + 1))
                skipSpace()
                guard at < bytes.count else { throw fail("unterminated array") }
                if bytes[at] == UInt8(ascii: ",") {
                    at += 1; continue
                }
                if bytes[at] == UInt8(ascii: "]") {
                    at += 1; return .array(items)
                }
                throw fail("expected , or ]")
            }
        }

        mutating func object(depth: Int) throws -> JSONDocument {
            at += 1
            var object = JSONObject()
            skipSpace()
            if at < bytes.count, bytes[at] == UInt8(ascii: "}") {
                at += 1
                return .object(object)
            }
            while true {
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw fail("expected a member name") }
                let key = try string()
                if object.contains(key) {
                    throw JSONDocumentError("duplicate member \(CanonicalJSON.quote(key))")
                }
                skipSpace()
                guard at < bytes.count, bytes[at] == UInt8(ascii: ":") else { throw fail("expected :") }
                at += 1
                skipSpace()
                object[key] = try value(depth: depth + 1)
                skipSpace()
                guard at < bytes.count else { throw fail("unterminated object") }
                if bytes[at] == UInt8(ascii: ",") {
                    at += 1; continue
                }
                if bytes[at] == UInt8(ascii: "}") {
                    at += 1; return .object(object)
                }
                throw fail("expected , or }")
            }
        }
    }
}

/// Writes documents back as JSON text.
enum JSONWriter {
    static func compact(_ value: JSONDocument) -> Data {
        var out = ""
        write(value, into: &out, separators: (",", ":"))
        return Data(out.utf8)
    }

    /// As Python's `json.dumps(value, ensure_ascii=False, separators=(", ", ": "))`,
    /// which the template substitution writes structured values with.
    static func python(_ value: JSONDocument) -> String {
        var out = ""
        write(value, into: &out, separators: (", ", ": "))
        return out
    }

    /// Two spaces a level, one member or element a line, `": "` after a
    /// name, an empty object or array as `{}` or `[]`, members in stored
    /// order: Python's `json.dumps(value, ensure_ascii=False, indent=2)`,
    /// the manifest's written form (`ProjectManifestFormat`).
    static func indented(_ value: JSONDocument) -> String {
        var out = ""
        writeIndented(value, level: 0, into: &out)
        return out
    }

    private static func writeIndented(_ value: JSONDocument, level: Int, into out: inout String) {
        let inner = String(repeating: "  ", count: level + 1)
        switch value {
        case let .array(items) where !items.isEmpty:
            out += "["
            for (index, item) in items.enumerated() {
                out += index > 0 ? ",\n" : "\n"
                out += inner
                writeIndented(item, level: level + 1, into: &out)
            }
            out += "\n" + String(repeating: "  ", count: level) + "]"
        case let .object(object) where !object.isEmpty:
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                out += index > 0 ? ",\n" : "\n"
                out += inner
                out += CanonicalJSON.quote(entry.key) + ": "
                writeIndented(entry.value, level: level + 1, into: &out)
            }
            out += "\n" + String(repeating: "  ", count: level) + "}"
        default:
            write(value, into: &out, separators: (",", ":"))
        }
    }

    private static func write(_ value: JSONDocument, into out: inout String, separators: (item: String, key: String)) {
        switch value {
        case .null: out += "null"
        case let .bool(flag): out += flag ? "true" : "false"
        case let .integer(number): out += String(number)
        case let .string(text): out += CanonicalJSON.quote(text)
        case let .array(items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 {
                    out += separators.item
                }
                write(item, into: &out, separators: separators)
            }
            out += "]"
        case let .object(object):
            out += "{"
            for (index, entry) in object.entries.enumerated() {
                if index > 0 {
                    out += separators.item
                }
                out += CanonicalJSON.quote(entry.key) + separators.key
                write(entry.value, into: &out, separators: separators)
            }
            out += "}"
        }
    }
}
