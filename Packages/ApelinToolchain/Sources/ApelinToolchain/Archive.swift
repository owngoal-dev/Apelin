import Compression
import CryptoKit
import CToolchainSystem
import Darwin
import Foundation

public struct ToolchainArchiveLimits: Sendable {
    public var expandedBytes: Int64 = 8 * 1024 * 1024 * 1024
    public var entries: Int = 200_000
    public var pathDepth: Int = 64
    public init() {}
}

/// The extractor owns a new private directory; callers must not concurrently mutate it.
struct PackageArchive {
    let limits: ToolchainArchiveLimits
    func extract(_ package: URL, to destination: URL) throws {
        let reader = try BinaryReader(package)
        let header = try reader.read(28)
        guard header.prefix(4) == Data("xar!".utf8), try header.number(6, as: UInt16.self, big: true) == 1 else {
            throw ToolchainFailure("The package format is not supported. Choose another toolchain.")
        }
        let headerSize = try Int(header.number(4, as: UInt16.self, big: true))
        let compressed = try header.number(8, as: UInt64.self, big: true),
            expanded = try header.number(16, as: UInt64.self, big: true)
        guard headerSize >= 28, compressed <= 16 * 1024 * 1024, expanded <= 64 * 1024 * 1024 else {
            throw ToolchainFailure("The package index is invalid or exceeds the size limit.")
        }
        try reader.seek(UInt64(headerSize))
        let packed = try reader.read(Int(compressed))
        var xml = Data(count: Int(expanded)); var size = uLongf(expanded)
        let status = xml.withUnsafeMutableBytes { output in packed.withUnsafeBytes { input in
            uncompress(
                output.bindMemory(to: UInt8.self).baseAddress!,
                &size,
                input.bindMemory(to: UInt8.self).baseAddress!,
                uLong(packed.count),
            )
        } }
        guard status == Z_OK, size == expanded else {
            throw ToolchainFailure("The package index is damaged. Download the toolchain again.")
        }
        let toc = XarTOC()
        let parser = XMLParser(data: xml); parser.delegate = toc; parser.shouldResolveExternalEntities = false
        guard parser.parse(), let payload = toc.payload, payload.offset >= 0, payload.length > 12 else {
            throw ToolchainFailure("The package contains invalid or unsupported content.")
        }
        let start = UInt64(headerSize) + compressed + UInt64(payload.offset)
        guard start <= reader.size, UInt64(payload.length) <= reader.size - start else {
            throw ToolchainFailure("The package index points beyond the end of the file.")
        }
        guard ["sha1", "sha256"].contains(payload.algorithm) else {
            throw ToolchainFailure("The package uses an unsupported integrity check.")
        }
        try reader.seek(start)
        var remaining = payload.length
        // Only the algorithm the table names: hashing the payload both ways cost a second pass's worth of CPU.
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        let useSHA1 = payload.algorithm == "sha1"
        while remaining > 0 {
            try Task.checkCancellation()
            let data = try reader.read(Int(min(4 * 1024 * 1024, remaining)))
            if useSHA1 {
                sha1.update(data: data)
            } else {
                sha256.update(data: data)
            }
            remaining -= Int64(data.count)
        }
        let actual = useSHA1 ? hex(sha1.finalize()) : hex(sha256.finalize())
        guard actual == payload.checksum else {
            throw ToolchainFailure("The package content failed its integrity check. Download the toolchain again.")
        }
        try reader.seek(start)
        let pbzx = try PBZXReader(reader: reader, end: start + UInt64(payload.length))
        try directory(destination)
        let root = try canonical(destination)
        try extractCPIO(pbzx, root: root)
    }

