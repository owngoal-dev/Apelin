import ApelinCore
import ApelinDiagnostics
@testable import ApelinDiagnosticsWorker
@testable import ApelinLogReaderWorker
import ApelinProtocol
import ConfirmLoaded
import Foundation
import XCTest

/// icli in icli's own shapes: a bounded read hands out one batch, a stream
/// hears every batch's lines as soon as it opens.
private final class FakeIcli: IcliSurface, @unchecked Sendable {
    let lock = NSLock()
    var batches: [[[String: Any]]] = []
    var crashes: [String] = []
    var front: [String: Any] = ["bundle_id": "com.apple.springboard", "verified": true, "source": "runningboard"]
    /// Answers for `frontmostApp` before `front`, one per call.
    var fronts: [[String: Any]] = []
    var taps: [(Double, Double)] = []
    var elementTaps: [(String?, String?)] = []
    var lockAnswer: [String: Any] = ["locked": false, "screen_off": false]
    /// What a wake answers; every press, by icli's name.
    var wakeAnswer: [String: Any] = ["button": "wake", "locked": false, "screen_off": false]
    var presses: [String] = []
    /// The dispatch queue each `frontmostApp` call ran on.
    var frontQueues: [String] = []

    func captureSyslog(seconds _: Double, filter _: IcliSyslogFilter, maxLines _: Int) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let next = batches.isEmpty ? [] : batches.removeFirst()
        return ["entries": next, "truncated": false]
    }

    func openSyslogStream(
        filter _: IcliSyslogFilter,
        seconds: Double,
        handler: @escaping @Sendable (LogEntry) -> Bool,
        onEnd: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream {
        let lines = lock.withLock { batches.flatMap(\.self) }
        let entries = lines.map { row in
            LogEntry(
                date: (row["date"] as? String).flatMap(ISO8601DateFormatter().date(from:)),
                process: row["process"] as? String ?? "",
                pid: Int32(row["pid"] as? Int ?? 0),
                subsystem: row["subsystem"] as? String ?? "",
                category: row["category"] as? String ?? "",
                level: LogLevel(icliName: row["level"] as? String ?? ""),
                message: row["message"] as? String ?? "",
            )
        }
        let stream = FakeSyslogStream(seconds: seconds, handler: handler, onEnd: onEnd)
        DispatchQueue.global().async { entries.forEach(stream.offer) }
        return stream
    }

    func crashLogs(bundleID _: String?) throws -> [String: Any] {
        ["crashes": crashes]
    }

    func readCrashLog(_: String, maxBytes _: Int) throws -> [String: Any] {
        throw DiagnosticsError.unavailable("no")
    }

    func takeScreenshot() throws -> [String: Any] {
        ["data": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(), "width": 3, "height": 4, "coordinate_scale": 1]
    }

    func uiElements(maxElements _: Int, visibleOnly _: Bool, clickableOnly _: Bool) throws -> [String: Any] {
        ["pid": 42, "elements": [["label": "OK", "identifier": "ok", "role": "button", "frame": ["x": 1, "y": 2, "width": 3, "height": 4]]]]
    }

    func tap(x: Double, y: Double) throws -> [String: Any] {
        taps.append((x, y)); return [:]
    }

    func tapElement(text: String?, identifier: String?, role _: String?, match _: String, index _: Int) throws -> [String: Any] {
        elementTaps.append((text, identifier)); return [:]
    }

    func waitForElement(
        text _: String?,
        identifier _: String?,
        role _: String?,
        match _: String,
        index _: Int,
        appear: Bool,
        timeout _: Double,
        interval _: Double,
    ) throws -> [String: Any] {
        ["found": appear]
    }

    func swipe(x1 _: Double, y1 _: Double, x2 _: Double, y2 _: Double, seconds _: Double) throws -> [String: Any] {
        [:]
    }

    func typeText(_: String, delayMS _: Double) throws -> [String: Any] {
        [:]
    }

    func pressButton(_ name: String) throws -> [String: Any] {
        presses.append(name)
        return name == "wake" ? wakeAnswer : ["button": name]
    }

    func frontmostApp() -> [String: Any] {
        let queue = String(cString: __dispatch_queue_get_label(nil))
        return lock.withLock {
            frontQueues.append(queue)
            return fronts.isEmpty ? front : fronts.removeFirst()
        }
    }

    func lockState() -> [String: Any] {
        lockAnswer
    }

    func screenInfo() -> [String: Any] {
        ["width": 430, "height": 932, "locked": lockAnswer["locked"] ?? false, "screen_off": lockAnswer["screen_off"] ?? false]
    }

    func runningApps() throws -> [String: Any] {
        ["apps": [["pid": 77, "name": "Preferences", "executable": "/Applications/Preferences.app/Preferences", "bundle_id": "com.apple.Preferences"]]]
    }

    func respring() throws -> [String: Any] {
        ["method": "frontboard_relaunch", "previous_pid": 1, "pid": 2]
    }
}

