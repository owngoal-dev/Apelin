import ApelinDebian
import ArchiveKit
import Foundation

/// How `control.tar` and `data.tar` are compressed. Each one names the member
/// (`data.tar.zst`, `data.tar.xz`, ...) and every one is something Irisin's
/// reader and dpkg both decode.
public enum DebCompression: String, Sendable, Hashable, CaseIterable {
    /// What `Scripts/package-deb.sh` ships (`dpkg-deb -Zzstd`), and the
    /// default.
    case zstd
    case xz
    case gzip
    /// A bare `data.tar`. Larger, but nothing to decode.
    case none

    /// The `ar` member suffix after `.tar`.
    public var memberSuffix: String {
        switch self {
        case .zstd: ".zst"
        case .xz: ".xz"
        case .gzip: ".gz"
        case .none: ""
        }
    }

    /// dpkg-deb's own default level for each, so a package written here
    /// weighs what the Mac packager's would.
    public var defaultLevel: Int {
        switch self {
        case .zstd: 3
        case .xz: 6
        case .gzip: 9
        case .none: 0
        }
    }
}

/// A sink that compresses everything written to it into `next`.
///
/// libarchive does the compression: its `raw` format writes one member's
/// bytes with no container around them, through the same filter code Fila's
/// and Irisin's archives use, and every codec is linked into the static
/// binary — nothing spawns a helper. Output is unblocked (no record padding)
/// and single-threaded, so the same input always gives the same bytes; gzip
/// leaves its timestamp field zero for the same reason.
final class CompressingSink: ByteSink {
    private let archive: OpaquePointer
    private let output: Output

    /// libarchive calls back into this with the compressed bytes.
    private final class Output {
        let next: ByteSink
        @objc dynamic var failure: Error?

        init(next: ByteSink) {
            self.next = next
        }
    }

    init(compression: DebCompression, into next: ByteSink) throws {
        guard let archive = archive_write_new() else {
            throw PackageFormatError.archive("archive_write_new failed")
        }
        self.archive = archive
        output = Output(next: next)
        let level = compression.defaultLevel
        let filter: Int32
        let options: String
        switch compression {
        case .zstd:
            filter = archive_write_add_filter_zstd(archive)
            options = "zstd:compression-level=\(level),zstd:threads=1"
        case .xz:
            filter = archive_write_add_filter_xz(archive)
            options = "xz:compression-level=\(level),xz:threads=1"
        case .gzip:
            filter = archive_write_add_filter_gzip(archive)
            options = "gzip:compression-level=\(level),gzip:!timestamp"
        case .none:
            preconditionFailure("an uncompressed member needs no compressor")
        }
        do {
            // A warning means libarchive would run an external program for
            // the codec. Only linked-in codecs are acceptable.
            try check(filter)
            try check(archive_write_set_format_raw(archive))
            try check(archive_write_set_options(archive, options))
            try check(archive_write_set_bytes_per_block(archive, 0))
            try check(archive_write_open2(
                archive,
                Unmanaged.passUnretained(output).toOpaque(),
                nil,
                { _, client, buffer, length in
                    guard let client, let buffer else { return -1 }
                    let output = Unmanaged<Output>.fromOpaque(client).takeUnretainedValue()
                    do {
                        try output.next.write(UnsafeRawBufferPointer(start: buffer, count: length))
                        return length
                    } catch {
                        output.failure = error
                        return -1
                    }
                },
                nil,
                nil,
            ))
            guard let entry = archive_entry_new() else { throw PackageFormatError.archive("archive_entry_new failed") }
            defer { archive_entry_free(entry) }
            archive_entry_set_pathname(entry, "member")
            archive_entry_set_filetype(entry, UInt32(S_IFREG))
            archive_entry_set_perm(entry, 0o644)
            try check(archive_write_header(archive, entry))
        } catch {
            archive_write_free(archive)
            throw error
        }
    }

    deinit {
        archive_write_free(archive)
    }

    func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        var done = 0
        while done < bytes.count {
            let wrote = archive_write_data(archive, base.advanced(by: done), bytes.count - done)
            if wrote < 0 {
                throw failure()
            }
            if wrote == 0 {
                throw PackageFormatError.archive("the compressor accepted no bytes")
            }
            done += wrote
        }
    }

    /// Flushes the compressor's tail. Nothing may be written after this.
    @objc dynamic func finish() throws {
        try check(archive_write_close(archive))
    }

    @objc private dynamic func check(_ status: Int32) throws {
        guard status == ARCHIVE_OK else { throw failure() }
    }

    @objc private dynamic func failure() -> Error {
        if let error = output.failure {
            return error
        }
        return PackageFormatError.archive(
            archive_error_string(archive).map { String(cString: $0) } ?? "libarchive error",
        )
    }
}
