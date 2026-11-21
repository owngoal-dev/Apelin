import ApelinCore
import ApelinDiagnostics
@testable import ApelinDiagnosticsWorker
import ApelinProtocol
import Foundation
import XCTest

/// The screen as icli's surface sees it, with a Lock Screen that a Home
/// press passes only once the keybag is unlocked (`uiUnlocks`).
private final class LockScreenIcli: IcliSurface, @unchecked Sendable {
    let lock = NSLock()
    var locked = false
    var screenOff = false
    /// Whether Home or a swipe passes a lit Lock Screen.
    var uiUnlocks = true
    var presses: [String] = []
    /// Presses and foreground reads, in order.
    var events: [String] = []
    var swipes = 0

    func captureSyslog(seconds _: Double, filter _: IcliSyslogFilter, maxLines _: Int) throws -> [String: Any] {
        [:]
    }

    func openSyslogStream(
        filter _: IcliSyslogFilter,
        seconds _: Double,
        handler _: @escaping @Sendable (LogEntry) -> Bool,
        onEnd _: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream {
        throw DiagnosticsError.unavailable("no")
    }

    func crashLogs(bundleID _: String?) throws -> [String: Any] {
        [:]
    }

    func readCrashLog(_: String, maxBytes _: Int) throws -> [String: Any] {
        [:]
    }

    func takeScreenshot() throws -> [String: Any] {
        [:]
    }

    func uiElements(maxElements _: Int, visibleOnly _: Bool, clickableOnly _: Bool) throws -> [String: Any] {
        [:]
    }

    func tap(x _: Double, y _: Double) throws -> [String: Any] {
        [:]
    }

    func tapElement(text _: String?, identifier _: String?, role _: String?, match _: String, index _: Int) throws -> [String: Any] {
        [:]
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
        lock.withLock {
            swipes += 1
            if uiUnlocks, !screenOff {
                locked = false
            }
        }
        return [:]
    }

    func typeText(_: String, delayMS _: Double) throws -> [String: Any] {
        XCTFail("nothing types while unlocking")
        return [:]
    }

    func pressButton(_ name: String) throws -> [String: Any] {
        lock.withLock {
            presses.append(name)
            events.append(name)
            switch name {
            case "power": locked = true; screenOff = true
            case "wake": screenOff = false
            case "home" where !screenOff && uiUnlocks: locked = false
            default: break
            }
            return ["button": name, "locked": locked, "screen_off": screenOff]
        }
    }

    func frontmostApp() -> [String: Any] {
        lock.withLock { events.append("front") }
        return ["bundle_id": "wiki.qaq.apelin", "verified": false, "source": "springboard_query"]
    }

    func lockState() -> [String: Any] {
        lock.withLock { ["locked": locked, "screen_off": screenOff] }
    }

    func screenInfo() -> [String: Any] {
        ["width": 430, "height": 932]
    }

    func runningApps() throws -> [String: Any] {
        ["apps": []]
    }

    func respring() throws -> [String: Any] {
        [:]
    }
}

/// icli's passcode commands, scripted: the keybag's lock state follows the
/// screen's lock (as MobileKeyBag's does) unless the test says otherwise,
/// and every attempt is counted.
private final class FakeKeybag: PasscodeKeybag, @unchecked Sendable {
    let lock = NSLock()
    let screen: LockScreenIcli
    /// The device's passcode; nil: it has none.
    var devicePasscode: String? = "1472"
    var failedAttempts: Int? = 0
    var ledger: [String] = []
    var backoff = 0
    var outdated = false
    /// Whether the keybag locks when the screen does.
    var keybagLocks = true
    var keybagLocked = false
    /// What the next attempt answers instead of comparing (a kill, a status
    /// icli does not promise).
    var forcedAnswer: UnlockAnswer?
    /// Runs during an attempt: what another process does meanwhile.
    var duringAttempt: (() -> Void)?
    var attempts: [String] = []
    var forgets = 0
    var statusReads = 0

    init(screen: LockScreenIcli) {
        self.screen = screen
    }

    private var lockStateValue: Int {
        guard devicePasscode != nil else { return 3 }
        if keybagLocks, screen.lockState()["locked"] as? Bool == true, !keybagLocked {
            keybagLocked = true
        }
        return keybagLocked ? 2 : 0
    }