private struct NoHost: ApelinTransport {
    func call(_ request: WireRequest, descriptors _: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        (.failure(request.requestID, .unimplemented(request.operation)), [])
    }
}

/// A host that answers the respring and remembers it was asked.
private final class RespringHost: ApelinTransport, @unchecked Sendable {
    let lock = NSLock()
    var operations: [AppOperation] = []
    func call(_ request: WireRequest, descriptors _: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        lock.withLock { operations.append(request.operation) }
        guard request.operation == .respring else { return (.failure(request.requestID, .unimplemented(request.operation)), []) }
        return (.success(request.requestID, Acknowledged()), [])
    }
}

/// A task's events as the host would number them, with a wait for the end.
private final class TaskEvents: @unchecked Sendable {
    let lock = NSLock()
    var items: [(TaskID, String, JSONValue?)] = []
    let done = DispatchSemaphore(value: 0)
    func emit(_ taskID: TaskID, _ kind: String, _ payload: JSONValue?) {
        lock.lock(); items.append((taskID, kind, payload)); lock.unlock()
        if kind == TaskEvent.stateKind {
            done.signal()
        }
    }

    var all: [(TaskID, String, JSONValue?)] {
        lock.lock(); defer { lock.unlock() }; return items
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
}

final class DiagnosticsWorkerTests: XCTestCase {
    private func line(_ message: String, process: String = "SpringBoard", subsystem: String = "wiki.qaq.hello") -> [String: Any] {
        ["date": "2026-10-17T10:00:00Z", "process": process, "pid": 55, "subsystem": subsystem, "category": "tweak", "level": "notice", "message": message]
    }

