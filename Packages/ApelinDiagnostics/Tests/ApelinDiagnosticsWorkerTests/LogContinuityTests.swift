import ApelinCore
import ApelinDiagnostics
import ApelinDiagnosticsCore
@testable import ApelinLogReaderWorker
import ApelinProtocol
import Foundation
import XCTest

/// icli's `SyslogStream` as the fakes play it: entries are offered one at a
/// time under a recursive lock (the handler may end the stream it is called
/// from), nothing is offered once it has ended, it ends by itself after its
/// seconds, and `onEnd` runs once on another queue.
final class FakeSyslogStream: IcliSyslogStream, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let handler: @Sendable (LogEntry) -> Bool
    private let onEnd: @Sendable (String) -> Void
    private var finished = false
    private var heard: [LogEntry] = []

    init(seconds: Double, handler: @escaping @Sendable (LogEntry) -> Bool, onEnd: @escaping @Sendable (String) -> Void) {
        self.handler = handler
        self.onEnd = onEnd
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [weak self] in self?.end("duration") }
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    /// Every entry offered while the stream was open, in order.
    var heardEntries: [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    func offer(_ entry: LogEntry) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        heard.append(entry)
        if !handler(entry), !finished {
            endLocked("handler")
        }
    }

    func end(_ reason: String) {
        lock.lock()
        if !finished {
            endLocked(reason)
        }
        lock.unlock()
    }

    func cancel() {
        end("cancelled")
    }

    private func endLocked(_ reason: String) {
        finished = true
        let onEnd = onEnd
        DispatchQueue.global().async { onEnd(reason) }
    }
}

/// A unified log in real time — a numbered line every `period`, with a
/// line from another subsystem between each — that every open stream hears
/// from the moment it opens until it ends.
private final class TimelineIcli: IcliSurface, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [FakeSyslogStream] = []
    private var counter = 0
    private var stopped = false
    private(set) var filters: [IcliSyslogFilter] = []
    /// When set, every stream is ended `interrupted` this long after it opens.
    var interruptAfter: TimeInterval?

    func start(period: TimeInterval) {
        Thread.detachNewThread { [self] in
            while !lock.withLock({ stopped }) {
                log()
                Thread.sleep(forTimeInterval: period)
            }
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    private func log() {
        lock.withLock {
            counter += 1
            let steady = LogEntry(date: Date(), process: "Steady", pid: 77, subsystem: "wiki.qaq.steady", category: "tick", level: .default, message: "line \(counter)")
            let noise = LogEntry(date: Date(), process: "Noise", pid: 78, subsystem: "wiki.qaq.steadyish", category: "tick", level: .default, message: "noise \(counter)")
            for stream in streams {
                stream.offer(steady)
                stream.offer(noise)
            }
        }
    }

    var stream: FakeSyslogStream? {
        lock.withLock { streams.last }
    }

    func openSyslogStream(
        filter: IcliSyslogFilter,
        seconds: Double,
        handler: @escaping @Sendable (LogEntry) -> Bool,
        onEnd: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream {
        let stream = FakeSyslogStream(seconds: seconds, handler: handler, onEnd: onEnd)
        lock.withLock {
            filters.append(filter)
            streams.append(stream)
        }
        if let interruptAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + interruptAfter) { stream.end("interrupted") }
        }
        return stream
    }

    private func unused() -> DiagnosticsError {
        .unavailable("not in this fake")
    }

    func captureSyslog(seconds _: Double, filter _: IcliSyslogFilter, maxLines _: Int) throws -> [String: Any] {
        throw unused()
    }

    func crashLogs(bundleID _: String?) throws -> [String: Any] {
        throw unused()
    }

    func readCrashLog(_: String, maxBytes _: Int) throws -> [String: Any] {
        throw unused()
    }

    func takeScreenshot() throws -> [String: Any] {
        throw unused()
    }

    func uiElements(maxElements _: Int, visibleOnly _: Bool, clickableOnly _: Bool) throws -> [String: Any] {
        throw unused()
    }

    func tap(x _: Double, y _: Double) throws -> [String: Any] {
        throw unused()
    }

    func tapElement(text _: String?, identifier _: String?, role _: String?, match _: String, index _: Int) throws -> [String: Any] {
        throw unused()
    }

    func waitForElement(
        text _: String?,
        identifier _: String?,
        role _: String?,
        match _: String,
        index _: Int,
        appear _: Bool,
        timeout _: Double,
        interval _: Double,
    ) throws -> [String: Any] {
        throw unused()
    }

    func swipe(x1 _: Double, y1 _: Double, x2 _: Double, y2 _: Double, seconds _: Double) throws -> [String: Any] {
        throw unused()
    }

    func typeText(_: String, delayMS _: Double) throws -> [String: Any] {
        throw unused()
    }

    func pressButton(_: String) throws -> [String: Any] {
        throw unused()
    }

    func frontmostApp() -> [String: Any] {
        [:]
    }

    func lockState() -> [String: Any] {
        [:]
    }

    func screenInfo() -> [String: Any] {
        [:]
    }

    func runningApps() throws -> [String: Any] {
        throw unused()
    }

    func respring() throws -> [String: Any] {
        throw unused()
    }
}