    func extractCPIO(_ stream: ByteReader, root: URL) throws {
        var count = 0, total: Int64 = 0
        var links: [(URL, String)] = []
        var seen = Set<String>()
        var hardlinks: [String: URL] = [:]
        var deferredHardlinks: [(URL, String)] = []
        while true {
            try Task.checkCancellation()
            let magic = try stream.read(6)
            let headerSize: Int, alignment: Int, mode: Int, bytes: Int, nameSize: Int, inode: Int, linkCount: Int
            let device: String
            func value(_ data: Data, _ start: Int, _ length: Int, radix: Int) throws -> Int {
                guard
                    let n = Int(String(decoding: data[start ..< start + length], as: UTF8.self), radix: radix),
                    n >= 0
                else {
                    throw ToolchainFailure("The package contains invalid file metadata.")
                }
                return n
            }
            if magic == Data("070707".utf8) {
                let h = try stream.read(70)
                headerSize = 76; alignment = 1
                device = try String(value(h, 0, 6, radix: 8)); inode = try value(h, 6, 6, radix: 8)
                mode = try value(h, 12, 6, radix: 8); linkCount = try value(h, 30, 6, radix: 8)
                nameSize = try value(h, 53, 6, radix: 8); bytes = try value(h, 59, 11, radix: 8)
            } else if magic == Data("070701".utf8) {
                let h = try stream.read(104)
                headerSize = 110; alignment = 4
                inode = try value(h, 0, 8, radix: 16); mode = try value(h, 8, 8, radix: 16)
                linkCount = try value(h, 32, 8, radix: 16); bytes = try value(h, 48, 8, radix: 16)
                device = try "\(value(h, 56, 8, radix: 16)):\(value(h, 64, 8, radix: 16))"; nameSize = try value(h, 88, 8, radix: 16)
            } else {
                throw ToolchainFailure("The package uses an unsupported archive format.")
            }
            guard nameSize > 0, nameSize <= 4096, Int64(bytes) <= limits.expandedBytes - total else {
                throw ToolchainFailure("The package has an invalid file name or exceeds the size limit.")
            }
            let nameData = try stream.read(nameSize)
            guard
                nameData.last == 0,
                !nameData.dropLast().contains(0),
                let name = String(data: nameData.dropLast(), encoding: .utf8)
            else {
                throw ToolchainFailure("The package contains an invalid file path.")
            }
            _ = try stream.read((alignment - (headerSize + nameSize) % alignment) % alignment)
            if name == "TRAILER!!!" {
                break
            }
            count += 1; total += Int64(bytes)
            guard count <= limits.entries else {
                throw ToolchainFailure("The package contains too many files. Choose another toolchain.")
            }
            let parts = name.split(separator: "/").map(String.init).filter { $0 != "." }
            guard !name.hasPrefix("/"), !parts.contains(".."), parts.count <= limits.pathDepth else {
                throw ToolchainFailure("The package contains an unsafe or overly nested path.")
            }
            if parts.isEmpty {
                guard mode & 0o170000 == 0o040000, bytes == 0 else {
                    throw ToolchainFailure("The package root is not a valid folder.")
                }
                continue
            }
            let relative = parts.joined(separator: "/")
            guard seen.insert(relative).inserted else {
                throw ToolchainFailure("The package contains a duplicate path: \(relative).")
            }
            let target = root.appendingPathComponent(relative)
            try directory(target.deletingLastPathComponent())
            guard try contained(canonical(target.deletingLastPathComponent()), in: root) else {
                throw ToolchainFailure("A package folder resolves outside the extraction folder.")
            }
            switch mode & 0o170000 {
            case 0o040000:
                guard bytes == 0 else {
                    throw ToolchainFailure("The package contains a folder with invalid file data.")
                }
                try directory(target)
            case 0o100000:
                // All symlinks are deferred, so no path traversal can follow one during extraction.
                let key = "\(device):\(inode)"
                if linkCount > 1, bytes == 0 {
                    deferredHardlinks.append((target, key))
                } else {
                    let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(mode & 0o755))
                    guard fd >= 0 else { throw ToolchainFailure("Unable to extract a package file.") }
                    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var remaining = bytes
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let chunk = try stream.read(min(1024 * 1024, remaining)); try file.write(contentsOf: chunk); remaining -= chunk.count
                    }
                    try file.close()
                    if linkCount > 1 {
                        hardlinks[key] = target
                    }
                }
            case 0o120000:
                guard
                    bytes > 0,
                    bytes <= 4096,
                    let link = try String(data: stream.read(bytes), encoding: .utf8),
                    !link.utf8.contains(0),
                    !link.hasPrefix("/")
                else {
                    throw ToolchainFailure("The package contains an unsafe symbolic link.")
                }
                var linkParts = Array(parts.dropLast())
                for component in link.split(separator: "/") {
                    if component == ".." {
                        guard !linkParts.isEmpty else {
                            throw ToolchainFailure(
                                "A package symbolic link points outside the extraction folder: \(relative) -> \(link).",
                            )
                        }
                        linkParts.removeLast()
                    } else if component != "." {
                        linkParts.append(String(component))
                    }
                }
                links.append((target, link))
            default: throw ToolchainFailure("The package contains an unsupported file type.")
            }
            _ = try stream.read((alignment - bytes % alignment) % alignment)
        }
        for (target, key) in deferredHardlinks {
            if let original = hardlinks[key] {
                try FileManager.default.linkItem(at: original, to: target)
            } else {
                guard FileManager.default.createFile(
                    atPath: target.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o644],
                ) else {
                    throw ToolchainFailure("Unable to extract a linked package file.")
                }
                hardlinks[key] = target
            }
        }
        let linkMap = Dictionary(uniqueKeysWithValues: links.map {
            ($0.0.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/"), $0.1)
        })
        // Validate complete link chains before creating any link. Missing in-tree targets are
        // permitted (Apple ships crashlog pointing into another package), but never selected.
        for name in linkMap.keys {
            var pending = name.split(separator: "/").map(String.init), resolved: [String] = [], hops = 0
            while !pending.isEmpty {
                let part = pending.removeFirst()
                if part == "." {
                    continue
                }
                if part == ".." {
                    guard !resolved.isEmpty else {
                        throw ToolchainFailure("A package symbolic link resolves outside the extraction folder.")
                    }
                    resolved.removeLast(); continue
                }
                resolved.append(part)
                if let destination = linkMap[resolved.joined(separator: "/")] {
                    hops += 1
                    guard hops <= 40 else {
                        throw ToolchainFailure("The package contains too many nested symbolic links.")
                    }
                    resolved.removeLast()
                    pending = destination.split(separator: "/").map(String.init) + pending
                }
            }
        }
        for (target, link) in links {
            try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: link)
        }
        for (target, _) in links {
            if let resolved = try? canonical(target) {
                guard contained(resolved, in: root) else {
                    throw ToolchainFailure("A package symbolic link resolves outside the extraction folder.")
                }
            }
        }
    }
}

