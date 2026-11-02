import Darwin
import Foundation

/// A list kept on disk, read one element at a time: an element that does not
/// decode — cut short, or written by another version with a case or a field
/// this one lacks — is kept as it was and written back with the rest, never
/// allowed to take the readable ones with it.
///
/// What this stands against (issues #33 and #34's audit): a whole list read
/// with `try?` falls back to empty when one element is bad, and the next
/// save writes the empty list over every good one; a list read with `try`
/// makes the whole feature fail. Use it for any `[Record]` that is both read
/// and written back.
public struct PreservedList<Element: Codable>: Codable {
    public var items: [Element]
    /// The elements that did not decode, as they were on disk.
    public private(set) var unreadable: [JSONValue]

    public init(_ items: [Element] = [], unreadable: [JSONValue] = []) {
        self.items = items
        self.unreadable = unreadable
    }

    public init(from decoder: Decoder) throws {
        items = []
        unreadable = []
        // Each element is one `Slot`, decoded once whatever it holds, so the
        // walk never depends on where a failed decode leaves the container.
        for slot in try [Slot](from: decoder) {
            switch slot {
            case let .item(item): items.append(item)
            case let .raw(raw): unreadable.append(raw)
            }
        }
    }

    /// One element: what it decodes to, else the JSON it is, read with the
    /// same decoder (and so the same date and data strategies).
    private enum Slot: Decodable {
        case item(Element)
        case raw(JSONValue)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let item = try? container.decode(Element.self) {
                self = .item(item)
            } else {
                self = try .raw(container.decode(JSONValue.self))
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for item in items {
            try container.encode(item)
        }
        for raw in unreadable {
            try container.encode(raw)
        }
    }
}

/// A file Apelin keeps that does not read at all. It is never replaced with
/// an empty state that the next save would make permanent: it is renamed
/// beside itself, `<name>.unreadable-<time>`, kept for whoever looks, and the
/// caller starts afresh.
public enum UnreadableFile {
    /// Renames `url` aside; answers the new location, or nil when nothing
    /// was there or the rename failed (the caller must not overwrite it).
    @discardableResult
    public static func setAside(_ url: URL, now: Date = Date()) -> URL? {
        let stamp = Int(now.timeIntervalSince1970)
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)")
        var attempt = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            attempt += 1
            destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).unreadable-\(stamp)-\(attempt)")
        }
        return rename(url.path, destination.path) == 0 ? destination : nil
    }
}
