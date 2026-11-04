import ApelinCore
import ApelinProtocol
import Foundation
import os

/// Where the console's lines go besides a run's output file.
public protocol ConsoleLogSink: Sendable {
    /// One output line, exactly as written to the run's file.
    func line(_ text: String)
    /// A problem outside any run's output (a folder the console cannot make).
    func problem(_ text: String)
}

/// The unified log: subsystem `wiki.qaq.apelin`, category `console`. The
/// app's sink.
public struct UnifiedLogSink: ConsoleLogSink {
    private let log = Logger(subsystem: DataFolder.bundleIdentifier, category: "console")

    public init() {}

    public func line(_ text: String) {
        log.log("\(text, privacy: .public)")
    }

    public func problem(_ text: String) {
        log.error("console: \(text, privacy: .public)")
    }
}

/// One run's JSON lines: to the file, and each to the log sink.
final class ConsoleOutput: @unchecked Sendable {
    private let handle: FileHandle?
    private let runID: String
    private let log: any ConsoleLogSink
    private let lock = PthreadLock()

    init(url: URL, runID: String, log: any ConsoleLogSink, append: Bool = false) {
        if !append || !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        if append {
            _ = try? handle?.seekToEnd()
        }
        self.runID = runID
        self.log = log
    }

    func write(_ type: String, _ fields: [String: JSONValue]) {
        var object = fields
        object["type"] = .string(type)
        object["runID"] = .string(runID)
        object["time"] = .string(ISO8601DateFormatter().string(from: Date()))
        guard var line = try? JSONCoding.encode(JSONValue.object(object)) else { return }
        let text = String(decoding: line, as: UTF8.self)
        line.append(0x0A)
        lock.withLock { handle?.write(line) }
        log.line(text)
    }

    @objc dynamic func close() {
        lock.withLock { try? handle?.close() }
    }
}