protocol ByteReader { func read(_ count: Int) throws -> Data }
final class BinaryReader: ByteReader {
    let file: FileHandle
    let size: UInt64
    @objc dynamic var offset: UInt64 = 0
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url); size = try file.seekToEnd(); try file.seek(toOffset: 0)
    }

    deinit { try? file.close() }
    @objc dynamic func seek(_ offset: UInt64) throws {
        guard offset <= size else { throw ToolchainFailure("The package points beyond the end of the file.") }; try file.seek(toOffset: offset); self.offset = offset
    }

    func read(_ count: Int) throws -> Data {
        guard count >= 0, UInt64(count) <= size - offset else { throw ToolchainFailure("The package is incomplete.") }
        let data = try autoreleasepool { try file.read(upToCount: count) } ?? Data()
        guard data.count == count else { throw ToolchainFailure("The package is incomplete.") }
        offset += UInt64(count); return data
    }
}

/// The Payload's pbzx stream: a header, then chunks that are each an
/// independent XZ stream (or stored as is). Chunks are read in order and up
/// to `window` of them are decoded at once on the device's cores, then handed
/// out in order: the bytes are the ones a one-at-a-time decode gives, and at
/// most `window` chunks (each at most 64 MB, 16 MB in Apple's packages) are
/// held. Four at once took CLT 15.0's extraction from 78 s to 36 s on an
/// A12Z and from about 50 s to 20 s on an iPhone 15 Pro (2026-10-21).
final class PBZXReader: ByteReader {
    let reader: BinaryReader, end: UInt64
    let window: Int
    var buffer = Data()
    @objc dynamic var cursor = 0
    private var decoded: [Data] = []
    init(reader: BinaryReader, end: UInt64, window: Int = PBZXReader.defaultWindow) throws {
        self.reader = reader; self.end = end; self.window = max(1, window)
        guard try reader.read(4) == Data("pbzx".utf8) else {
            throw ToolchainFailure("The package uses an unsupported compression format.")
        }
        let chunkSize = try reader.read(8).number(0, as: UInt64.self, big: true)
        guard chunkSize > 0, chunkSize <= 64 * 1024 * 1024 else {
            throw ToolchainFailure("The package uses an unsupported compression block size.")
        }
    }