    func status() throws -> KeybagStatus {
        try lock.withLock {
            statusReads += 1
            if outdated {
                throw KeybagFailure.outdated
            }
            return KeybagStatus(
                lockState: lockStateValue,
                failedAttempts: failedAttempts,
                backoffSeconds: backoff,
                ledgerFailures: ledger.count,
            )
        }
    }

    func unlock(passcode: String) -> UnlockAnswer {
        lock.withLock {
            attempts.append(passcode)
            duringAttempt?()
            if let forcedAnswer {
                return forcedAnswer
            }
            // icli's own guards, as `--max-failures 1` applies them.
            if lockStateValue != 2 {
                return UnlockAnswer(outcome: .unlocked(attempted: false), detail: "already unlocked")
            }
            if ledger.contains(passcode) {
                return UnlockAnswer(outcome: .rejectedBefore, detail: "rejected before")
            }
            if max(ledger.count, failedAttempts ?? 0) >= DevicePasscode.maximumFailures || backoff > 0 {
                return UnlockAnswer(outcome: .refused, detail: "limit reached")
            }
            if passcode == devicePasscode {
                keybagLocked = false
                failedAttempts = 0
                ledger = []
                return UnlockAnswer(outcome: .unlocked(attempted: true), detail: "The keybag is unlocked.")
            }
            failedAttempts = (failedAttempts ?? 0) + 1
            ledger.append(passcode)
            return UnlockAnswer(outcome: .rejected, detail: "The keybag rejected the passcode.")
        }
    }

    func forgetRejected() throws {
        lock.withLock {
            forgets += 1
            ledger = []
        }
    }

    /// A person unlocks the device with its passcode.
    func personUnlocks() {
        lock.withLock {
            keybagLocked = false
            failedAttempts = 0
        }
        screen.lock.withLock {
            screen.locked = false
            screen.screenOff = false
        }
    }
}

private final class MemoryPasscodeStore: DevicePasscodeStore, @unchecked Sendable {
    let lock = NSLock()
    var saved: SavedPasscode?
    var failWrites = false
    var writes: [SavedPasscode.Stage] = []

    func read() throws -> SavedPasscode? {
        lock.withLock { saved }
    }

    func write(_ saved: SavedPasscode) throws {
        try lock.withLock {
            if failWrites {
                throw ApelinError(.unavailable, "the keychain is locked")
            }
            writes.append(saved.stage)
            self.saved = saved
        }
    }

    func remove() throws {
        lock.withLock { saved = nil }
    }
}

final class DeviceUnlockTests: XCTestCase {
    private var screen: LockScreenIcli!
    private var keybag: FakeKeybag!
    private var store: MemoryPasscodeStore!
    private var unlocker: DeviceUnlock!

    override func setUp() {
        screen = LockScreenIcli()
        keybag = FakeKeybag(screen: screen)
        store = MemoryPasscodeStore()
        unlocker = DeviceUnlock(diagnostics: quick(screen), keybag: keybag, store: store)
        unlocker.lockWait = 0.2
        unlocker.pollInterval = 0.01
        unlocker.settle = 0.05
    }

    /// Diagnostics whose foreground settles at once.
    private func quick(_ icli: LockScreenIcli) -> Diagnostics {
        var diagnostics = Diagnostics(icli: icli)
        diagnostics.settleTimeout = 0.05
        diagnostics.settleInterval = 0.01
        return diagnostics
    }

    private func lockDevice() {
        screen.lock.withLock {
            screen.locked = true
            screen.screenOff = true
        }
        _ = try? keybag.status()
    }

    private func expectError(
        _ reason: ApelinError.Reason,
        _ code: ApelinError.Code,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void,
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let error = error as? ApelinError
            XCTAssertEqual(error?.code, code, file: file, line: line)
            XCTAssertEqual(error?.reason, reason, "\(String(describing: error))", file: file, line: line)
        }
    }

    // MARK: Test and Save