private final class Events: @unchecked Sendable {
    let lock = NSLock()
    var items: [(String, JSONValue?)] = []
    var end: (TaskState, String?)?
    let done = DispatchSemaphore(value: 0)
    func emit(_ kind: String, _ payload: JSONValue?) {
        lock.lock(); items.append((kind, payload)); lock.unlock()
    }

    func finish(_ state: TaskState, _ message: String?) {
        lock.lock(); end = (state, message); lock.unlock(); done.signal()
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.filter { $0.0 == "log" }.compactMap { $0.1?["message"]?.stringValue }
    }
}

/// The mobile `logStream` through one icli `SyslogStream`: what the stream
/// heard is what the task emits, once each and in order.
final class LogContinuityTests: XCTestCase {
    /// Numbered lines, so a drop or a repeat shows by number: every matching
    /// line the stream heard is one `log` event, in order, and nothing else.
    func testEveryLineHeardArrivesOnceInOrder() throws {
        let icli = TimelineIcli()
        icli.start(period: 0.01)
        defer { icli.stop() }
        let events = try stream(icli, filter: ApelinProtocol.LogFilter(subsystem: "wiki.qaq.steady", limit: 5000, windowSeconds: 3))
        XCTAssertEqual(events.end?.0, .succeeded)
        let stream = try XCTUnwrap(icli.stream)
        let expected = stream.heardEntries.filter { $0.subsystem == "wiki.qaq.steady" }.map(\.message)
        // Enough lines to show order and gaps; a slow CI runner hears far
        // fewer than the 300 a 10 ms period offers in 3 s.
        XCTAssertGreaterThan(expected.count, 20)
        // The window can end between a line reaching the stream and the
        // stream being cancelled; that one line is not sent.
        XCTAssertEqual(events.messages, Array(expected.prefix(events.messages.count)))
        XCTAssertLessThanOrEqual(expected.count - events.messages.count, 1)
        XCTAssertEqual(Set(events.messages).count, events.messages.count, "nothing repeated")
        XCTAssertEqual(icli.filters.first?.subsystem, "wiki.qaq.steady", "icli filters the subsystem itself")
        XCTAssertFalse(events.items.contains { $0.0 == "truncated" })
    }

    func testCancelStopsTheStreamAtOnce() throws {
        let icli = TimelineIcli()
        icli.start(period: 0.01)
        defer { icli.stop() }
        let pump = LogStreamPump(source: Diagnostics(icli: icli))
        let events = Events()
        try pump.start(LogStreamRequest(filter: ApelinProtocol.LogFilter(windowSeconds: 30)), taskID: TaskID("c"), emit: events.emit, finish: events.finish)
        Thread.sleep(forTimeInterval: 0.5)
        let cancelled = Date()
        pump.cancel(TaskID("c"))
        XCTAssertEqual(events.done.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
        XCTAssertEqual(events.end?.0, .cancelled)
        XCTAssertEqual(icli.stream?.isFinished, true, "icli's stream was cancelled")
        let count = events.messages.count
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(events.messages.count, count, "nothing is emitted after the end")
    }

    func testALimitEndsTheStreamTruncated() throws {
        let icli = TimelineIcli()
        icli.start(period: 0.005)
        defer { icli.stop() }
        let events = try stream(icli, filter: ApelinProtocol.LogFilter(limit: 25, windowSeconds: 30))
        XCTAssertEqual(events.end?.0, .succeeded)
        XCTAssertEqual(events.messages.count, 25)
        XCTAssertEqual(events.items.last?.0, "truncated")
        XCTAssertNil(events.items.last?.1?["reason"])
    }

    /// The system ending the stream at once, before anything matched, is a
    /// refusal: `denied`, so the host turns to the root reader.
    func testAStreamEndedAtOnceIsDenied() {
        let icli = TimelineIcli()
        icli.interruptAfter = 0.05
        let pump = LogStreamPump(source: Diagnostics(icli: icli))
        XCTAssertThrowsError(try pump.start(LogStreamRequest(filter: ApelinProtocol.LogFilter(windowSeconds: 5)), taskID: TaskID("d"), emit: { _, _ in }, finish: { _, _ in })) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .denied)
        }
    }

    /// Ended by the system later, the stream lost the rest of its window and
    /// says so.
    func testAStreamEndedLaterIsTruncatedBySource() throws {
        let icli = TimelineIcli()
        icli.interruptAfter = 1.5
        icli.start(period: 0.01)
        defer { icli.stop() }
        let events = try stream(icli, filter: ApelinProtocol.LogFilter(windowSeconds: 10))
        XCTAssertEqual(events.end?.0, .succeeded)
        XCTAssertGreaterThan(events.messages.count, 0)
        XCTAssertEqual(events.items.last?.0, "truncated")
        XCTAssertEqual(events.items.last?.1?["reason"]?.stringValue, "source")
    }

    private func stream(_ icli: TimelineIcli, filter: ApelinProtocol.LogFilter) throws -> Events {
        let pump = LogStreamPump(source: Diagnostics(icli: icli))
        let events = Events()
        try pump.start(LogStreamRequest(filter: filter), taskID: TaskID("s"), emit: events.emit, finish: events.finish)
        XCTAssertEqual(events.done.wait(timeout: .now() + (filter.windowSeconds ?? 30) + 10), .success)
        return events
    }
}