    func testLogStreamEmitsFilteredLinesAndEndsWithItsWindow() throws {
        let icli = FakeIcli()
        icli.batches = [[line("ApelinLoaded B-1 in SpringBoard"), line("other", subsystem: "com.apple.x")], [line("second")]]
        let pump = LogStreamPump(source: Diagnostics(icli: icli))
        let events = Events()
        try pump.start(
            LogStreamRequest(filter: ApelinProtocol.LogFilter(subsystem: "wiki.qaq.hello", windowSeconds: 1)),
            taskID: TaskID("t"),
            emit: events.emit,
            finish: events.finish,
        )
        XCTAssertEqual(events.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(events.end?.0, .succeeded)
        let messages = events.items.filter { $0.0 == "log" }.compactMap { $0.1?["message"]?.stringValue }
        XCTAssertEqual(messages.first, "ApelinLoaded B-1 in SpringBoard")
        XCTAssertFalse(messages.contains("other"))
    }

    func testLogStreamStopsAtItsLimit() throws {
        let icli = FakeIcli()
        icli.batches = [[line("a"), line("b"), line("c")]]
        let pump = LogStreamPump(source: Diagnostics(icli: icli))
        let events = Events()
        try pump.start(LogStreamRequest(filter: ApelinProtocol.LogFilter(limit: 2, windowSeconds: 30)), taskID: TaskID("t"), emit: events.emit, finish: events.finish)
        XCTAssertEqual(events.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(events.items.filter { $0.0 == "log" }.count, 2)
        XCTAssertEqual(events.items.last?.0, "truncated")
    }

    func testLogStreamRefusesWhatTheSourceCannotReadAsDenied() {
        let pump = LogStreamPump(source: Diagnostics(icli: UnavailableIcli()))
        XCTAssertThrowsError(try pump.start(LogStreamRequest(filter: ApelinProtocol.LogFilter(windowSeconds: 5)), taskID: TaskID("t"), emit: { _, _ in }, finish: { _, _ in })) { error in
            XCTAssertEqual((error as? ApelinError)?.code, .denied)
        }
    }

    func testLogFilterBoundsAreTheWires() {
        XCTAssertThrowsError(try LogStreamPump.window(ApelinProtocol.LogFilter(windowSeconds: 601)))
        XCTAssertThrowsError(try LogStreamPump.limit(ApelinProtocol.LogFilter(limit: 0)))
        XCTAssertThrowsError(try LogStreamPump.filter(ApelinProtocol.LogFilter(level: "loud"), duration: 1, maxEntries: 1))
        XCTAssertEqual(try LogStreamPump.filter(ApelinProtocol.LogFilter(level: "error"), duration: 1, maxEntries: 1).minimumLevel, .error)
    }

    func testLoadPlanFromTheTweakTemplate() throws {
        let manifest = try JSONCoding.decode(JSONValue.self, from: Data("""
        {"projectID": "p", "package": {"id": "wiki.qaq.hello",
          "layout": [{"path": "/Library/MobileSubstrate/DynamicLibraries/Hello.dylib", "product": "tweak"}],
          "tweakFilter": {"dylib": "tweak", "bundles": ["com.apple.springboard"]}}}
        """.utf8))
        let rootless = try LoadPlan.from(manifest: manifest, buildID: "B-1", installRoot: "/var/jb")
        XCTAssertEqual(rootless.marker, "ApelinLoaded B-1")
        XCTAssertEqual(rootless.subsystem, "wiki.qaq.hello")
        XCTAssertEqual(rootless.dylibPath, "/var/jb/Library/MobileSubstrate/DynamicLibraries/Hello.dylib")
        let filter = try XCTUnwrap(rootless.filterPlist)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: filter, format: nil) as? [String: [String: [String]]])
        XCTAssertEqual(plist["Filter"]?["Bundles"], ["com.apple.springboard"])
        XCTAssertEqual(try LoadPlan.from(manifest: manifest, buildID: "B-1", installRoot: "/").dylibPath, "/Library/MobileSubstrate/DynamicLibraries/Hello.dylib")
    }