    func testARightPasscodeIsSavedOnlyAfterIcliUnlockedTheLockedDeviceWithIt() throws {
        let response = try unlocker.saveAndTest("1472")
        XCTAssertEqual(response.outcome, .saved)
        XCTAssertEqual(response.state, DevicePasscodeState(saved: true, device: .passcode))
        XCTAssertEqual(keybag.attempts, ["1472"], "one attempt")
        XCTAssertEqual(screen.presses.first, "power", "the device locks first")
        XCTAssertEqual(store.saved, SavedPasscode(passcode: "1472", stage: .verified))
        XCTAssertFalse(screen.locked, "back past the Lock Screen")
    }

    func testAWrongPasscodeCostsOneAttemptAndIsNotSaved() throws {
        try store.write(SavedPasscode(passcode: "1472", stage: .verified))
        let response = try unlocker.saveAndTest("9999")
        XCTAssertEqual(response.outcome, .rejected)
        XCTAssertEqual(response.failedAttempts, 1)
        XCTAssertEqual(keybag.attempts, ["9999"])
        XCTAssertEqual(store.saved?.passcode, "1472", "the passcode saved before stays")
        XCTAssertTrue(screen.locked, "the user unlocks the device")
        XCTAssertFalse(screen.presses.contains("home"), "nothing opens the passcode pad")

        // Behind the Lock Screen the app cannot ask again; were it to, with the
        // count still at one, nothing would be tried.
        let again = try unlocker.saveAndTest("1472")
        XCTAssertEqual(again.outcome, .failed, "the keybag is still locked")
        XCTAssertEqual(keybag.attempts, ["9999"])
    }

    func testAfterAPersonUnlocksTheLedgerIsClearedAndTheNextTestMayTry() throws {
        _ = try unlocker.saveAndTest("9999")
        keybag.personUnlocks()
        XCTAssertEqual(keybag.ledger, ["9999"])
        let response = try unlocker.saveAndTest("1472")
        XCTAssertEqual(response.outcome, .saved)
        XCTAssertEqual(keybag.forgets, 1, "a typed passcode on a device whose count reads zero")
        XCTAssertEqual(keybag.attempts, ["9999", "1472"])
    }

