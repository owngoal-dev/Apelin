@testable import ApelinDiagnostics
import XCTest

/// Stands in for IcliKit, which does not build for macOS: answers each call
/// with the fixture dictionary of the same name and records what was asked.
final class FakeIcli: IcliSurface, @unchecked Sendable {
    private let responses: [String: [String: Any]]
    private let lock = NSLock()
    private(set) var calls = [String]()
    var lockStateResponse: [String: Any]?
    /// What a wake answers: icli's lock state after it.
    var wakeResponse: [String: Any] = [:]
    var screenshotResponse: [String: Any] = [:]
    var crashText: [String: Any] = [:]
    /// Answers for `frontmostApp`, one per call, the last one repeated;
    /// empty: the fixture's.
    var frontmostAnswers: [[String: Any]] = []
    /// Answers for `uiElements`, the same way.
    var elementAnswers: [[String: Any]] = []
    var waitAnswer: [String: Any] = ["found": true]

    init() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "icli-responses", withExtension: "json", subdirectory: "Fixtures"))
        responses = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: Any]])
    }

    private func answer(_ name: String, _ detail: String = "") -> [String: Any] {
        lock.lock()
        calls.append(detail.isEmpty ? name : "\(name) \(detail)")
        lock.unlock()
        return responses[name] ?? [:]
    }

    func captureSyslog(seconds: Double, filter: IcliSyslogFilter, maxLines: Int) throws -> [String: Any] {
        let fields = [
            "process=\(filter.process ?? "-")", "subsystem=\(filter.subsystem ?? "-")",
            "message=\(filter.messageContains ?? "-")", "level=\(filter.level)",
        ]
        return answer("captureSyslog", "seconds=\(seconds) \(fields.joined(separator: " ")) maxLines=\(maxLines)")
    }

    func openSyslogStream(
        filter _: IcliSyslogFilter,
        seconds _: Double,
        handler _: @escaping @Sendable (LogEntry) -> Bool,
        onEnd _: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream {
        _ = answer("openSyslogStream")
        throw DiagnosticsError.unavailable("not in this fake")
    }

    func crashLogs(bundleID: String?) throws -> [String: Any] {
        answer("crashLogs", bundleID ?? "-")
    }

    func readCrashLog(_ path: String, maxBytes: Int) throws -> [String: Any] {
        _ = answer("readCrashLog", "\(path) \(maxBytes)"); return crashText
    }

    func takeScreenshot() throws -> [String: Any] {
        _ = answer("takeScreenshot"); return screenshotResponse
    }

    func uiElements(maxElements: Int, visibleOnly _: Bool, clickableOnly _: Bool) throws -> [String: Any] {
        let fixture = answer("uiElements", "max=\(maxElements)")
        return next(&elementAnswers) ?? fixture
    }

    func tap(x: Double, y: Double) throws -> [String: Any] {
        answer("tap", "\(x),\(y)")
    }

    func tapElement(text: String?, identifier: String?, role _: String?, match: String, index: Int) throws -> [String: Any] {
        answer("tapElement", "\(identifier ?? text ?? "-") \(match) \(index)")
    }

    func waitForElement(
        text: String?,
        identifier: String?,
        role _: String?,
        match: String,
        index: Int,
        appear: Bool,
        timeout: Double,
        interval: Double,
    ) throws -> [String: Any] {
        _ = answer("waitForElement", "\(identifier ?? text ?? "-") \(match) \(index) appear=\(appear) \(timeout)s every \(interval)s")
        return waitAnswer
    }

    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double) throws -> [String: Any] {
        answer("swipe", "\(x1),\(y1)->\(x2),\(y2) \(seconds)")
    }

    func typeText(_ text: String, delayMS _: Double) throws -> [String: Any] {
        answer("typeText", text)
    }

    func pressButton(_ name: String) throws -> [String: Any] {
        _ = answer("pressButton", name)
        return name == "wake" ? wakeResponse : ["button": name]
    }

    func frontmostApp() -> [String: Any] {
        let fixture = answer("frontmostApp")
        return next(&frontmostAnswers) ?? fixture
    }

    /// The first of `answers`, kept as the answer from then on once it is
    /// the last; nil when there are none.
    private func next(_ answers: inout [[String: Any]]) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = answers.first else { return nil }
        if answers.count > 1 {
            answers.removeFirst()
        }
        return next
    }

    func lockState() -> [String: Any] {
        lockStateResponse ?? answer("lockState")
    }

    func screenInfo() -> [String: Any] {
        answer("screenInfo")
    }

    func runningApps() throws -> [String: Any] {
        answer("runningApps")
    }

    func processes() throws -> [String: Any] {
        answer("processes")
    }

    /// Where the fixture's app bundles are, when a test made them on disk.
    var appsRoot: URL?

    func installedApps() throws -> [String: Any] {
        var raw = answer("installedApps")
        if let appsRoot, let apps = raw["apps"] as? [[String: Any]] {
            raw["apps"] = apps.map { app in
                var app = app
                if let path = app["bundle_path"] as? String {
                    app["bundle_path"] = appsRoot.appendingPathComponent((path as NSString).lastPathComponent).path
                }
                return app
            }
        }
        return raw
    }

    func respring() throws -> [String: Any] {
        answer("respring")
    }
}

