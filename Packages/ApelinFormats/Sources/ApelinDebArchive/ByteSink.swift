import ApelinDebian
import Foundation

/// Where archive bytes go, in order.
protocol ByteSink: AnyObject {
    func write(_ bytes: UnsafeRawBufferPointer) throws
}

extension ByteSink {
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    func write(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { try write($0) }
    }
}

/// The outermost sink: the `.deb` itself. It knows its length and can
/// overwrite bytes it already wrote, which is how an `ar` member header gets
/// its size after the member has streamed through a compressor.
protocol PatchableSink: ByteSink {
    var byteCount: Int64 { get }
    func overwrite(_ bytes: [UInt8], at offset: Int64) throws
}

final class MemorySink: PatchableSink {
    private(set) var data = Data()

    @objc dynamic var byteCount: Int64 {
        Int64(data.count)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        data.append(contentsOf: bytes)
    }

    @objc dynamic func overwrite(_ bytes: [UInt8], at offset: Int64) throws {
        let start = data.startIndex + Int(offset)
        data.replaceSubrange(start ..< start + bytes.count, with: bytes)
    }
}

/// A descriptor written with `pwrite` at offsets this sink tracks.
final class DescriptorSink: PatchableSink {
    private let descriptor: Int32
    @objc private(set) dynamic var byteCount: Int64 = 0

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try put(bytes, at: byteCount)
        byteCount += Int64(bytes.count)
    }

    @objc dynamic func overwrite(_ bytes: [UInt8], at offset: Int64) throws {
        try bytes.withUnsafeBytes { try put($0, at: offset) }
    }

    private func put(_ bytes: UnsafeRawBufferPointer, at offset: Int64) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var written = 0
        while written < bytes.count {
            let put = pwrite(
                descriptor,
                base.advanced(by: written),
                bytes.count - written,
                off_t(offset) + off_t(written),
            )
            if put < 0 {
                if errno == EINTR {
                    continue
                }
                throw PackageFormatError.system(errno: errno, "write")
            }
            if put == 0 {
                throw PackageFormatError.system(errno: ENOSPC, "write")
            }
            written += put
        }
    }
}

/// Counts what passes through, for the `ar` member size.
final class CountingSink: ByteSink {
    private let next: ByteSink
    @objc private(set) dynamic var byteCount: Int64 = 0

    init(_ next: ByteSink) {
        self.next = next
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        try next.write(bytes)
        byteCount += Int64(bytes.count)
    }
}