    func testNothingIsTriedWhileAFailureIsOnRecord() throws {
        keybag.failedAttempts = 1
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .refused)
        keybag.failedAttempts = nil
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .refused, "an unreadable count refuses")
        keybag.failedAttempts = 0
        keybag.backoff = 60
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .refused)
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertTrue(screen.presses.isEmpty, "the device was not even locked")
        XCTAssertNil(store.saved)
    }

    func testADeviceWithoutAPasscodeNeedsNone() throws {
        keybag.devicePasscode = nil
        let response = try unlocker.saveAndTest("1472")
        XCTAssertEqual(response.outcome, .noPasscode)
        XCTAssertEqual(response.state, DevicePasscodeState(saved: false, device: .noPasscode))
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertTrue(screen.presses.isEmpty)
    }

    func testAnOldIcliTriesNothing() throws {
        keybag.outdated = true
        let response = try unlocker.saveAndTest("1472")
        XCTAssertEqual(response.outcome, .icliOutdated)
        XCTAssertEqual(response.state.device, .icliOutdated)
        XCTAssertTrue(keybag.attempts.isEmpty)
    }

    func testAKeybagThatDoesNotLockIsNoTest() throws {
        keybag.keybagLocks = false
        let response = try unlocker.saveAndTest("1472")
        XCTAssertEqual(response.outcome, .didNotLock)
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertNil(store.saved)
        XCTAssertFalse(screen.screenOff, "the screen is lit again")
    }

    func testAnAttemptThatFoundNothingToUnlockIsNoTest() throws {
        keybag.forcedAnswer = UnlockAnswer(outcome: .unlocked(attempted: false), detail: "already unlocked")
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .didNotLock)
        XCTAssertNil(store.saved)
    }

    func testAnAttemptThatKeepsNoPromiseSavesNothing() throws {
        keybag.forcedAnswer = UnlockAnswer(outcome: .unknown, detail: "icli did not answer")
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .failed)
        XCTAssertNil(store.saved)
    }

    func testAPasscodeIcliWouldCutIsRefusedBeforeAnything() {
        for passcode in ["", "14\n72", "1472\r", "14\u{0}72", String(repeating: "1", count: 129)] {
            XCTAssertThrowsError(try unlocker.saveAndTest(passcode)) { error in
                XCTAssertEqual((error as? ApelinError)?.code, .badRequest)
            }
        }
        XCTAssertEqual(keybag.statusReads, 0)
        XCTAssertTrue(screen.presses.isEmpty)
    }

    func testAPasscodeThatUnlockedButCouldNotBeSavedIsNotUsable() throws {
        store.failWrites = true
        XCTAssertEqual(try unlocker.saveAndTest("1472").outcome, .failed)
        XCTAssertNil(store.saved)
    }

    // MARK: The agent's unlock

    func testAnUnlockWithTheSavedPasscodeGoesToTheHomeScreen() throws {
        _ = try unlocker.saveAndTest("1472")
        screen.presses = []
        keybag.attempts = []
        lockDevice()
        let left = try unlocker.unlock()
        XCTAssertEqual(left, LockState(locked: false, screenOff: false))
        XCTAssertEqual(keybag.attempts, ["1472"])
        XCTAssertEqual(screen.presses.last, "home", "ends on the Home Screen")
        XCTAssertEqual(screen.events.suffix(2), ["front", "home"], "Home once the app in front has settled")
        XCTAssertEqual(store.saved?.stage, .verified)
        XCTAssertEqual(store.writes.suffix(2), [.attempting, .verified], "marked before the attempt, cleared after")
    }

    func testARejectedPasscodeIsRemovedSoASecondPressTriesNothing() throws {
        _ = try unlocker.saveAndTest("1472")
        keybag.devicePasscode = "2580" // the user changed it
        keybag.attempts = []
        lockDevice()
        expectError(.devicePasscodeRejected, .denied) { _ = try unlocker.unlock() }
        XCTAssertNil(store.saved)
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try unlocker.unlock() }
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try unlocker.unlock() }
        XCTAssertEqual(keybag.attempts, ["1472"], "one attempt, however often it is pressed")
        XCTAssertEqual(keybag.failedAttempts, 1)
    }

    func testAnAttemptWhoseEndIsUnknownDropsThePasscode() throws {
        _ = try unlocker.saveAndTest("1472")
        keybag.attempts = []
        lockDevice()
        keybag.forcedAnswer = UnlockAnswer(outcome: .unknown, detail: "icli did not answer in time")
        expectError(.devicePasscodeRejected, .denied) { _ = try unlocker.unlock() }
        keybag.forcedAnswer = nil
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try unlocker.unlock() }
        XCTAssertEqual(keybag.attempts.count, 1)
    }

    func testAnAttemptACrashCutShortLeavesNothingToTry() throws {
        // A worker killed between marking and answering left the mark.
        try store.write(SavedPasscode(passcode: "1472", stage: .attempting))
        lockDevice()
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try unlocker.unlock() }
        XCTAssertNil(store.saved, "dropped")
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertEqual(try unlocker.state(), DevicePasscodeState(saved: false, device: .passcode))
    }

    func testNoAttemptWhenTheMarkCannotBeWritten() throws {
        _ = try unlocker.saveAndTest("1472")
        keybag.attempts = []
        lockDevice()
        store.failWrites = true
        XCTAssertThrowsError(try unlocker.unlock())
        XCTAssertTrue(keybag.attempts.isEmpty)
        // A success whose clearing write fails leaves the mark: the next
        // press finds an attempt it never saw end, and tries nothing.
        store.failWrites = false
        try store.write(SavedPasscode(passcode: "1472", stage: .verified))
        let marking = MarkThenFail(inner: store)
        let marked = DeviceUnlock(diagnostics: quick(screen), keybag: keybag, store: marking, serial: PthreadLock())
        _ = try marked.unlock()
        XCTAssertEqual(keybag.attempts, ["1472"])
        XCTAssertEqual(store.saved?.stage, .attempting)
        lockDevice()
        keybag.attempts = []
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try marked.unlock() }
        XCTAssertTrue(keybag.attempts.isEmpty)
    }

    func testAFailureOnRecordRefusesTheUnlockAndKeepsThePasscode() throws {
        _ = try unlocker.saveAndTest("1472")
        keybag.attempts = []
        lockDevice()
        keybag.failedAttempts = 1 // the user mistyped it on the Lock Screen
        expectError(.devicePasscodeRefused, .conflict) { _ = try unlocker.unlock() }
        keybag.failedAttempts = 0
        keybag.ledger = ["0000"]
        expectError(.devicePasscodeRefused, .conflict) { _ = try unlocker.unlock() }
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertEqual(store.saved?.stage, .verified)
        XCTAssertEqual(keybag.forgets, 0, "an unlock never clears icli's ledger")
    }

    func testIcliRefusingAfterTheChecksKeepsThePasscode() throws {
        _ = try unlocker.saveAndTest("1472")
        lockDevice()
        keybag.forcedAnswer = UnlockAnswer(outcome: .refused, detail: "The keybag is delaying passcode attempts for 60 s; icli does not attempt during a back-off.")
        expectError(.devicePasscodeRefused, .conflict) { _ = try unlocker.unlock() }
        XCTAssertEqual(store.saved?.stage, .verified)
    }

    /// Another apelin-diagnostics whose attempt was rejected dropped the
    /// passcode while this one's attempt waited on icli's ledger: neither an
    /// attempt that found nothing to unlock nor one icli refused puts it back.
    func testAPasscodeAnotherUseDroppedMeanwhileStaysDropped() throws {
        let store = try XCTUnwrap(store)
        for answer in [UnlockAnswer.Outcome.unlocked(attempted: false), .refused] {
            try store.write(SavedPasscode(passcode: "1472", stage: .verified))
            lockDevice()
            keybag.duringAttempt = { try? store.remove() }
            keybag.forcedAnswer = UnlockAnswer(outcome: answer, detail: "")
            _ = try? unlocker.unlock()
            XCTAssertNil(store.saved, "\(answer)")
        }
    }

    func testNothingSavedOnALockedDeviceTriesNothing() {
        lockDevice()
        expectError(.devicePasscodeNotSaved, .conflict) { _ = try unlocker.unlock() }
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertTrue(screen.presses.isEmpty, "nothing is pressed either")
    }

    func testAnUnlockedDeviceIsLeftAsItIs() throws {
        XCTAssertEqual(try unlocker.unlock(), LockState(locked: false, screenOff: false))
        XCTAssertTrue(screen.presses.isEmpty)
        XCTAssertEqual(keybag.statusReads, 0)
        screen.screenOff = true
        XCTAssertEqual(try unlocker.unlock(), LockState(locked: false, screenOff: false))
        XCTAssertEqual(screen.presses, ["wake"], "a dark unlocked screen is only woken")
    }

    func testADeviceWithoutAPasscodeIsWokenAndTakenHome() throws {
        keybag.devicePasscode = nil
        lockDevice()
        XCTAssertEqual(try unlocker.unlock(), LockState(locked: false, screenOff: false))
        XCTAssertTrue(keybag.attempts.isEmpty)
        XCTAssertEqual(screen.presses.first, "wake")
        XCTAssertEqual(screen.presses.last, "home")
    }

    /// The way each unlock went, which the agent says: never the passcode
    /// where none was used.
    func testAnUnlockSaysTheWayItWent() throws {
        XCTAssertEqual(try unlocker.unlockReporting().path, .nothing, "unlocked and lit")
        screen.screenOff = true
        XCTAssertEqual(try unlocker.unlockReporting().path, .wake, "unlocked and dark")
        keybag.devicePasscode = nil
        lockDevice()
        XCTAssertEqual(
            try unlocker.unlockReporting(),
            DeviceUnlock.UnlockAnswer(state: LockState(locked: false, screenOff: false), path: .lockScreen),
            "no passcode: woken and past the Lock Screen",
        )
        XCTAssertTrue(keybag.attempts.isEmpty)
    }

    func testAnUnlockWithTheSavedPasscodeSaysSo() throws {
        _ = try unlocker.saveAndTest("1472")
        lockDevice()
        XCTAssertEqual(try unlocker.unlockReporting().path, .passcode)
        XCTAssertEqual(keybag.attempts.last, "1472")
    }

    func testALockScreenThatStaysIsAnsweredNotTypedInto() throws {
        _ = try unlocker.saveAndTest("1472")
        lockDevice()
        screen.uiUnlocks = false
        let left = try unlocker.unlock()
        XCTAssertEqual(left, LockState(locked: true, screenOff: false))
        XCTAssertEqual(screen.swipes, 1, "Home, then one swipe")
        XCTAssertEqual(store.saved?.stage, .verified, "the keybag took it")
    }

    func testPressesFromTwoCallersTakeTurnsAndARejectionStopsBoth() throws {
        _ = try unlocker.saveAndTest("1472")
        keybag.devicePasscode = "2580"
        keybag.attempts = []
        lockDevice()
        let shared = try XCTUnwrap(unlocker)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in _ = try? shared.unlock() }
        XCTAssertEqual(keybag.attempts, ["1472"])
    }

    func testStateReadsTheDevice() throws {
        XCTAssertEqual(try unlocker.state(), DevicePasscodeState(saved: false, device: .passcode))
        _ = try unlocker.saveAndTest("1472")
        XCTAssertEqual(try unlocker.state(), DevicePasscodeState(saved: true, device: .passcode))
        try unlocker.remove()
        XCTAssertEqual(try unlocker.state(), DevicePasscodeState(saved: false, device: .passcode))
        keybag.outdated = true
        XCTAssertEqual(try unlocker.state().device, .icliOutdated)
    }

    // MARK: The wire

    /// An unlock takes no target, and Apelin beneath the Lock Screen does not
    /// refuse it: it ends on the Home Screen.
    func testTheUnlockPressGoesByTheWorker() async throws {
        keybag.devicePasscode = nil
        lockDevice()
        var service = DiagnosticsService(
            diagnostics: quick(screen),
            host: ApelinService(transport: NoAnswer()),
            home: "/nonexistent",
            installRoot: "/",
        )
        service.deviceUnlock = unlocker
        let left = try await service.uiAction(.init(action: .press(button: "unlock"), refusedBundleIDs: ["wiki.qaq.apelin"]))
        // a device without a passcode: past the Lock Screen, and said so
        XCTAssertEqual(left, ApelinProtocol.UIActionResponse(locked: false, screenOff: false, unlockedBy: .lockScreen))
        do {
            _ = try await service.uiAction(.init(targetID: "com.apple.Preferences", action: .press(button: "unlock")))
            XCTFail("a target was taken")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .badRequest)
        }
        do {
            _ = try await service.uiAction(.init(action: .press(button: "bogus")))
            XCTFail("an unknown button was pressed")
        } catch let error as ApelinError {
            XCTAssertTrue(error.message.contains("unlock"), error.message)
        }
    }
}

