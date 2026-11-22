import ApelinDiagnosticsCore
@testable import ConfirmLoaded
import XCTest

final class InjectionFilterTests: XCTestCase {
    private func filter(_ text: String) throws -> InjectionFilter {
        try InjectionFilter(data: Data(text.utf8))
    }

    private let springBoard = FilterTarget(bundleIdentifier: "com.apple.springboard", executableName: "SpringBoard")

    func testApelinHelloSelectsSpringBoard() throws {
        // The research tweak's plist, verbatim.
        let hello = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); }; }"#)
        XCTAssertEqual(hello.bundles, ["com.apple.springboard"])
        XCTAssertEqual(hello.evaluate(for: springBoard).verdict, .matches)
        let settings = FilterTarget(bundleIdentifier: "com.apple.Preferences", executableName: "Preferences")
        XCTAssertEqual(hello.evaluate(for: settings).verdict, .doesNotMatch)
    }

    func testAFrameworkBundleIsUndetermined() throws {
        let uikit = try filter(#"{ Filter = { Bundles = ( "com.apple.UIKit" ); }; }"#)
        XCTAssertEqual(uikit.evaluate(for: springBoard).verdict, .undetermined)
    }

    func testExecutablesAndModes() throws {
        let both = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); Executables = ( "backboardd" ); }; }"#)
        XCTAssertEqual(both.evaluate(for: springBoard).verdict, .doesNotMatch, "every key must match")
        let any = try filter(#"{ Filter = { Mode = Any; Bundles = ( "com.apple.springboard" ); Executables = ( "backboardd" ); }; }"#)
        XCTAssertEqual(any.evaluate(for: springBoard).verdict, .matches)
        let backboardd = FilterTarget(bundleIdentifier: nil, executableName: "backboardd")
        XCTAssertEqual(any.evaluate(for: backboardd).verdict, .matches)
    }

    func testClassesAreOnlyKnowableInside() throws {
        let classes = try filter(#"{ Filter = { Classes = ( "SBIconController" ); }; }"#)
        XCTAssertEqual(classes.evaluate(for: springBoard).verdict, .undetermined)
        let anyWithHit = try filter(#"{ Filter = { Mode = Any; Classes = ( "X" ); Executables = ( "SpringBoard" ); }; }"#)
        XCTAssertEqual(anyWithHit.evaluate(for: springBoard).verdict, .matches)
    }

    func testCoreFoundationVersionRange() throws {
        let ranged = try filter(#"{ Filter = { Bundles = ( "com.apple.springboard" ); CoreFoundationVersion = ( 1900, 2000 ); }; }"#)
        var target = springBoard
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .undetermined, "version not known")
        target.coreFoundationVersion = 1953.1
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .matches)
        target.coreFoundationVersion = 2000
        XCTAssertEqual(ranged.evaluate(for: target).verdict, .doesNotMatch, "max is exclusive")
    }

    func testNoFilterAndEmptyFilter() throws {
        XCTAssertEqual(try filter("{ }").evaluate(for: springBoard).verdict, .matches)
        XCTAssertFalse(try filter("{ }").hasFilter)
        XCTAssertEqual(try filter("{ Filter = { }; }").evaluate(for: springBoard).verdict, .matches)
        XCTAssertEqual(try filter("{ Filter = { Mode = Any; }; }").evaluate(for: springBoard).verdict, .doesNotMatch)
    }

    func testXMLPlistsParseToo() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Filter</key><dict><key>Executables</key>
        <array><string>SpringBoard</string></array></dict></dict></plist>
        """
        XCTAssertEqual(try filter(xml).evaluate(for: springBoard).verdict, .matches)
    }

    func testNonsenseIsRefused() {
        XCTAssertThrowsError(try filter("not a plist {{{"))
        XCTAssertThrowsError(try filter("( a, b )"))
        XCTAssertThrowsError(try filter("{ Filter = ( a ); }"))
        XCTAssertThrowsError(try InjectionFilter(data: Data(count: InjectionFilter.maximumBytes + 1)))
    }
}

/// A live log that hands over `entries` as the listen begins, then stays
/// open until its deadline, unless `dropped` has the system end it first.
private struct FakeLogs: LiveLogSource {
    var entries: [LogEntry]
    var error: DiagnosticsError?
    var dropped = false

    func listen(
        _: LogFilter,
        until deadline: Date,
        deliver: @escaping @Sendable (LogEntry) -> Bool,
    ) throws -> LiveLogListener {
        if let error {
            throw error
        }
        let listener = LiveLogListener(deadline: deadline, deliver: deliver)
        for entry in entries where !listener.offer(entry) {
            break
        }
        if dropped {
            listener.markDropped()
            listener.finish()
        }
        return listener
    }
}

/// The process list, one answer per look, the last one repeated.
private final class FakeProcesses: ProcessListSource, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[ProcessRow]]
    private(set) var looks = 0
    var failure: DiagnosticsError?
    /// Looks that answer before `failure` is thrown.
    var answeredLooks = 0

    init(_ answers: [[ProcessRow]]) {
        self.answers = answers
    }

    func processes() throws -> [ProcessRow] {
        lock.lock()
        defer { lock.unlock() }
        if let failure, looks >= answeredLooks {
            throw failure
        }
        looks += 1
        return answers.count > 1 ? answers.removeFirst() : answers.first ?? []
    }
}

private func row(_ pid: Int32, _ executable: String) -> ProcessRow {
    ProcessRow(pid: pid, name: String(executable.prefix(16)), executable: "/usr/libexec/\(executable)", bundleIdentifier: "")
}

final class ConfirmLoadedTests: XCTestCase {
    private func request(window: TimeInterval = 1) -> LoadConfirmationRequest {
        LoadConfirmationRequest(
            marker: "ApelinHello: loaded into",
            targetExecutable: "SpringBoard",
            targetBundleIdentifier: "com.apple.springboard",
            dylibPath: "/var/jb/Library/MobileSubstrate/DynamicLibraries/ApelinHello.dylib",
            filterPlist: Data(#"{ Filter = { Bundles = ( "com.apple.springboard" ); }; }"#.utf8),
            logWindow: window,
        )
    }

    private func line(_ process: String, _ pid: Int32, _ message: String) -> LogEntry {
        LogEntry(date: Date(), process: process, pid: pid, subsystem: "", category: "", level: .default, message: message)
    }

    func testTheMarkerAndFilterConfirmAfterTheTrigger() {
        let triggered = Flag()
        let stages = Stages()
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [
            line("SpringBoardHelper", 801, "ApelinHello: loaded into SpringBoardHelper"),
            line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard"),
        ]))
        let result = confirm.run(request(), trigger: { triggered.set() }, stage: stages.append)
        XCTAssertTrue(triggered.value)
        XCTAssertEqual(stages.values, [.listening, .trigger])
        XCTAssertEqual(result.marker.status, .confirmed)
        XCTAssertEqual(result.marker.detail, "Marker logged by pid 1200.", "another process's marker does not count")
        XCTAssertEqual(result.filter.status, .confirmed)
        XCTAssertNil(result.triggerFailure)
        XCTAssertTrue(result.isLoaded, "the marker is the evidence")
    }

    func testTheImageListIsNeverRead() {
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard")]))
        let result = confirm.run(request())
        XCTAssertEqual(result.image.status, .notRead)
        // An agent on iOS 17 took "the iOS 27 kernel" for a rule about
        // another system.
        XCTAssertTrue(result.image.detail.contains("on any iOS version"), result.image.detail)
        XCTAssertNil(result.image.detail.range(of: #"iOS \d"#, options: .regularExpression), result.image.detail)
    }

    func testEachEvidenceFailsOnItsOwn() {
        struct RespringFailed: Error {}
        let confirm = ConfirmLoaded(logs: FakeLogs(entries: [line("SpringBoard", 1200, "something else")]))
        var request = request()
        request.targetBundleIdentifier = "com.apple.Preferences"
        let result = confirm.run(request) { throw RespringFailed() }
        XCTAssertEqual(result.marker.status, .absent)
        XCTAssertEqual(result.filter.status, .absent)
        XCTAssertNotNil(result.triggerFailure)
        XCTAssertFalse(result.isLoaded)
    }

    func testMissingSourcesAreUnavailableNotAbsent() {
        var request = request()
        request.filterPlist = nil
        let result = ConfirmLoaded(logs: FakeLogs(entries: [])).run(request)
        XCTAssertEqual(result.filter.status, .unavailable)

        let failingLogs = ConfirmLoaded(logs: FakeLogs(entries: [], error: .unavailable("no stream")))
        XCTAssertEqual(failingLogs.run(self.request()).marker.status, .unavailable)
        XCTAssertNil(failingLogs.run(self.request()).process, "no process list was given")
    }

    /// A stream the system ended before the window did heard only part of
    /// it: a miss there proves nothing.
    func testALostStreamIsNoMiss() {
        let result = ConfirmLoaded(logs: FakeLogs(entries: [], dropped: true)).run(request(window: 30))
        XCTAssertEqual(result.marker.status, .unavailable)
        XCTAssertTrue(result.marker.detail.hasPrefix("The system ended the log stream"), result.marker.detail)
    }

    /// A long window costs a hit nothing.
    func testTheListenEndsWithTheMarker() {
        let started = Date()
        let result = ConfirmLoaded(logs: FakeLogs(entries: [line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard")]))
            .run(request(window: 600))
        XCTAssertTrue(result.isLoaded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    /// The process list, looked at as the check begins and as it listens:
    /// a respring shows as SpringBoard starting again, and a target that
    /// never ran is said so.
    func testTheTargetProcessIsWatched() throws {
        let respring = FakeProcesses([[row(55, "SpringBoard")], [row(55, "SpringBoard")], [row(1200, "SpringBoard")]])
        let restarted = ConfirmLoaded(logs: FakeLogs(entries: []), processes: respring, lookInterval: 0.05)
            .run(request(window: 0.5))
        let seen = try XCTUnwrap(restarted.process)
        XCTAssertEqual(seen.status, .confirmed)
        XCTAssertEqual(seen.runningAtStart, [55])
        XCTAssertEqual(seen.startedDuring, [1200])
        XCTAssertEqual(seen.detail, "SpringBoard was running when the check began (pid 55) and started again during it (pid 1200).")
        XCTAssertGreaterThan(respring.looks, 3)
        XCTAssertFalse(restarted.isLoaded, "a process that ran is not a tweak that loaded")

        let never = ConfirmLoaded(logs: FakeLogs(entries: []), processes: FakeProcesses([[row(55, "SpringBoard")]]), lookInterval: 0.05)
        var daemon = request(window: 0.5)
        daemon.targetExecutable = "dtremotedisplayd"
        let absent = never.run(daemon).process
        XCTAssertEqual(absent?.status, .absent)
        XCTAssertEqual(absent?.runningAtStart, [])
        XCTAssertEqual(absent?.startedDuring, [])
        XCTAssertTrue(absent?.detail.hasPrefix("No process named dtremotedisplayd ran while the check looked") == true, absent?.detail ?? "")
    }

    /// A pid that logged the marker ran, though no look caught it.
    func testThePidThatLoggedTheMarkerRan() {
        let result = ConfirmLoaded(
            logs: FakeLogs(entries: [line("SpringBoard", 1300, "ApelinHello: loaded into SpringBoard")]),
            processes: FakeProcesses([[]]),
        ).run(request(window: 600))
        XCTAssertEqual(result.process?.status, .confirmed)
        XCTAssertEqual(result.process?.startedDuring, [1300])
    }

    /// A list that cannot be read is said so, and the marker still counts.
    func testAnUnreadableProcessListIsUnavailable() {
        let processes = FakeProcesses([[row(55, "SpringBoard")]])
        processes.failure = .unavailable("sysctl refused")
        let result = ConfirmLoaded(
            logs: FakeLogs(entries: [line("SpringBoard", 1200, "ApelinHello: loaded into SpringBoard")]),
            processes: processes,
        ).run(request())
        XCTAssertEqual(result.process?.status, .unavailable)
        XCTAssertEqual(result.process?.detail, "The process list could not be read: sysctl refused")
        XCTAssertTrue(result.isLoaded)

        // Read when the check began, not later: a target never seen says
        // how many looks saw nothing at all.
        let later = FakeProcesses([[row(55, "SpringBoard")]])
        later.failure = .unavailable("sysctl refused")
        later.answeredLooks = 1
        var daemon = request(window: 0.5)
        daemon.targetExecutable = "dtremotedisplayd"
        let missed = ConfirmLoaded(logs: FakeLogs(entries: []), processes: later, lookInterval: 0.05).run(daemon).process
        XCTAssertEqual(missed?.status, .absent)
        XCTAssertTrue(missed?.detail.contains("of those looks could not read the list.") == true, missed?.detail ?? "")
    }

    /// A check stopped before it triggers does not respring, and its listen,
    /// however long, ends at once.
    func testAStoppedCheckEndsAtOnceWithoutItsTrigger() {
        let stop = LoadCheckStop()
        stop.stop()
        let triggered = Flag()
        let stages = Stages()
        let started = Date()
        let result = ConfirmLoaded(logs: FakeLogs(entries: [])).run(
            request(window: 600),
            trigger: { triggered.set() },
            stage: { stages.append($0) },
            stop: stop,
        )
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertFalse(triggered.value)
        XCTAssertEqual(stages.values, [.listening])
        XCTAssertFalse(result.isLoaded)

        // Stopped from another thread while it listens.
        let listening = LoadCheckStop()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { listening.stop() }
        let begun = Date()
        _ = ConfirmLoaded(logs: FakeLogs(entries: [])).run(request(window: 600), stop: listening)
        XCTAssertLessThan(Date().timeIntervalSince(begun), 2)
    }
}

private final class Stages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ConfirmLoaded.Stage] = []
    func append(_ stage: ConfirmLoaded.Stage) {
        lock.lock(); stored.append(stage); lock.unlock()
    }

    var values: [ConfirmLoaded.Stage] {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() {
        lock.lock(); stored = true; lock.unlock()
    }

    var value: Bool {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}
