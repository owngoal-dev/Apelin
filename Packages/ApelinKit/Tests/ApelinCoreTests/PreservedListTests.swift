import ApelinCore
import Foundation
import XCTest

/// A list read back from disk keeps what it cannot read (issue #33's audit).
final class PreservedListTests: XCTestCase {
    struct Record: Codable, Equatable {
        enum Kind: String, Codable { case c, swift }
        var id: String
        var kind: Kind
        var made: Date
    }

    func testAnUnreadableElementIsKeptAndWrittenBack() throws {
        for (encoder, decoder) in [(JSONEncoder(), JSONDecoder()), (JSONCoding.encoder(), JSONCoding.decoder())] {
            let good = Record(id: "a", kind: .c, made: Date(timeIntervalSince1970: 1_700_000_000))
            let goodJSON = try String(decoding: encoder.encode(good), as: UTF8.self)
            // a kind this version lacks, and an element missing a field
            let text = #"[\#(goodJSON),{"id":"b","kind":"rust","made":0},{"id":"c"}]"#
            let list = try decoder.decode(PreservedList<Record>.self, from: Data(text.utf8))
            XCTAssertEqual(list.items, [good])
            XCTAssertEqual(list.unreadable.count, 2)

            var written = list
            written.items.append(Record(id: "d", kind: .swift, made: good.made))
            let again = try decoder.decode(PreservedList<Record>.self, from: encoder.encode(written))
            XCTAssertEqual(again.items.map(\.id), ["a", "d"])
            XCTAssertEqual(again.unreadable, list.unreadable)
        }
    }

    func testAFileThatDoesNotReadIsSetAsideNotReplaced() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("registry.json")
        try Data("{".utf8).write(to: file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try XCTUnwrap(UnreadableFile.setAside(file, now: now))
        XCTAssertEqual(first.lastPathComponent, "registry.json.unreadable-1800000000")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try Data("{".utf8).write(to: file)
        let second = try XCTUnwrap(UnreadableFile.setAside(file, now: now))
        XCTAssertEqual(second.lastPathComponent, "registry.json.unreadable-1800000000-2")
        XCTAssertEqual(try Data(contentsOf: first), Data("{".utf8))
        XCTAssertNil(UnreadableFile.setAside(file, now: now))
    }
}