final class DiagnosticsTests: XCTestCase {
    // MARK: Logs

    func testSubsystemGoesToIcliBeforeItsCap() throws {
        let icli = try FakeIcli()
        let result = try Diagnostics(icli: icli).readLogs(LogFilter(subsystem: "wiki.qaq.apelin.hello", duration: 3))
        // The fixture is icli unfiltered; Apelin's own check still holds.
        XCTAssertEqual(result.entries.map(\.message), ["ApelinHello: alert shown", "ApelinHello: second line"])
        XCTAssertEqual(result.source, .icli)
        XCTAssertFalse(result.truncated)
        // icli filters the subsystem itself, so its cap counts only those.
        XCTAssertEqual(icli.calls, ["captureSyslog seconds=3.0 process=- subsystem=wiki.qaq.apelin.hello message=- level=debug maxLines=501"])
    }

    func testProcessIsExactWhileIcliMatchesSubstrings() throws {
        let icli = try FakeIcli()
        let result = try Diagnostics(icli: icli).readLogs(LogFilter(process: "springboard", messageContains: "loaded into"))
        XCTAssertEqual(result.entries.map(\.pid), [800], "SpringBoardHelper is not SpringBoard")
        XCTAssertEqual(result.entries.first?.date, ISO8601DateFormatter().date(from: "2026-10-17T02:15:00Z"))
        // Checked here after icli, so icli is asked for its whole cap.
        XCTAssertEqual(icli.calls, ["captureSyslog seconds=3.0 process=springboard subsystem=- message=loaded into level=debug maxLines=5000"])
    }

    func testLevelIsIcliLevelByName() throws {
        let icli = try FakeIcli()
        let result = try Diagnostics(icli: icli).readLogs(LogFilter(minimumLevel: .error, maxEntries: 10))
        XCTAssertEqual(result.entries.map(\.level), [.error, .fault])
        XCTAssertEqual(icli.calls, ["captureSyslog seconds=3.0 process=- subsystem=- message=- level=error maxLines=11"])
        for level in LogLevel.allCases {
            XCTAssertTrue(["debug", "info", "default", "error", "fault"].contains(Diagnostics.icliFilter(LogFilter(minimumLevel: level)).level))
        }
    }

    func testTheCapTruncates() throws {
        let result = try Diagnostics(icli: FakeIcli()).readLogs(LogFilter(maxEntries: 2))
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertTrue(result.truncated)
    }