    func read(_ count: Int) throws -> Data {
        var result = Data(); result.reserveCapacity(count)
        while result.count < count {
            if cursor == buffer.count {
                try nextChunk()
            }
            let length = min(count - result.count, buffer.count - cursor)
            result.append(buffer[cursor ..< cursor + length]); cursor += length
        }
        return result
    }

    /// Four decodes at once at most, and never more than the cores: past
    /// four the reads and the cpio writer, which stay serial, set the pace.
    @objc dynamic static var defaultWindow: Int {
        min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    @objc private dynamic func nextChunk() throws {
        try Task.checkCancellation()
        if decoded.isEmpty {
            try fill()
        }
        buffer = decoded.removeFirst()
        cursor = 0
    }

    /// Reads the next chunks (up to `window`, stopping at the stream's end
    /// only when the cpio reader still wants bytes) and decodes them side by side.
    @objc private dynamic func fill() throws {
        var chunks: [(expanded: Int, input: Data)] = []
        repeat {
            guard reader.offset <= end, end - reader.offset >= 16 else {
                if chunks.isEmpty {
                    throw ToolchainFailure(
                        "The compressed package content is incomplete. Download the toolchain again.",
                    )
                }
                break
            }
            let h = try reader.read(16)
            let expanded = try h.number(0, as: UInt64.self, big: true),
                packed = try h.number(8, as: UInt64.self, big: true)
            guard
                expanded > 0,
                expanded <= 64 * 1024 * 1024,
                packed > 0,
                packed <= 64 * 1024 * 1024,
                packed <= end - reader.offset
            else {
                throw ToolchainFailure("A compressed package block is invalid or exceeds the size limit.")
            }
            try chunks.append((Int(expanded), reader.read(Int(packed))))
        } while chunks.count < window
        decoded = try concurrentMap(chunks) {
            try Self.decode($0.input, expanded: $0.expanded)
        }
    }

    static func decode(_ input: Data, expanded: Int) throws -> Data {
        if input.count == expanded {
            return input
        }
        var output = Data(count: expanded)
        let count = output.withUnsafeMutableBytes { output in input.withUnsafeBytes { source in
            compression_decode_buffer(
                output.bindMemory(to: UInt8.self).baseAddress!,
                output.count,
                source.bindMemory(to: UInt8.self).baseAddress!,
                source.count,
                nil,
                COMPRESSION_LZMA,
            )
        } }
        guard count == expanded else { throw ToolchainFailure("The compressed package content is damaged.") }
        return output
    }
}

private final class XarTOC: NSObject, XMLParserDelegate {
    struct Payload { let offset: Int64; let length: Int64; let checksum: String; let algorithm: String }
    var payload: Payload?
    private var stack: [String] = [], text = "", fields: [String: String] = [:]
    @objc private dynamic var fileDepth = 0
    @objc dynamic func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes: [String: String],
    ) {
        stack.append(elementName); text = ""
        if elementName == "archived-checksum", fileDepth == 1 {
            fields["checksumAlgorithm"] = attributes["style"]
        }
        if elementName == "file" {
            fileDepth += 1; if fileDepth == 1 {
                fields = [:]
            }
        }
    }

    @objc dynamic func parser(_: XMLParser, foundCharacters string: String) {
        text += string
    }

    @objc dynamic func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
    ) {
        if fileDepth == 1 {
            fields[stack.suffix(2).joined(separator: "/")] = text
        }
        if elementName == "file" {
            if fileDepth == 1,
               fields["file/name"] == "Payload",
               let offset = Int64(fields["data/offset"] ?? ""),
               let length = Int64(fields["data/length"] ?? "")
            {
                payload = Payload(
                    offset: offset,
                    length: length,
                    checksum: fields["data/archived-checksum"] ?? "",
                    algorithm: fields["checksumAlgorithm"] ?? "",
                )
            }
            fileDepth -= 1
        }
        stack.removeLast(); text = ""
    }
}
