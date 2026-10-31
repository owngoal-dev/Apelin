import enum ApelinCore.PrivateShapes
import struct ApelinCore.LogRedaction
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI

/// What a diagnostic journal keeps of a call: its arguments summarised and
/// every text redacted (`LogRedaction`) before it is cut to a bound that
/// says how long it was; of a result, only its size when the tool returns
/// the user's own content, else a short redacted summary. A journal is
/// shared to report a problem, so nothing reaches the file without this,
/// and nothing is cut silently.
struct JournalRedaction: Sendable {
    private let redaction: LogRedaction

    static let argumentBytes = 1024
    static let resultBytes = 512
    static let errorBytes = 4096
    /// One string argument inside a summary: a file's whole contents is
    /// the shape of the call, not its point.
    static let fieldBytes = 256
    /// The elements of a list, or the fields of an object, a summary keeps.
    static let fieldCount = 64

    /// `home` is mobile's home; `installRoot` the install root the host
    /// derived; `names` what the device calls itself.
    init(home: String?, installRoot: String?, names: [String] = []) {
        redaction = LogRedaction(home: home, installRoot: installRoot, names: names)
    }

    /// `text` redacted, then cut to `limit` bytes of UTF-8.
    func text(_ text: String, limit: Int) -> String {
        redaction.text(text, limit: limit)
    }

    /// `text` with credentials, e-mail addresses, this device's paths and
    /// network names and device identifiers replaced.
    func redacted(_ text: String) -> String {
        redaction.redacted(text)
    }

    static func grouped(_ number: Int) -> String {
        LogRedaction.grouped(number)
    }

    // MARK: - Arguments

    /// A call's arguments as the journal keeps them: a field named like a
    /// secret replaced (the git credential's `token` among them, as every
    /// event masks it: `ToolArgumentRedaction`), each string redacted and
    /// then cut to `fieldBytes`, at most `fieldCount` elements of a list
    /// or fields of an object, the whole cut to `argumentBytes`. The value
    /// is read as it is, never encoded whole first: a file_write of a
    /// megabyte costs its first kilobyte.
    func arguments(_ arguments: JSONValue, tool _: String) -> String {
        text(summarized(arguments).canonicalJSON, limit: Self.argumentBytes)
    }

    private func summarized(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .object(fields):
            var kept: [String: JSONValue] = [:]
            for key in fields.keys.sorted().prefix(Self.fieldCount) {
                guard let field = fields[key] else { continue }
                kept[key] = LogRedaction.isSecretName(key) && field != .null ? .string(LogRedaction.redacted) : summarized(field)
            }
            if fields.count > Self.fieldCount {
                kept["…"] = .string("\(fields.count - Self.fieldCount) more fields")
            }
            return .object(kept)
        case let .array(values):
            var kept = values.prefix(Self.fieldCount).map(summarized)
            if values.count > Self.fieldCount {
                kept.append(.string("… \(values.count - Self.fieldCount) more"))
            }
            return .array(kept)
        case let .string(string):
            return .string(text(string, limit: Self.fieldBytes))
        default:
            return value
        }
    }

    // MARK: - Results

    /// The tools whose result is the user's own content — a file, a match,
    /// a listing, a memory or skill, another conversation, a web page, the
    /// device's log, a crash report, the screen — which a journal records
    /// only by size (owner, 2026-10-31).
    static let contentTools: Set<AgentToolName> = [
        .fileRead, .fileList, .fileGrep, .fileFind, .fileShow, .memoryList, .memorySave, .memoryDelete,
        .skillList, .skillRead, .skillSave, .skillRemove, .conversationRead, .webFetch, .logRead,
        .crashList, .crashRead, .crashSymbolicate, .screenCapture, .screenReadTree, .screenInteract,
    ]

    /// A call's result: for a content tool's that succeeded, its size —
    /// bytes and lines of text, images —, never its text; for any other,
    /// and for a content tool's error, its text redacted and cut to
    /// `resultBytes`, images named.
    func result(_ result: AgentToolResult, tool: String, isError: Bool) -> String {
        if !isError, let name = AgentToolName.canonical(tool), Self.contentTools.contains(name) {
            return Self.size(of: result)
        }
        let parts = result.content.map { block -> String in
            switch block {
            case let .text(text): text.text
            case let .image(image): "[image \(image.mimeType)]"
            }
        }
        return text(parts.joined(separator: "\n"), limit: Self.resultBytes)
    }

    /// `"2,345 bytes in 57 lines"`, with the images there are: what a
    /// content tool's result says without saying what it holds.
    static func size(of result: AgentToolResult) -> String {
        var bytes = 0
        var lines = 0
        var images = 0
        for block in result.content {
            switch block {
            case let .text(text):
                bytes += text.text.utf8.count
                // a last line without its line end is a line too
                lines += text.text.reduce(into: 0) { count, character in
                    if character.isNewline {
                        count += 1
                    }
                } + (text.text.last.map { $0.isNewline ? 0 : 1 } ?? 0)
            case .image:
                images += 1
            }
        }
        var parts: [String] = []
        if bytes > 0 || images == 0 {
            parts.append("\(grouped(bytes)) bytes in \(grouped(lines)) \(lines == 1 ? "line" : "lines")")
        }
        if images > 0 {
            parts.append("\(images) \(images == 1 ? "image" : "images")")
        }
        return "\"" + parts.joined(separator: ", ") + "\""
    }

    // MARK: - Hosts

    /// An endpoint's host as a journal names it: none for a private
    /// address or a name on the local network.
    static func endpoint(_ host: String?) -> String {
        guard let host, !host.isEmpty else { return "-" }
        return PrivateShapes.isLocalHost(host) ? "local-endpoint" : host
    }
}