    /// A project folder with the tweak template's manifest and an installed
    /// dylib under a fake install root.
    private func makeProject() throws -> (home: URL, root: URL, dylib: URL) {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-diag-\(UUID().uuidString)")
        let project = home.appendingPathComponent("Documents/wiki.qaq.apelin/Projects/Hello")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let root = home.appendingPathComponent("jb")
        let dylibFolder = root.appendingPathComponent("Library/MobileSubstrate/DynamicLibraries")
        try FileManager.default.createDirectory(at: dylibFolder, withIntermediateDirectories: true)
        let dylib = dylibFolder.appendingPathComponent("Hello.dylib")
        FileManager.default.createFile(atPath: dylib.path, contents: Data([0]))
        try """
        {"projectID": "proj-1", "package": {"id": "wiki.qaq.hello",
          "layout": [{"path": "/Library/MobileSubstrate/DynamicLibraries/Hello.dylib", "product": "tweak"}],
          "tweakFilter": {"dylib": "tweak", "bundles": ["com.apple.springboard"]}}}
        """.write(to: project.appendingPathComponent("apelin-project.json"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, root, dylib)
    }

    /// Reading another process's image list panicked the iOS 27 kernel, the
    /// second time through the region-path walk alone: a request that asks
    /// is the reply, before a task exists, and nothing is emitted.
    func testConfirmLoadedRefusesAnImageCheckBeforeTheTaskIsAccepted() async throws {
        let (home, root, _) = try makeProject()
        let events = TaskEvents()
        let service = DiagnosticsService(
            diagnostics: Diagnostics(icli: FakeIcli()),
            host: ApelinService(transport: NoHost()),
            home: home.path,
            installRoot: root.path,
            emit: events.emit,
        )
        let request = ApelinProtocol.ConfirmLoadedRequest(
            buildID: "B-1",
            targetID: "SpringBoard",
            projectID: "proj-1",
            logWindowSeconds: 1,
            imageCheck: .regionPaths,
        )
        do {
            try await service.startConfirmLoaded(request, taskID: TaskID("confirm-refused"))
            XCTFail("an image check was accepted")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
            XCTAssertTrue(error.message.contains("on every iOS version"), error.message)
            XCTAssertNil(error.message.range(of: #"iOS \d"#, options: .regularExpression), error.message)
        }
        XCTAssertTrue(events.all.isEmpty, "a refused request starts nothing")
    }

    func testConfirmLoadedReportsEachEvidenceApartAndNeverReadsTheImageList() async throws {
        let (home, root, _) = try makeProject()
        let icli = FakeIcli()
        icli.batches = [[line("nothing to see")]]
        let service = DiagnosticsService(
            diagnostics: Diagnostics(icli: icli),
            host: ApelinService(transport: NoHost()),
            home: home.path,
            installRoot: root.path,
        )
        let response = try await service.confirmLoaded(ApelinProtocol.ConfirmLoadedRequest(buildID: "B-1", targetID: "SpringBoard", projectID: "proj-1", logWindowSeconds: 1))
        XCTAssertFalse(response.loaded)
        XCTAssertEqual(response.evidence.map(\.kind), ["log", "image", "filter"])
        XCTAssertEqual(response.evidence.map(\.passed), [false, false, true])
        XCTAssertTrue(response.evidence[0].detail.hasPrefix("absent"))
        XCTAssertTrue(response.evidence[1].detail.hasPrefix("notRead:"), response.evidence[1].detail)
        XCTAssertNil(response.evidence[1].detail.range(of: #"iOS \d"#, options: .regularExpression), response.evidence[1].detail)
    }

    /// The task: accepted at once, then `stage` events, the host's respring,
    /// and the answer in the final `state` — none of it needing an attach.
    func testConfirmLoadedIsATaskThatRespringsThroughTheHostAndAnswersInItsFinalState() async throws {
        let (home, root, _) = try makeProject()
        let icli = FakeIcli()
        icli.batches = [[line("ApelinLoaded B-1 in SpringBoard")]]
        let host = RespringHost()
        let events = TaskEvents()
        let service = DiagnosticsService(
            diagnostics: Diagnostics(icli: icli),
            host: ApelinService(transport: host),
            home: home.path,
            installRoot: root.path,
            emit: events.emit,
        )
        let taskID = TaskID("confirm-1")
        try await service.startConfirmLoaded(ApelinProtocol.ConfirmLoadedRequest(buildID: "B-1", targetID: "SpringBoard", projectID: "proj-1", trigger: .respring, logWindowSeconds: 1), taskID: taskID)
        XCTAssertEqual(events.done.wait(timeout: .now() + 10), .success)

        let all = events.all
        XCTAssertTrue(all.allSatisfy { $0.0 == taskID })
        XCTAssertEqual(all.filter { $0.1 == "stage" }.compactMap { $0.2?["stage"]?.stringValue }, ["listening", "trigger"])
        XCTAssertEqual(host.operations, [.respring], "the respring is the host's")
        let final = try XCTUnwrap(all.last)
        XCTAssertEqual(final.1, TaskEvent.stateKind)
        let answer = try ApelinProtocol.ConfirmLoadedResponse.from(finalState: TaskEvent(seq: EventSeq(UInt64(all.count)), kind: final.1, payload: final.2))
        XCTAssertTrue(answer.loaded)
        XCTAssertEqual(answer.evidence.map(\.kind), ["log", "image", "filter"])
        XCTAssertTrue(answer.evidence[1].detail.hasPrefix("notRead:"))
    }

    func testABadLoadCheckIsTheReplyNotAFailedTask() async throws {
        let events = TaskEvents()
        let service = DiagnosticsService(diagnostics: Diagnostics(icli: FakeIcli()), host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/", emit: events.emit)
        for bad in [
            ApelinProtocol.ConfirmLoadedRequest(buildID: "", targetID: "SpringBoard"),
            ApelinProtocol.ConfirmLoadedRequest(buildID: "B-1", targetID: "SpringBoard", logWindowSeconds: 0),
            ApelinProtocol.ConfirmLoadedRequest(buildID: "B-1", targetID: "../SpringBoard"),
        ] {
            do {
                try await service.startConfirmLoaded(bad, taskID: TaskID("t"))
                XCTFail("accepted \(bad)")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .badRequest)
            }
        }
        XCTAssertTrue(events.all.isEmpty, "nothing ran")
    }

    func testUIActionsAreTheClosedListAndBoundToTheForegroundApp() throws {
        let icli = FakeIcli()
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleTimeout = 0.05
        diagnostics.settleInterval = 0.01
        let service = DiagnosticsService(diagnostics: diagnostics, host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/")
        XCTAssertEqual(try DiagnosticsService.action(.tap(x: 1, y: 2)), .tap(UIPoint(x: 1, y: 2)))
        XCTAssertEqual(try DiagnosticsService.action(.tapElement(text: "OK", identifier: nil)), .tapElement(UIElementSelector(text: "OK", match: .exact)))
        XCTAssertEqual(try DiagnosticsService.action(.press(button: "wake")), .press(.wake))
        XCTAssertEqual(try DiagnosticsService.action(.press(button: "home")), .press(.home))
        XCTAssertEqual(try DiagnosticsService.action(.press(button: "lock")), .press(.lock))
        for unknown in ["power", "volume_up", "Home", ""] {
            XCTAssertThrowsError(try DiagnosticsService.action(.press(button: unknown)), unknown) { error in
                XCTAssertEqual((error as? ApelinError)?.code, .badRequest)
            }
        }
        XCTAssertNoThrow(try service.requireTarget("com.apple.springboard"))
        XCTAssertThrowsError(try service.requireTarget("com.apple.Preferences")) { error in
            XCTAssertEqual(
                error as? ApelinError,
                ApelinError(.conflict, "com.apple.Preferences is not the verified foreground app after 0 s (com.apple.springboard)"),
            )
        }
    }

    /// Characters sent with no gap were dropped: "Hello world" arrived as
    /// "Hello wrd". A `type` goes at icli's own pace.
    func testTextIsTypedAtIclisPace() throws {
        XCTAssertEqual(try DiagnosticsService.action(.type(text: "hi")), .type(text: "hi", delayMilliseconds: 30))
    }

    /// Two reads of the app a switch is leaving do not refuse an action
    /// bound to the app it is switching to: the target is waited for.
    func testATargetIsWaitedForWhileTheAppItLeavesIsStillInFront() throws {
        let icli = FakeIcli()
        let apelin: [String: Any] = ["bundle_id": "wiki.qaq.apelin", "verified": true, "source": "runningboard"]
        icli.fronts = [apelin, apelin]
        icli.front = ["bundle_id": "wiki.qaq.fila", "verified": true, "source": "runningboard"]
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0.01
        let service = DiagnosticsService(diagnostics: diagnostics, host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/")
        XCTAssertEqual(try service.requireTarget("wiki.qaq.fila")?.bundleIdentifier, "wiki.qaq.fila")
    }

    /// A `type` answers what the tree holds once the text has gone in; the
    /// fake's tree never changes, so no field holds it.
    func testATypeAnswersWhatTheFieldsHold() async throws {
        var diagnostics = Diagnostics(icli: FakeIcli())
        diagnostics.settleInterval = 0.01
        let service = DiagnosticsService(diagnostics: diagnostics, host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/")
        let typed = try await service.uiAction(.init(action: .type(text: "Hello world")))
        XCTAssertEqual(typed, ApelinProtocol.UIActionResponse(typedTextMatches: false, fieldValues: []))
        let tapped = try await service.uiAction(.init(action: .tap(x: 1, y: 2)))
        XCTAssertEqual(tapped, ApelinProtocol.UIActionResponse())
    }

    /// A targeted UI read or element tap settles the foreground once, and
    /// the polling runs off the cooperative pool.
    func testATargetedUIRequestSettlesTheForegroundOnceOffThePool() async throws {
        let icli = FakeIcli()
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0.01
        let service = DiagnosticsService(
            diagnostics: diagnostics,
            host: ApelinService(transport: NoHost()),
            home: "/nonexistent",
            installRoot: "/",
        )
        let requests: [(String, () async throws -> Void)] = [
            ("readUITree", { _ = try await service.readUITree(.init(targetID: "com.apple.springboard")) }),
            ("tapElement", {
                _ = try await service.uiAction(.init(
                    targetID: "com.apple.springboard",
                    action: .tapElement(text: "OK", identifier: nil),
                ))
            }),
        ]
        for (name, request) in requests {
            icli.lock.withLock { icli.frontQueues = [] }
            try await request()
            let queues = icli.lock.withLock { icli.frontQueues }
            XCTAssertEqual(queues.count, 2, "\(name): one settle is two matching reads")
            XCTAssertFalse(queues.contains { $0.contains("cooperative") }, "\(name): \(queues)")
        }
    }

    /// On a dark screen only a wake goes through, and its answer says what
    /// it left; the refusal of anything else says it is the screen.
    func testAWakeAnswersTheLockStateAndIsAllADarkScreenTakes() async throws {
        let icli = FakeIcli()
        icli.lockAnswer = ["locked": true, "screen_off": true]
        icli.wakeAnswer = ["button": "wake", "locked": true, "screen_off": false]
        let service = DiagnosticsService(diagnostics: Diagnostics(icli: icli), host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/")
        let woken = try await service.uiAction(.init(action: .press(button: "wake")))
        XCTAssertEqual(woken, ApelinProtocol.UIActionResponse(locked: true, screenOff: false))
        for action in [ApelinProtocol.UIAction.press(button: "home"), .tap(x: 1, y: 2)] {
            do {
                _ = try await service.uiAction(.init(action: action))
                XCTFail("\(action) ran on a dark screen")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .conflict)
                XCTAssertTrue(error.message.hasPrefix("The screen is off."), error.message)
            }
        }
        XCTAssertEqual(icli.presses, ["wake"])
        XCTAssertTrue(icli.taps.isEmpty)

        icli.lockAnswer = ["locked": false, "screen_off": false]
        let tapped = try await service.uiAction(.init(action: .tap(x: 1, y: 2)))
        XCTAssertEqual(tapped, ApelinProtocol.UIActionResponse(), "only a wake answers the lock state")
    }

    /// An agent's actions name Apelin as refused (the host sets the list):
    /// named as the target it is refused before anything is read, and in
    /// front, verified or not, on the settled read the action would have
    /// gone by, with no target too. Without the list (the app, the console)
    /// the same tap goes through.
    func testARefusedAppIsNeverReachedByAUIAction() async throws {
        let icli = FakeIcli()
        let apelin: [String: Any] = ["bundle_id": "wiki.qaq.apelin", "verified": true, "source": "runningboard"]
        icli.front = apelin
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0.01
        diagnostics.settleTimeout = 0.05
        let service = DiagnosticsService(
            diagnostics: diagnostics,
            host: ApelinService(transport: NoHost()),
            home: "/nonexistent",
            installRoot: "/",
        )
        let refused = ["wiki.qaq.apelin"]
        func expectRefused(_ request: ApelinProtocol.UIActionRequest, _ what: String) async {
            do {
                _ = try await service.uiAction(request)
                XCTFail("\(what): performed")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .denied, what)
            } catch {
                XCTFail("\(what): \(error)")
            }
        }

        let actions: [ApelinProtocol.UIAction] = [
            .tap(x: 200, y: 4),
            .tapElement(text: "Delete", identifier: nil),
            .type(text: "yes"),
            .swipe(fromX: 300, fromY: 100, toX: 20, toY: 100, durationMilliseconds: 200),
        ]
        for action in actions {
            await expectRefused(.init(action: action, refusedBundleIDs: refused), "Apelin in front, \(action)")
        }
        icli.lock.withLock { icli.frontQueues = [] }
        await expectRefused(.init(targetID: "wiki.qaq.apelin", action: .tap(x: 200, y: 4), refusedBundleIDs: refused), "Apelin as the target")
        XCTAssertTrue(icli.lock.withLock { icli.frontQueues.isEmpty }, "a refused target is refused before the foreground is read")
        icli.front = ["bundle_id": "wiki.qaq.apelin", "verified": false, "source": "springboard_query"]
        await expectRefused(.init(action: .tap(x: 200, y: 4), refusedBundleIDs: refused), "Apelin in front, unverified")
        XCTAssertTrue(icli.taps.isEmpty && icli.elementTaps.isEmpty, "nothing reached the screen")

        icli.front = ["bundle_id": "com.apple.Preferences", "verified": true, "source": "runningboard"]
        _ = try await service.uiAction(.init(action: .tap(x: 1, y: 2), refusedBundleIDs: refused))
        icli.front = apelin
        _ = try await service.uiAction(.init(action: .tap(x: 200, y: 4)))
        XCTAssertEqual(icli.taps.map(\.0), [1, 200], "another app in front, and any app without the list")
    }

    func testCrashListUsesFileNamesAsIDs() throws {
        let icli = FakeIcli()
        icli.crashes = [
            "/var/mobile/Library/Logs/CrashReporter/SpringBoard-2026-10-17-100000.ips",
            "/var/mobile/Library/Logs/CrashReporter/../../etc/passwd",
        ]
        let service = DiagnosticsService(diagnostics: Diagnostics(icli: icli), host: ApelinService(transport: NoHost()), home: "/nonexistent", installRoot: "/")
        let list = try service.crashList(CrashListRequest())
        XCTAssertEqual(list.reports.map(\.id), ["SpringBoard-2026-10-17-100000.ips"])
        XCTAssertEqual(list.reports.first?.process, "SpringBoard")
        XCTAssertFalse(DiagnosticsService.isValidReportID("../x.ips"))
        XCTAssertFalse(DiagnosticsService.isValidReportID("x.txt"))
    }

    func testScreenshotIsPassedAsADescriptor() throws {
        let descriptor = try DescriptorFile.holding(Data([1, 2, 3]))
        defer { descriptor.close() }
        let data = FileHandle(fileDescriptor: descriptor.rawValue, closeOnDealloc: false).readDataToEndOfFile()
        XCTAssertEqual(data, Data([1, 2, 3]))
    }
}
