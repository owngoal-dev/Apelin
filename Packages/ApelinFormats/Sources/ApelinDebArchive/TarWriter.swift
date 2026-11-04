import ApelinDebian
import Foundation

/// A GNU-format tar stream, the format `dpkg-deb` itself writes.
///
/// Hand-written rather than libarchive's writer so every byte is decided
/// here: no host user or group lookup, no PAX headers carrying access times,
/// no extended attributes or ACLs picked up from the build machine. A name or
/// link target over 100 bytes goes in a GNU `././@LongLink` record, which
/// dpkg, libarchive and every tar read.
final class TarWriter {
    enum Kind {
        case file(size: Int64)
        case directory
        case symbolicLink(target: String)
    }

    private let sink: ByteSink

    init(sink: ByteSink) {
        self.sink = sink
    }

    /// Writes one member's header. A regular file's `size` bytes follow
    /// through `writeContents`, then `finishContents` pads them.
    func writeHeader(name: String, kind: Kind, mode: UInt16, modificationTime: Int64) throws {
        let size: Int64
        let typeflag: UInt8
        var linkName = ""
        switch kind {
        case let .file(fileSize):
            size = fileSize
            typeflag = UInt8(ascii: "0")
        case .directory:
            size = 0
            typeflag = UInt8(ascii: "5")
        case let .symbolicLink(target):
            size = 0
            typeflag = UInt8(ascii: "2")
            linkName = target
        }
        guard size >= 0, size < Self.octalLimit(digits: 11) else {
            throw PackageFormatError.tooLarge("\(name) is larger than a tar header can describe")
        }
        guard modificationTime >= 0, modificationTime < Self.octalLimit(digits: 11) else {
            throw PackageFormatError.invalidEntry("\(name) has a modification time tar cannot store")
        }
        let nameBytes = Array(name.utf8)
        let linkBytes = Array(linkName.utf8)
        if nameBytes.count > 100 {
            try writeLongLink(nameBytes, typeflag: UInt8(ascii: "L"))
        }
        if linkBytes.count > 100 {
            try writeLongLink(linkBytes, typeflag: UInt8(ascii: "K"))
        }
        try sink.write(Self.header(
            name: nameBytes,
            mode: mode,
            size: size,
            modificationTime: modificationTime,
            typeflag: typeflag,
            linkName: linkBytes,
        ))
    }

    func writeContents(_ bytes: UnsafeRawBufferPointer) throws {
        try sink.write(bytes)
    }

    /// Pads the member that just ended to the next 512-byte block.
    @objc dynamic func finishContents(size: Int64) throws {
        let remainder = Int(size % 512)
        if remainder != 0 {
            try sink.write([UInt8](repeating: 0, count: 512 - remainder))
        }
    }

    /// The two zero blocks that end a tar stream.
    @objc dynamic func finish() throws {
        try sink.write([UInt8](repeating: 0, count: 1024))
    }

    @objc private dynamic func writeLongLink(_ bytes: [UInt8], typeflag: UInt8) throws {
        let payload = bytes + [0]
        try sink.write(Self.header(
            name: Array("././@LongLink".utf8),
            mode: 0o644,
            size: Int64(payload.count),
            modificationTime: 0,
            typeflag: typeflag,
            linkName: [],
        ))
        try sink.write(payload)
        try finishContents(size: Int64(payload.count))
    }

    /// One 512-byte GNU header. Fields beyond the name and link name are
    /// fixed: root:wheel, uid and gid 0, no device numbers.
    @objc static dynamic func header(
        name: [UInt8],
        mode: UInt16,
        size: Int64,
        modificationTime: Int64,
        typeflag: UInt8,
        linkName: [UInt8],
    ) -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int, width: Int) {
            for (index, byte) in bytes.prefix(width).enumerated() {
                block[offset + index] = byte
            }
        }
        func octal(_ value: Int64, at offset: Int, width: Int) {
            let digits = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits
            put(Array(padded.utf8), at: offset, width: width - 1)
        }
        put(name, at: 0, width: 100)
        octal(Int64(mode), at: 100, width: 8)
        octal(0, at: 108, width: 8) // uid
        octal(0, at: 116, width: 8) // gid
        octal(size, at: 124, width: 12)
        octal(modificationTime, at: 136, width: 12)
        put(Array(repeating: 0x20, count: 8), at: 148, width: 8) // checksum, summed as spaces
        block[156] = typeflag
        put(linkName, at: 157, width: 100)
        put(Array("ustar  ".utf8), at: 257, width: 8) // GNU magic and version, NUL-terminated
        put(Array("root".utf8), at: 265, width: 32)
        put(Array("wheel".utf8), at: 297, width: 32)
        let checksum = block.reduce(0) { $0 + Int64($1) }
        octal(checksum, at: 148, width: 7)
        block[154] = 0
        block[155] = 0x20
        return block
    }

    @objc private static dynamic func octalLimit(digits: Int) -> Int64 {
        Int64(1) << (3 * digits)
    }
}
