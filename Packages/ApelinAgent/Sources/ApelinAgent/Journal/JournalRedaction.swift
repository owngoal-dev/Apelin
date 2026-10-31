import struct ApelinCore.LogRedaction
import Foundation
import KWWKAgent
import KWWKAI

/// What a diagnostic journal keeps of a call: its arguments and result
/// summarised and every text redacted (`LogRedaction`), each cut to a bound
/// that says how long it was. A journal is shared to report a problem, so
/// nothing reaches the file without this; nothing is cut silently.
struct JournalRedaction: Sendable {
    private let redaction: LogRedaction

    static let argumentBytes = 1024
    static let resultBytes = 1024
    static let errorBytes = 4096
    /// One string argument inside a summary: a file's whole contents is
    /// the shape of the call, not its point.
    static let fieldBytes = 256

    /// `home` is mobile's home; `installRoot` the install root the host
    /// derived.
    init(home: String?, installRoot: String?) {
        redaction = LogRedaction(home: home, installRoot: installRoot)
    }

    /// `text` redacted and cut to `limit` bytes of UTF-8.
    func text(_ text: String, limit: Int) -> String {
        redaction.text(text, limit: limit)
    }

    /// `text` with credentials, e-mail addresses and this device's paths
    /// replaced.
    func redacted(_ text: String) -> String {
        redaction.redacted(text)
    }

    static func truncated(_ text: String, limit: Int) -> String {
        LogRedaction.truncated(text, limit: limit)
    }

    static func grouped(_ number: Int) -> String {
        LogRedaction.grouped(number)
    }

    /// A call's arguments as the journal keeps them: the git credential's
    /// token masked as every event masks it (`ToolArgumentRedaction`), any
    /// field named like a secret replaced, each string cut to
    /// `fieldBytes`, the whole redacted and cut to `argumentBytes`.
    func arguments(_ arguments: JSONValue, tool: String) -> String {
        let masked = ToolArgumentRedaction.redacted(arguments.canonicalJSON, tool: tool)
        let value = (try? JSONDecoder().decode(JSONValue.self, from: Data(masked.utf8))) ?? arguments
        return text(summarized(value).canonicalJSON, limit: Self.argumentBytes)
    }

    /// A call's result: its text, images named, redacted and cut to
    /// `resultBytes`.
    func result(_ result: AgentToolResult) -> String {
        let parts = result.content.map { block -> String in
            switch block {
            case let .text(text): text.text
            case let .image(image): "[image \(image.mimeType)]"
            }
        }
        return text(parts.joined(separator: "\n"), limit: Self.resultBytes)
    }

    private func summarized(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(fields):
            var kept: [String: JSONValue] = [:]
            for (key, field) in fields {
                kept[key] = Self.isSecretName(key) && field != .null ? .string(LogRedaction.redacted) : summarized(field)
            }
            return .object(kept)
        case let .array(values):
            return .array(values.map(summarized))
        case let .string(string):
            return .string(Self.truncated(string, limit: Self.fieldBytes))
        default:
            return value
        }
    }

    /// A field whose value is a credential by its name: `token`,
    /// `apiKey`, `password`, `Authorization`, an OAuth `access` or
    /// `refresh`, and the like.
    static func isSecretName(_ name: String) -> Bool {
        let folded = name.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["access", "refresh", "key", "auth"].contains(folded) {
            return true
        }
        // `max_tokens` counts them
        if folded.contains("token"), !folded.contains("tokens") {
            return true
        }
        return ["password", "passwd", "secret", "apikey", "authorization", "credential", "cookie", "privatekey"]
            .contains { folded.contains($0) }
    }
}
