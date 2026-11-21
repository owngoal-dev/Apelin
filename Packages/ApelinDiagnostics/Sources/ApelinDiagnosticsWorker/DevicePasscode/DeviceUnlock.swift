import ApelinCore
import ApelinDiagnostics
import ApelinProtocol
import Foundation

/// The device passcode's keeper and its one user (owner, 2026-11-21): Test
/// and Save from Settings, and the unlock an agent presses.
///
/// Nothing here may lock the device out. Before any attempt, icli's status
/// must read zero failed attempts on the device's own counter (which only a
/// successful unlock clears), no back-off and no block, and the attempt
/// itself runs with icli's `--max-failures 1`, which checks the same again
/// under icli's lock on its ledger. So an attempt is made only while no
/// failure is on record, and a wrong passcode costs one attempt, after which
/// nothing more is tried — by this process, another apelin-diagnostics or a
/// script running icli — until a person unlocks the device. On top of that,
/// a passcode is kept only once a test unlocked the device with it; it is
/// marked `attempting` before each use and dropped unless that use is seen
/// to unlock or to try nothing, so a rejection, a crash or a kill mid-attempt
/// leaves no passcode to try again. One call at a time, in this process.
struct DeviceUnlock: Sendable {
    let diagnostics: Diagnostics
    let keybag: any PasscodeKeybag
    let store: any DevicePasscodeStore
    /// Shared by every copy: the worker makes one and hands it to each request.
    let serial: PthreadLock
    /// How long the test waits for the keybag to lock after the side button.
    var lockWait: TimeInterval = 15
    var pollInterval: TimeInterval = 0.5
    /// How long passing the Lock Screen waits after each step.
    var settle: TimeInterval = 1.5

    init(
        diagnostics: Diagnostics,
        keybag: any PasscodeKeybag,
        store: any DevicePasscodeStore,
        serial: PthreadLock = PthreadLock(),
    ) {
        self.diagnostics = diagnostics
        self.keybag = keybag
        self.store = store
        self.serial = serial
    }

    // MARK: Settings

    /// Whether a usable passcode is saved, and what the device is. A saved
    /// passcode whose last attempt nobody saw end is dropped here.
    func state() throws -> DevicePasscodeState {
        try serial.withLock {
            try DevicePasscodeState(saved: usablePasscode() != nil, device: device())
        }
    }

    func remove() throws {
        try serial.withLock { try store.remove() }
    }

    /// Saves and tests `passcode`: the device locks, and icli unlocks it with
    /// the passcode, once. It is saved only when that attempt unlocked the
    /// device. A passcode already saved stays unless this one replaces it.
    func saveAndTest(_ passcode: String) throws -> DevicePasscodeSaveResponse {
        if let problem = DevicePasscode.problem(passcode) {
            throw ApelinError(.badRequest, "The passcode cannot be tested: \(problem).")
        }
        return try serial.withLock {
            let outcome = test(passcode)
            let failures = outcome.outcome == .rejected ? (try? keybag.status())?.failedAttempts : nil
            return try DevicePasscodeSaveResponse(
                outcome: outcome.outcome,
                failedAttempts: failures,
                detail: outcome.detail,
                state: DevicePasscodeState(saved: usablePasscode() != nil, device: device()),
            )
        }
    }

    private func test(_ passcode: String) -> (outcome: DevicePasscodeTestOutcome, detail: String) {
        let before: KeybagStatus
        do {
            before = try keybag.status()
        } catch let failure as KeybagFailure {
            return failure == .outdated ? (.icliOutdated, failure.detail) : (.failed, failure.detail)
        } catch {
            return (.failed, "\(error)")
        }
        if before.hasNoPasscode {
            return (.noPasscode, "the device has no passcode")
        }
        guard before.lockState == 0 else {
            return (.failed, "the device's keybag is locked; the test starts from an unlocked device")
        }
        if let refusal = before.refusal {
            return (.refused, refusal)
        }
        // The user typed this passcode just now on an unlocked device whose
        // counter reads zero: whatever icli's ledger remembers of earlier
        // passcodes (one the device's own passcode may have become since),
        // this attempt can bring the count to one at most.
        if before.ledgerFailures > 0 {
            do {
                try keybag.forgetRejected()
            } catch {
                return (.failed, "\(error)")
            }
        }

        do {
            try diagnostics.pressLock()
        } catch {
            return (.failed, "the device could not be locked: \(error)")
        }
        guard let locked = waitForKeybagLock() else {
            // Still unlocked, so nothing asks for the passcode: back to Apelin.
            _ = try? diagnostics.wake()
            _ = try? diagnostics.passLockScreen(settle: settle)
            return (.didNotLock, "the device's keybag did not lock within \(Int(lockWait)) s of the side button")
        }
        if let refusal = locked.refusal {
            _ = try? diagnostics.wake()
            return (.refused, refusal)
        }

        let answer = keybag.unlock(passcode: passcode)
        switch answer.outcome {
        case .unlocked(attempted: true):
            do {
                try store.write(SavedPasscode(passcode: passcode, stage: .verified))
            } catch {
                _ = try? diagnostics.passLockScreen(settle: settle)
                return (.failed, "the passcode unlocked the device, but it could not be saved: \(error)")
            }
            _ = try? diagnostics.wake()
            _ = try? diagnostics.passLockScreen(settle: settle)
            return (.saved, answer.detail)
        case .unlocked(attempted: false):
            // Unlocked before icli tried: no test took place.
            _ = try? diagnostics.wake()
            _ = try? diagnostics.passLockScreen(settle: settle)
            return (.didNotLock, "the device unlocked before the passcode was tried: \(answer.detail)")
        case .refused:
            _ = try? diagnostics.wake()
            return (.refused, answer.detail)
        case .rejected, .rejectedBefore:
            _ = try? diagnostics.wake()
            return (.rejected, answer.detail)
        case .unknown:
            _ = try? diagnostics.wake()
            return (.failed, answer.detail)
        }
    }

