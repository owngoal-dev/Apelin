import ApelinCore
import ApelinDiagnostics
import ApelinProtocol

extension DiagnosticsService {
    // MARK: UI

    /// The foreground is settled once, inside `blocking` (the wait sleeps),
    /// and that read both binds the target and stands for the read's own wait.
    func readUITree(_ tree: ApelinProtocol.ReadUITreeRequest) async throws -> ApelinProtocol.ReadUITreeResponse {
        let read = try await blocking {
            let front = try requireTarget(tree.targetID)
            return try mapped { try diagnostics.uiTree(UITreeRequest(), settled: front) }
        }
        return try ApelinProtocol.ReadUITreeResponse(tree: JSONValue(encoding: read))
    }

    /// A wake and an unlock answer the lock state they left, and a `type`
    /// what it left in the fields, read back from the tree; every other
    /// action, an empty reply.
    ///
    /// An unlock takes no target, and is not refused for an app on the
    /// refused list in front: while the device is locked that app is only
    /// the one beneath the Lock Screen (where the user locked it, Apelin
    /// most often), and an unlock leaves the Home Screen in front, never it.
    /// The session host's screen rules have let it through already.
    func uiAction(_ action: ApelinProtocol.UIActionRequest) async throws -> ApelinProtocol.UIActionResponse {
        if case let .press(button) = action.action, button == DevicePasscode.unlockButton {
            guard action.targetID == nil else {
                throw ApelinError(.badRequest, "An unlock acts on the whole device and takes no target.")
            }
            let passcodes = try requireDeviceUnlock()
            let left = try await blocking { try mapped { try passcodes.unlock() } }
            return ApelinProtocol.UIActionResponse(locked: left.locked, screenOff: left.screenOff)
        }
        let mappedAction = try Self.action(action.action)
        let outcome = try await blocking {
            let front = try requireTarget(action.targetID, refusing: action.refusedBundleIDs ?? [])
            return try mapped { try diagnostics.perform(mappedAction, settled: front) }
        }
        return ApelinProtocol.UIActionResponse(
            locked: outcome?.lock?.locked,
            screenOff: outcome?.lock?.screenOff,
            typedTextMatches: outcome?.typed?.matches,
            fieldValues: outcome?.typed?.fieldValues,
        )
    }

    /// An action is bound to the verified foreground app when a target is
    /// named; without one it goes to whatever is in front. An app in
    /// `refused` is never reached: named as the target, it is refused before
    /// anything is read, and in front — on the settled read, verified or
    /// not — it is refused too, even with no target, so the check and the
    /// action go by the same read. Answers the settled read it checked, nil
    /// when it read nothing. It waits: call it inside `blocking`.
    @discardableResult
    func requireTarget(_ targetID: String?, refusing refused: [String] = []) throws -> ForegroundApp? {
        if let targetID, refused.contains(targetID) {
            throw Self.refusal(targetID)
        }
        guard targetID != nil || !refused.isEmpty else { return nil }
        // Read once the app switch that brings it there, if any, is over:
        // with a target, once that app is the one in front.
        let front = diagnostics.settledForegroundApp(expecting: targetID)
        if refused.contains(front.bundleIdentifier) {
            throw Self.refusal(front.bundleIdentifier)
        }
        guard let targetID else { return front }
        guard front.verified, front.bundleIdentifier == targetID else {
            let seen = front.bundleIdentifier.isEmpty ? "unknown" : front.bundleIdentifier
            throw ApelinError(.conflict, "\(targetID) is not the verified foreground app after \(Int(diagnostics.settleTimeout)) s (\(seen))")
        }
        return front
    }

    private static func refusal(_ bundleID: String) -> ApelinError {
        ApelinError(.denied, "UI actions may not reach \(bundleID), so nothing was done: ask the user to do this there themselves")
    }

    static func action(_ action: ApelinProtocol.UIAction) throws -> ApelinDiagnosticsCore.UIAction {
        switch action {
        case let .tap(x, y):
            return .tap(UIPoint(x: x, y: y))
        case let .tapElement(text, identifier):
            return .tapElement(UIElementSelector(
                text: text,
                identifier: identifier,
                match: identifier == nil ? .exact : .contains,
            ))
        case let .type(text):
            return .type(text: text, delayMilliseconds: ApelinDiagnosticsCore.UIAction.defaultTypeDelayMilliseconds)
        case let .swipe(fromX, fromY, toX, toY, durationMilliseconds):
            return .swipe(
                from: UIPoint(x: fromX, y: fromY),
                to: UIPoint(x: toX, y: toY),
                seconds: Double(durationMilliseconds) / 1000,
            )
        case let .press(button):
            guard let pressed = HardwareButton(rawValue: button) else {
                let names = (HardwareButton.allCases.map(\.rawValue) + [DevicePasscode.unlockButton])
                    .joined(separator: ", ")
                throw ApelinError(.badRequest, "There is no \(button) button to press; the buttons are \(names).")
            }
            return .press(pressed)
        }
    }
}
