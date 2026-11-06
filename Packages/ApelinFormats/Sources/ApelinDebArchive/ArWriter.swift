import ApelinDebian
import Foundation

/// The `ar` container around a `.deb`: the global magic, then members with
/// 60-byte headers, as `dpkg-deb` writes them — plain names with no trailing
/// slash, uid and gid 0, mode 100644, and each member padded to an even
/// length with a newline.
final class ArWriter {
    private let sink: PatchableSink
    private let modificationTime: Int64

    init(sink: PatchableSink, modificationTime: Int64) throws {
        self.sink = sink
        self.modificationTime = modificationTime
        try sink.write(Array("!<arch>\n".utf8))
    }

    /// A member whose bytes are known up front.
    func addMember(name: String, contents: Data) throws {
        try sink.write(header(name: name, size: Int64(contents.count)))
        try sink.write(contents)
        try pad(Int64(contents.count))
    }

    /// A member streamed by `body` into the sink it is handed; the header's
    /// size is written once the stream has ended.
    func addMember(name: String, _ body: (ByteSink) throws -> Void) throws {
        let headerOffset = sink.byteCount
        try sink.write(header(name: name, size: 0))
        let counter = CountingSink(sink)
        try body(counter)
        try sink.overwrite(header(name: name, size: counter.byteCount), at: headerOffset)
        try pad(counter.byteCount)
    }

    @objc private dynamic func pad(_ size: Int64) throws {
        if size % 2 != 0 {
            try sink.write([0x0A])
        }
    }

    @objc private dynamic func header(name: String, size: Int64) throws -> [UInt8] {
        guard name.utf8.count <= 16, name.utf8.allSatisfy({ (33 ... 126).contains($0) && $0 != 0x2F }) else {
            throw PackageFormatError.invalidEntry("ar member name \(name.debugDescription)")
        }
        guard size >= 0, size < 10_000_000_000 else {
            throw PackageFormatError.tooLarge("ar member \(name) exceeds what its header can describe")
        }
        func field(_ text: String, _ width: Int) -> String {
            text + String(repeating: " ", count: width - text.utf8.count)
        }
        let text = field(name, 16)
            + field(String(modificationTime), 12)
            + field("0", 6)
            + field("0", 6)
            + field("100644", 8)
            + field(String(size), 10)
            + "`\n"
        return Array(text.utf8)
    }
}