    /// icli's status once the keybag reads locked, or nil after `lockWait`.
    private func waitForKeybagLock() -> KeybagStatus? {
        let deadline = Date().addingTimeInterval(lockWait)
        repeat {
            Thread.sleep(forTimeInterval: pollInterval)
            if let status = try? keybag.status(), !status.keybagUnlocked {
                return status
            }
        } while Date() < deadline
        return nil
    }

    // MARK: The agent's unlock

    /// `uiAction` `press` `unlock`: wakes the device, unlocks its keybag
    /// with the saved passcode when it is locked, passes the Lock Screen and
    /// presses Home. A device already unlocked and lit is left as it is; one
    /// unlocked with its screen off is only woken. Answers what it left.
    func unlock() throws -> LockState {
        try serial.withLock {
            let lock = diagnostics.lockState()
            guard lock.locked else {
                return lock.screenOff ? try diagnostics.wake() : lock
            }
            let status: KeybagStatus
            do {
                status = try keybag.status()
            } catch let failure as KeybagFailure {
                throw ApelinError(.unavailable, "The device could not be unlocked: \(failure.detail).")
            }
            if !status.keybagUnlocked {
                try unlockKeybag(status)
            }
            try diagnostics.wake()
            let left = try diagnostics.passLockScreen(settle: settle)
            guard !left.locked else { return left }
            // The Lock Screen going is an app switch, and a Home press made
            // during it is lost (on the iOS 27 vphone the app beneath stayed
            // in front): Home only once the app in front has settled.
            _ = diagnostics.settledForegroundApp()
            try diagnostics.pressHome()
            return diagnostics.lockState()
        }
    }

    /// One attempt with the saved passcode, or a refusal with nothing tried.
    private func unlockKeybag(_ status: KeybagStatus) throws {
        guard let saved = try usablePasscode() else {
            throw ApelinError(
                .conflict,
                "The device is locked, and no tested passcode is saved in Apelin's Settings, so nothing was tried. Ask the user to unlock the device.",
                reason: .devicePasscodeNotSaved,
            )
        }
        if let refusal = status.refusal {
            throw ApelinError(
                .conflict,
                "Nothing was tried: \(refusal). Ask the user to unlock the device.",
                reason: .devicePasscodeRefused,
            )
        }
        // icli would refuse too (`--max-failures 1`). Only a Test and Save,
        // a passcode the user types, clears icli's ledger; an unlock never.
        if status.ledgerFailures > 0 {
            throw ApelinError(
                .conflict,
                "Nothing was tried: icli has a rejected passcode on record. Ask the user to unlock the device, and to save and test the passcode again in Apelin's Settings, which clears that record.",
                reason: .devicePasscodeRefused,
            )
        }
        // Marked first: an attempt whose end nobody sees drops the passcode.
        try store.write(SavedPasscode(passcode: saved.passcode, stage: .attempting))
        let answer = keybag.unlock(passcode: saved.passcode)
        switch answer.outcome {
        case .unlocked:
            clearMark(saved)
        case .refused:
            clearMark(saved)
            throw ApelinError(
                .conflict,
                "Nothing was tried: \(Self.clause(answer.detail)). Ask the user to unlock the device.",
                reason: .devicePasscodeRefused,
            )
        case .rejected, .rejectedBefore, .unknown:
            try? store.remove()
            throw ApelinError(
                .denied,
                "The saved passcode did not unlock the device (\(Self.clause(answer.detail))), so Apelin removed it and will not try it again. Ask the user to unlock the device, and to save and test the passcode again in Settings if it changed.",
                reason: .devicePasscodeRejected,
            )
        }
    }

    /// Takes back the mark this use wrote, and only that: a passcode another
    /// use dropped meanwhile (another apelin-diagnostics, whose attempt was
    /// rejected) stays dropped.
    private func clearMark(_ saved: SavedPasscode) {
        let marked = SavedPasscode(passcode: saved.passcode, stage: .attempting)
        guard (try? store.read()) == marked else { return }
        try? store.write(SavedPasscode(passcode: saved.passcode, stage: .verified))
    }

    /// icli's sentence as a clause: no final full stop, never empty.
    private static func clause(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let clause = trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
        return clause.isEmpty ? "icli gave no reason" : clause
    }

    // MARK: Reading

    /// The saved passcode when it is usable. One left `attempting` is
    /// dropped: its attempt's end was never seen.
    private func usablePasscode() throws -> SavedPasscode? {
        guard let saved = try store.read() else { return nil }
        guard saved.stage == .verified else {
            try? store.remove()
            return nil
        }
        return saved
    }

    private func device() -> DevicePasscodeDevice {
        do {
            return try keybag.status().hasNoPasscode ? .noPasscode : .passcode
        } catch KeybagFailure.outdated {
            return .icliOutdated
        } catch {
            return .unknown
        }
    }
}