    func testOutOfRangeFiltersNeverReachIcli() throws {
        let icli = try FakeIcli()
        let diagnostics = Diagnostics(icli: icli)
        for filter in [
            LogFilter(duration: 0),
            LogFilter(duration: 61),
            LogFilter(duration: .nan),
            LogFilter(maxEntries: 0),
            LogFilter(maxEntries: 5001),
            LogFilter(subsystem: ""),
            LogFilter(messageContains: "a\0b"),
            LogFilter(process: String(repeating: "x", count: 257)),
        ] {
            XCTAssertThrowsError(try diagnostics.readLogs(filter)) { error in
                guard case DiagnosticsError.invalidParameter = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(icli.calls, [])
    }

    // MARK: Crash reports

    func testCrashListIsFilteredAndBounded() throws {
        let icli = try FakeIcli()
        let diagnostics = Diagnostics(icli: icli)
        let springBoard = try diagnostics.listCrashReports(CrashReportListRequest(processName: "springboard", limit: 1))
        XCTAssertEqual(springBoard.map(\.name), ["SpringBoard-2026-10-17-101500.ips"])
        XCTAssertEqual(try diagnostics.listCrashReports(CrashReportListRequest()).count, 3)
        XCTAssertThrowsError(try diagnostics.listCrashReports(CrashReportListRequest(limit: 0)))
        XCTAssertThrowsError(try diagnostics.listCrashReports(CrashReportListRequest(bundleIdentifier: "../x")))
    }

    func testOnlyReportsInsideTheCrashDirectoriesAreRead() throws {
        let icli = try FakeIcli()
        let diagnostics = Diagnostics(icli: icli)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ips")
        try Data("{}".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        for path in [outside.path, "/etc/passwd", "/var/mobile/Library/Logs/CrashReporter/../../../../etc/hosts", "a\0b.ips"] {
            XCTAssertThrowsError(try diagnostics.readCrashReport(path: path)) { error in
                guard case DiagnosticsError.invalidParameter = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try diagnostics.readCrashReport(path: outside.path, maxBytes: 0))
        XCTAssertEqual(icli.calls, [])
    }

    func testCrashTextKeepsIcliSizeAndTruncation() {
        // icli read at most maxBytes, cut back to a whole character.
        let cut = Diagnostics.decodeCrashText(["path": "/x.ips", "content": "ab", "size": 8, "bytes": 2, "truncated": true])
        XCTAssertEqual(cut.text, "ab")
        XCTAssertTrue(cut.truncated)
        XCTAssertEqual(cut.size, 8)
        let whole = Diagnostics.decodeCrashText(["path": "/x.ips", "content": "ab😀cd", "size": 8, "bytes": 8, "truncated": false])
        XCTAssertEqual(whole.text, "ab😀cd")
        XCTAssertFalse(whole.truncated)
    }

    // MARK: Screen and UI

    func testScreenshotIsDecodedAndCapped() throws {
        let icli = try FakeIcli()
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        icli.screenshotResponse = ["data": bytes.base64EncodedString(), "width": 390, "height": 844, "coordinate_scale": 1.0]
        let shot = try Diagnostics(icli: icli).screenshot()
        XCTAssertEqual(shot.jpeg, bytes)
        XCTAssertEqual(shot.width, 390)

        icli.screenshotResponse = ["data": Data(count: Screenshot.maximumBytes + 1).base64EncodedString()]
        XCTAssertThrowsError(try Diagnostics(icli: icli).screenshot())
        icli.screenshotResponse = ["path": "/tmp/x.jpg"]
        XCTAssertThrowsError(try Diagnostics(icli: icli).screenshot(), "a path is not an attachment")
    }

    func testUITreeDecodes() throws {
        let tree = try Diagnostics(icli: FakeIcli()).uiTree()
        XCTAssertEqual(tree.pid, 800)
        XCTAssertTrue(tree.truncated)
        XCTAssertEqual(tree.elements.map(\.label), ["Hello World", "OK", "Volume"])
        XCTAssertEqual(tree.elements[1].identifier, "hello.ok")
        XCTAssertEqual(tree.elements[1].tapPoint, UIPoint(x: 190, y: 382))
        XCTAssertEqual(tree.elements[1].frame, UIRect(x: 40, y: 360, width: 300, height: 44))
        XCTAssertEqual(tree.elements[2].value, "0.5")
    }

    func testActionsAreTypedAndChecked() throws {
        let icli = try FakeIcli()
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0
        try diagnostics.perform(.tap(UIPoint(x: 10, y: 20)))
        try diagnostics.perform(.tapElement(UIElementSelector(identifier: "hello.ok", match: .exact)))
        try diagnostics.perform(.swipe(from: UIPoint(x: 1, y: 2), to: UIPoint(x: 3, y: 4), seconds: 0.3))
        try diagnostics.perform(.type(text: "hi", delayMilliseconds: 30))
        XCTAssertNil(try diagnostics.perform(.press(.home)), "only a wake answers the lock state")
        try diagnostics.perform(.press(.lock))
        XCTAssertEqual(icli.calls.filter { !$0.hasPrefix("lockState") && $0 != "frontmostApp" }, [
            "tap 10.0,20.0",
            "waitForElement hello.ok exact 0 appear=true 3.0s every 0.3s",
            "tapElement hello.ok exact 0",
            "swipe 1.0,2.0->3.0,4.0 0.3",
            "uiElements max=2000",
            "typeText hi",
            // Nothing changed: read again, and the second read agrees.
            "uiElements max=2000",
            "uiElements max=2000",
            "pressButton home",
            "pressButton power",
        ])

        for bad in [
            UIAction.tap(UIPoint(x: -1, y: 0)),
            .tap(UIPoint(x: .infinity, y: 0)),
            .tapElement(UIElementSelector()),
            .tapElement(UIElementSelector(text: "x", index: 101)),
            .swipe(from: UIPoint(x: 0, y: 0), to: UIPoint(x: 1, y: 1), seconds: 10),
            .type(text: "", delayMilliseconds: 0),
            .type(text: String(repeating: "a", count: 4097), delayMilliseconds: 0),
            .type(text: "a", delayMilliseconds: 501),
        ] {
            XCTAssertThrowsError(try diagnostics.perform(bad), "\(bad)")
        }
    }

    /// Right after an app switch RunningBoard names no single focal app for
    /// about a second (seen on the iOS 26.4 vphone: readUITree failed at 0
    /// and 0.5 s after Apelin came to the front, passed from 1 s on). A read
    /// waits for the same verified app twice in a row.
    func testTheTreeWaitsForTheForegroundToSettle() throws {
        let icli = try FakeIcli()
        let unverified: [String: Any] = ["bundle_id": "com.apple.springboard", "verified": false, "source": "unavailable"]
        let apelin: [String: Any] = ["bundle_id": "wiki.qaq.apelin", "verified": true, "source": "runningboard"]
        let settings: [String: Any] = ["bundle_id": "com.apple.Preferences", "verified": true, "source": "runningboard"]
        icli.frontmostAnswers = [unverified, settings, unverified, apelin, apelin]
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0
        XCTAssertEqual(try diagnostics.uiTree().pid, 800)
        let asked = icli.calls.filter { $0 == "frontmostApp" || $0.hasPrefix("uiElements") }
        XCTAssertEqual(asked, Array(repeating: "frontmostApp", count: 5) + ["uiElements max=250"])
        XCTAssertEqual(
            diagnostics.settledForegroundApp(),
            ForegroundApp(bundleIdentifier: "wiki.qaq.apelin", verified: true, source: "runningboard"),
        )
    }

    /// An action bound to Fila, sent right after Fila was opened, was
    /// refused while the front went between Fila and Apelin: two reads of
    /// Apelin settle a plain wait. A settle that expects an app waits for
    /// that one.
    func testASettleThatExpectsAnAppWaitsForIt() throws {
        let icli = try FakeIcli()
        let apelin: [String: Any] = ["bundle_id": "wiki.qaq.apelin", "verified": true, "source": "runningboard"]
        let fila: [String: Any] = ["bundle_id": "wiki.qaq.fila", "verified": true, "source": "runningboard"]
        icli.frontmostAnswers = [apelin, apelin, fila, fila]
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0
        XCTAssertEqual(diagnostics.settledForegroundApp(expecting: "wiki.qaq.fila").bundleIdentifier, "wiki.qaq.fila")
        XCTAssertEqual(icli.calls.filter { $0 == "frontmostApp" }.count, 4)

        icli.frontmostAnswers = [apelin, apelin, fila, fila]
        XCTAssertEqual(diagnostics.settledForegroundApp().bundleIdentifier, "wiki.qaq.apelin", "any app settles a plain read")

        icli.frontmostAnswers = [apelin]
        diagnostics.settleTimeout = 0.05
        diagnostics.settleInterval = 0.01
        XCTAssertEqual(
            diagnostics.settledForegroundApp(expecting: "wiki.qaq.fila").bundleIdentifier,
            "wiki.qaq.apelin",
            "an app that never comes answers the last read once the time is up",
        )
    }

    /// A menu still animating in has no element to tap yet: the tap waits
    /// for it, and taps once.
    func testAnElementTapWaitsForItsElement() throws {
        let icli = try FakeIcli()
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0
        diagnostics.elementTimeout = 2
        diagnostics.elementInterval = 0.5
        try diagnostics.perform(.tapElement(UIElementSelector(text: "Rename", match: .exact)))
        XCTAssertEqual(icli.calls.filter { $0.hasPrefix("waitForElement") || $0.hasPrefix("tapElement") }, [
            "waitForElement Rename exact 0 appear=true 2.0s every 0.5s",
            "tapElement Rename exact 0",
        ])

        let missing = try FakeIcli()
        missing.waitAnswer = ["found": false]
        var waiting = Diagnostics(icli: missing)
        waiting.settleInterval = 0
        XCTAssertThrowsError(try waiting.perform(.tapElement(UIElementSelector(text: "Rename")))) { error in
            XCTAssertEqual(
                error as? DiagnosticsError,
                .failed("element \"Rename\" did not appear within 3 s; read the UI tree again"),
            )
        }
        XCTAssertFalse(missing.calls.contains { $0.hasPrefix("tapElement") }, "nothing is tapped")
    }

    /// The field that lost characters shows them lost.
    func testTypedTextIsReadBackFromTheFieldThatChanged() throws {
        func tree(_ field: String, pid: Int = 800) -> [String: Any] {
            ["pid": pid, "elements": [
                ["label": "Name", "value": field, "role": "element", "visible": true],
                ["label": "Volume", "value": 0.5, "role": "element", "visible": true],
            ]]
        }
        let icli = try FakeIcli()
        icli.elementAnswers = [tree(""), tree("Hello wrd")]
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleInterval = 0
        XCTAssertEqual(
            try diagnostics.perform(.type(text: "Hello world", delayMilliseconds: 30))?.typed,
            TypedText(matches: false, fieldValues: ["Hello wrd"]),
        )
        XCTAssertEqual(icli.calls.filter { $0.hasPrefix("uiElements") }.count, 3, "a read before, and after until two agree")

        icli.elementAnswers = [tree(""), tree("Hello world")]
        XCTAssertEqual(
            try diagnostics.perform(.type(text: "Hello world", delayMilliseconds: 30))?.typed,
            TypedText(matches: true, fieldValues: ["Hello world"]),
        )

        icli.elementAnswers = [tree(""), tree("Hello wor"), tree("Hello world")]
        XCTAssertEqual(
            try diagnostics.perform(.type(text: "Hello world", delayMilliseconds: 30))?.typed?.matches,
            true,
            "a read while the last characters go in is read again",
        )

        icli.elementAnswers = [tree(""), tree("Hello world", pid: 900)]
        XCTAssertNil(try diagnostics.perform(.type(text: "Hello world", delayMilliseconds: 30)), "another app's tree says nothing")
        XCTAssertNil(try diagnostics.perform(.tap(UIPoint(x: 1, y: 1))))
    }

    func testTypedTextCountsOnlyValuesThatChanged() {
        XCTAssertEqual(
            TypedText(typed: "b", before: ["x", "", "x", "0.5"], after: ["0.5", "x", "xb", "x"]),
            TypedText(matches: true, fieldValues: ["xb"]),
            "values that moved are not changes; a field that grew is",
        )
        XCTAssertEqual(TypedText(typed: "a", before: ["a"], after: ["a"]), TypedText(matches: false, fieldValues: []))
        let long = String(repeating: "a", count: TypedText.maximumValueCharacters + 5)
        let typed = TypedText(typed: "a", before: [], after: (0 ... TypedText.maximumValues).map { "\($0)\(long)" })
        XCTAssertEqual(typed.fieldValues.count, TypedText.maximumValues)
        XCTAssertEqual(typed.fieldValues.first?.count, TypedText.maximumValueCharacters)
    }

    func testAForegroundThatNeverSettlesIsNotRead() throws {
        let icli = try FakeIcli()
        icli.frontmostAnswers = [["bundle_id": "com.apple.springboard", "verified": false, "source": "unavailable"]]
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleTimeout = 0.05
        diagnostics.settleInterval = 0.01
        XCTAssertThrowsError(try diagnostics.uiTree()) { error in
            guard case .unavailable = error as? DiagnosticsError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try diagnostics.perform(.tapElement(UIElementSelector(identifier: "hello.ok", match: .exact))))
        XCTAssertFalse(icli.calls.contains { $0.hasPrefix("uiElements") || $0.hasPrefix("tapElement") })
        XCTAssertFalse(diagnostics.settledForegroundApp().verified)
    }

    func testALockedDeviceTakesNoInput() throws {
        let icli = try FakeIcli()
        icli.lockStateResponse = ["locked": true, "screen_off": false]
        for action in [UIAction.tap(UIPoint(x: 1, y: 1)), .press(.home), .press(.lock)] {
            XCTAssertThrowsError(try Diagnostics(icli: icli).perform(action), "\(action)") { error in
                XCTAssertEqual(error as? DiagnosticsError, .locked(screenOff: false))
            }
        }
        XCTAssertThrowsError(try Diagnostics(icli: icli).uiTree())
        XCTAssertFalse(icli.calls.contains { $0.hasPrefix("tap") || $0.hasPrefix("uiElements") || $0.hasPrefix("pressButton") })
    }

    /// The refusal says which it is, a dark screen or a lit lock screen, and
    /// that a wake is the way on.
    func testTheRefusalTellsADarkScreenFromALockedOne() throws {
        let icli = try FakeIcli()
        icli.lockStateResponse = ["locked": true, "screen_off": true]
        XCTAssertThrowsError(try Diagnostics(icli: icli).uiTree()) { error in
            XCTAssertEqual(error as? DiagnosticsError, .locked(screenOff: true))
        }
        icli.lockStateResponse = ["locked": false, "screen_off": true]
        XCTAssertThrowsError(try Diagnostics(icli: icli).perform(.press(.home))) { error in
            XCTAssertEqual(error as? DiagnosticsError, .locked(screenOff: true), "a dark screen, locked or not")
        }
        let dark = DiagnosticsError.locked(screenOff: true).localizedDescription
        let locked = DiagnosticsError.locked(screenOff: false).localizedDescription
        XCTAssertTrue(dark.hasPrefix("The screen is off."), dark)
        XCTAssertTrue(locked.hasPrefix("The device is locked."), locked)
        for message in [dark, locked] {
            XCTAssertTrue(message.contains("wake button"), message)
            XCTAssertTrue(message.contains("passcode") && message.contains("the user unlocks it"), message)
        }
    }

    /// A wake runs on a dark or locked screen, where nothing else does, and
    /// answers the state it left: a device with a passcode stays locked.
    func testAWakeRunsOnALockedDeviceAndAnswersWhatItLeft() throws {
        let icli = try FakeIcli()
        icli.lockStateResponse = ["locked": true, "screen_off": true]
        icli.wakeResponse = ["button": "wake", "locked": true, "screen_off": false]
        let diagnostics = Diagnostics(icli: icli)
        XCTAssertEqual(try diagnostics.perform(.press(.wake))?.lock, LockState(locked: true, screenOff: false))
        icli.wakeResponse = ["button": "wake", "locked": false, "screen_off": false]
        XCTAssertEqual(try diagnostics.perform(.press(.wake))?.lock, LockState(locked: false, screenOff: false))
        XCTAssertEqual(icli.calls, ["pressButton wake", "pressButton wake"])
    }

    // MARK: Apps, respring

    func testAppsAndRespringDecode() throws {
        let diagnostics = try Diagnostics(icli: FakeIcli())
        XCTAssertEqual(diagnostics.foregroundApp(), ForegroundApp(bundleIdentifier: "com.apple.springboard", verified: true, source: "runningboard"))
        XCTAssertEqual(try diagnostics.runningApps().first?.bundleIdentifier, "wiki.qaq.apelin")
        XCTAssertEqual(try diagnostics.respring(), RespringResult(method: "frontboard_relaunch", previousPID: 800, pid: 1200))
    }

    /// The process list names each process by pid, the kernel's name and
    /// its executable's path; kernel_task's pid 0 is no process to watch.
    func testProcessesDecodeAndMatchByExecutableName() throws {
        let rows = try Diagnostics(icli: FakeIcli()).processes()
        XCTAssertEqual(rows.map(\.pid), [800, 812, 901])
        XCTAssertEqual(rows.filter { $0.runs("dtremotedisplayd") }.map(\.pid), [812])
        XCTAssertEqual(rows.filter { $0.runs("springboard") }.map(\.pid), [800], "case aside, as the log's process names")
        XCTAssertTrue(rows.filter { $0.runs("Board") }.isEmpty, "the whole name, never a part of it")
        // A process with no path is known by the kernel's name, cut at 16
        // bytes for a longer executable name.
        XCTAssertEqual(rows.filter { $0.runs("com.apple.WebKit.WebContent") }.map(\.pid), [901])
        XCTAssertTrue(rows.filter { $0.runs("com.apple.WebKi") }.isEmpty, "a shorter name is not a cut one")
    }

    /// A bundle id names the executable its installed bundle's Info.plist
    /// gives, running or not; an id no app has is none.
    func testAnInstalledAppIsResolvedFromItsBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-apps-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Apelin.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let info: NSDictionary = ["CFBundleIdentifier": "wiki.qaq.apelin", "CFBundleExecutable": "Apelin"]
        XCTAssertTrue(info.write(to: bundle.appendingPathComponent("Info.plist"), atomically: true))
        let icli = try FakeIcli()
        icli.appsRoot = root
        let diagnostics = Diagnostics(icli: icli)
        XCTAssertEqual(try diagnostics.installedAppExecutable(bundleIdentifier: "wiki.qaq.apelin"), "Apelin")
        XCTAssertNil(try diagnostics.installedAppExecutable(bundleIdentifier: "com.example.missing"))
    }

    func testAnUnverifiedForegroundIsReportedAsSuch() {
        let app = Diagnostics.decodeForeground(["bundle_id": "com.apple.springboard", "verified": false, "source": "unavailable"])
        XCTAssertFalse(app.verified)
        XCTAssertEqual(Diagnostics.decodeForeground([:]).source, "unavailable")
    }
}
