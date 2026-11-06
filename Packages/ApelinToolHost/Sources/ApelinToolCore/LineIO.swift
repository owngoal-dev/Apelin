import Darwin
import Foundation

/// Reads newline-terminated lines from a descriptor, blocking, with a bound
/// on how long a line may grow. Meant to be driven from one thread.
public final class LineReader {
    public enum Event: Equatable {
        case line(Data)
        /// A line passed `maxLineBytes`. Its remainder is skipped up to the
        /// next newline, so a reader that keeps going resynchronises there.
        case oversized
        case endOfFile
    }

    private let descriptor: Int32
    private let maxLineBytes: Int
    private var buffer = Data()
    @objc private dynamic var skipping = false
    @objc private dynamic var finished = false
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)

    /// Does not take ownership of `descriptor`.
    public init(descriptor: Int32, maxLineBytes: Int) {
        self.descriptor = descriptor
        self.maxLineBytes = maxLineBytes
    }

    public func next() -> Event {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                if skipping {
                    skipping = false
                    continue
                }
                if line.count > maxLineBytes {
                    return .oversized
                }
                // Blank lines carry nothing; a CR before the newline is
                // tolerated rather than handed to the JSON parser.
                var trimmed = Data(line)
                if trimmed.last == 0x0D {
                    trimmed.removeLast()
                }
                if trimmed.isEmpty {
                    continue
                }
                return .line(trimmed)
            }
            if !skipping, buffer.count > maxLineBytes {
                buffer.removeAll(keepingCapacity: false)
                skipping = true
                return .oversized
            }
            if skipping {
                buffer.removeAll(keepingCapacity: true)
            }
            if finished {
                return .endOfFile
            }
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.append(contentsOf: chunk[0 ..< count])
            } else if count == 0 {
                finished = true
                // A last line without a newline is still a line.
                if !buffer.isEmpty, !skipping {
                    buffer.append(0x0A)
                }
            } else if errno != EINTR {
                finished = true
                return .endOfFile
            }
        }
    }
}

/// Writes whole frames to a descriptor, one writer at a time.
public final class LineWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()

    /// Does not take ownership of `descriptor`. A pipe whose reader has gone
    /// returns EPIPE here instead of raising SIGPIPE in the whole process.
    public init(descriptor: Int32) {
        self.descriptor = descriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    public func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return
                }
                remaining -= written
                pointer += written
            }
        }
    }
}
