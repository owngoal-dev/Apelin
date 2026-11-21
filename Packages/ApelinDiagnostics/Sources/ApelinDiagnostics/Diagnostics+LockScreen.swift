import Foundation

/// The steps of an unlock (`uiAction` `press` `unlock`) and of the device
/// passcode's test, on the screen alone. Unlike `perform`, they run while
/// the device is locked: they are how it is left. None of them types or
/// reads a passcode; the keybag is the worker's, through icli's command.
public extension Diagnostics {
    /// icli's `locked` and `screen_off` now.
    func lockState() -> LockState {
        Self.decodeLock(icli.lockState())
    }

    /// icli's wake: the screen lit, and a device without a passcode past its
    /// Lock Screen. Answers what it left.
    @discardableResult
    func wake() throws -> LockState {
        try Self.decodeLock(icli.pressButton(HardwareButton.wake.icliName))
    }

    /// The side button: the screen goes off and the device locks.
    func pressLock() throws {
        _ = try icli.pressButton(HardwareButton.lock.icliName)
    }

    /// Home, whatever is in front: from an app, the Home Screen.
    func pressHome() throws {
        _ = try icli.pressButton(HardwareButton.home.icliName)
    }

    /// Past a lit Lock Screen whose keybag is already unlocked: Home, then,
    /// on a device that answers a swipe rather than Home (Face ID), one
    /// swipe up from the bottom edge, each followed by up to `settle`
    /// seconds for the lock to go. Answers what it left; a Lock Screen that
    /// stays asks the user, and nothing here types into it.
    @discardableResult
    func passLockScreen(settle: TimeInterval = 1.5, interval: TimeInterval = 0.25) throws -> LockState {
        var state = lockState()
        guard state.locked else { return state }
        try pressHome()
        state = waitForUnlock(within: settle, interval: interval)
        guard state.locked, !state.screenOff else { return state }
        let screen = icli.screenInfo()
        let width = (screen["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (screen["height"] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return state }
        _ = try icli.swipe(x1: width / 2, y1: height - 2, x2: width / 2, y2: height * 0.4, seconds: 0.25)
        return waitForUnlock(within: settle, interval: interval)
    }

    /// The lock state once it reads unlocked, or after `seconds`.
    private func waitForUnlock(within seconds: TimeInterval, interval: TimeInterval) -> LockState {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let state = lockState()
            if !state.locked || Date() >= deadline {
                return state
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