private struct NoAnswer: ApelinTransport {
    func call(_ request: WireRequest, descriptors _: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        (.failure(request.requestID, .unimplemented(request.operation)), [])
    }
}

/// Writes the mark, then fails every write after it: a success whose
/// clearing write was lost.
private final class MarkThenFail: DevicePasscodeStore, @unchecked Sendable {
    let inner: MemoryPasscodeStore
    let lock = NSLock()
    var marked = false

    init(inner: MemoryPasscodeStore) {
        self.inner = inner
    }

    func read() throws -> SavedPasscode? {
        try inner.read()
    }

    func write(_ saved: SavedPasscode) throws {
        let fail = lock.withLock {
            defer {
                if saved.stage == .attempting {
                    marked = true
                }
            }
            return marked
        }
        if fail {
            throw ApelinError(.unavailable, "the keychain is locked")
        }
        try inner.write(saved)
    }

    func remove() throws {
        try inner.remove()
    }
}

// MARK: - icli's command line

/// The real runner, against a script standing in for icli: what it is
/// given, how its statuses read, and that a run past its time is killed.
final class IcliPasscodeCommandTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("icli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A stand-in icli that writes its argv and its first line of input to
    /// files beside it, then runs `body`.
    private func command(_ body: String, timeout: TimeInterval = 10) throws -> IcliPasscodeCommand {
        let script = folder.appendingPathComponent("icli")
        let text = """
        #!/bin/sh
        dir=$(dirname "$0")
        printf '%s\\n' "$@" > "$dir/argv"
        IFS= read -r line
        printf '%s' "$line" > "$dir/input"
        \(body)
        """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return IcliPasscodeCommand(executable: script.path, environment: ["PATH=/usr/bin:/bin"], timeout: timeout, owner: getuid())
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
    }

    func testThePasscodeGoesOnStandardInputAndNeverInArgv() throws {
        let icli = try command(#"echo '{"result":"unlocked","attempted":true,"status":0,"hint":"The keybag is unlocked."}'; exit 0"#)
        let answer = icli.unlock(passcode: "14 72")
        XCTAssertEqual(answer.outcome, .unlocked(attempted: true))
        XCTAssertEqual(try read("input"), "14 72")
        let argv = try read("argv")
        XCTAssertEqual(argv, "device\npasscode\nunlock\n--passcode-stdin\n--max-failures\n1\n")
        XCTAssertFalse(argv.contains("1472") || argv.contains("14 72"))
    }

    func testEachStatusReadsAsIcliPromisesAndNothingElseIsBelieved() throws {
        let cases: [(String, UnlockAnswer.Outcome)] = [
            (#"echo '{"result":"unlocked","attempted":false}'; exit 0"#, .unlocked(attempted: false)),
            (#"echo '{"result":"rejected","attempted":true}'; exit 3"#, .rejected),
            (#"echo '{"result":"rejected_cached","attempted":false}'; exit 4"#, .rejectedBefore),
            (#"echo '{"result":"refused","attempted":false}'; exit 5"#, .refused),
            (#"echo '{"result":"system_error","attempted":true}'; exit 6"#, .unknown),
            (#"echo '{"error":"failed","message":"boom"}'; exit 1"#, .unknown),
            (#"echo '{"result":"unlocked","attempted":true}'; exit 3"#, .unknown),
            (#"echo '{"result":"refused","attempted":true}'; exit 5"#, .unknown),
            (#"echo 'not json'; exit 0"#, .unknown),
            (#"kill -9 $$"#, .unknown),
        ]
        for (body, expected) in cases {
            XCTAssertEqual(try command(body).unlock(passcode: "1472").outcome, expected, body)
        }
    }

    func testARunPastItsTimeIsKilledAndKeepsNoPromise() throws {
        let start = Date()
        let answer = try command("sleep 20", timeout: 0.5).unlock(passcode: "1472")
        XCTAssertEqual(answer.outcome, .unknown)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testStatusReadsTheKeybagAndAnOldIcliSaysSo() throws {
        let status = try command(#"echo '{"lock_state":2,"failed_attempts":0,"backoff_seconds":0,"ledger_failures":1,"recovery_countdown":0}'"#).status()
        XCTAssertEqual(status, KeybagStatus(lockState: 2, failedAttempts: 0, ledgerFailures: 1))
        XCTAssertEqual(try read("argv"), "device\npasscode\nstatus\n")
        XCTAssertEqual(try read("input"), "", "no input for a status")
        XCTAssertThrowsError(try command("echo 'Error: Unexpected argument' >&2; exit 64").status()) { error in
            XCTAssertEqual(error as? KeybagFailure, .outdated)
        }
        XCTAssertThrowsError(try command("echo '{}'").status())
        let unreadable = try command(#"echo '{"lock_state":2,"failed_attempts":true}'"#).status()
        XCTAssertNil(unreadable.failedAttempts, "a count that is no number is no count")
        XCTAssertNotNil(unreadable.refusal)
    }

    func testAnOldIcliTriesNothing() throws {
        XCTAssertEqual(try command("exit 64").unlock(passcode: "1472").outcome, .refused)
    }

    func testForgetAsksWithForce() throws {
        try command("echo '{}'").forgetRejected()
        XCTAssertEqual(try read("argv"), "device\npasscode\nforget\n--force\n")
        XCTAssertThrowsError(try command("exit 1").forgetRejected())
    }

    func testAnExecutableOthersMayWriteIsNeverHandedAPasscode() throws {
        let icli = try command("echo '{}'")
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: icli.executable)
        let answer = icli.unlock(passcode: "1472")
        XCTAssertEqual(answer.outcome, .refused, "not started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input").path))
        let link = folder.appendingPathComponent("link")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: icli.executable)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: icli.executable)
        let linked = IcliPasscodeCommand(executable: link.path, environment: [], timeout: 5, owner: getuid())
        XCTAssertEqual(linked.unlock(passcode: "1472").outcome, .refused, "a link is not the file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("input").path))
        let missing = IcliPasscodeCommand(executable: folder.appendingPathComponent("none").path, environment: [], timeout: 5, owner: getuid())
        XCTAssertThrowsError(try missing.status())
    }
}
