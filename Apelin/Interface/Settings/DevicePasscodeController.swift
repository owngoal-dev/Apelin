import ApelinProtocol
import SPIndicator
import UIKit

/// Settings ▸ Agent ▸ Device Passcode (owner, 2026-11-21): the passcode the
/// agent's unlock uses (`uiAction` `press` `unlock`), kept by
/// apelin-diagnostics in its own keychain group. It is saved only once a
/// test, which locks the device and has icli unlock it with the passcode,
/// passed; the field is emptied whatever the test answered. A device with no
/// passcode needs none, and an icli too old to unlock says so.
final class DevicePasscodeController: TableController {
    private enum Section: Hashable {
        case status
        case entry
        case saved
    }

    private enum RowID: Hashable {
        case status
        case field
        case test
        case remove
    }

    /// What the status row says.
    private enum Status: Equatable {
        case checking
        case testing
        case saved
        case notSaved
        case notNeeded
        case unavailable
    }

    private struct Row: Equatable {
        let id: RowID
        var status: Status?
        var enabled = true
    }

    private lazy var dataSource = TableDataSource<Section, RowID, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    /// What apelin-diagnostics last answered; nil until it has.
    private var state: DevicePasscodeState?
    @objc private dynamic var failure: Error?
    @objc private dynamic var isTesting = false
    private var loader: Task<Void, Never>?
    @objc private dynamic var activation: NSObjectProtocol?
    /// What waits for the reader to be back in Apelin: a test's answer
    /// arrives while the app comes back from behind the Lock Screen.
    private var onActive: [() -> Void] = []

    private let passcodeField = UITextField()
    @objc private dynamic lazy var fieldCell = GitSettingsController.cell(containing: passcodeField)

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit {
        loader?.cancel()
        if let activation {
            NotificationCenter.default.removeObserver(activation)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Device Passcode")
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        passcodeField.font = .preferredFont(forTextStyle: .body)
        passcodeField.adjustsFontForContentSizeCategory = true
        passcodeField.isSecureTextEntry = true
        passcodeField.autocorrectionType = .no
        passcodeField.autocapitalizationType = .none
        passcodeField.spellCheckingType = .no
        passcodeField.smartDashesType = .no
        passcodeField.smartQuotesType = .no
        passcodeField.clearButtonMode = .whileEditing
        passcodeField.returnKeyType = .go
        passcodeField.placeholder = String(localized: "Enter device passcode")
        passcodeField.accessibilityLabel = String(localized: "Device Passcode")
        passcodeField.addAction(UIAction { [weak self] _ in self?.updateRows() }, for: .editingChanged)
        passcodeField.addAction(UIAction { [weak self] _ in self?.confirmTest() }, for: .editingDidEndOnExit)
        dataSource.footerTitle = { [weak self] section in self?.footer(for: section) }
        updateRows()
        // The test locks the device; whatever it left is read again when
        // the reader comes back.
        activation = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc private dynamic func becameActive() {
        let waiting = onActive
        onActive = []
        waiting.forEach { $0() }
        if viewIfLoaded?.window != nil, !isTesting {
            load()
        }
    }

    private func whenActive(_ action: @escaping () -> Void) {
        if UIApplication.shared.applicationState == .active {
            action()
        } else {
            onActive.append(action)
        }
    }

    // MARK: - Loading

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let answer = try await ApelinService.app.devicePasscodeState()
                guard !Task.isCancelled, let self else { return }
                state = answer
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            self?.updateRows()
        }
    }

    private var status: Status {
        if isTesting {
            return .testing
        }
        guard let state else {
            return failure == nil ? .checking : .unavailable
        }
        if state.saved {
            return .saved
        }
        switch state.device {
        case .noPasscode: return .notNeeded
        case .icliOutdated: return .unavailable
        case .passcode, .unknown: return .notSaved
        }
    }

    @objc private dynamic var canTest: Bool {
        !isTesting && DevicePasscode.problem(passcodeField.text ?? "") == nil
    }

    @objc private dynamic func updateRows() {
        passcodeField.isEnabled = !isTesting
        let status = status
        var sections: [(Section, [Row])] = [(.status, [Row(id: .status, status: status)])]
        switch status {
        case .saved:
            sections.append((.saved, [Row(id: .remove, enabled: !isTesting)]))
        case .notSaved, .testing:
            sections.append((.entry, [Row(id: .field), Row(id: .test, enabled: canTest)]))
        case .checking, .notNeeded, .unavailable:
            break
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .status:
            switch status {
            case .notNeeded:
                String(localized: "This device has no passcode, so the agent can unlock it without one.")
            case .unavailable where state?.device == .icliOutdated:
                String(localized: "Unlocking with a passcode requires icli 0.11.0 or later. Update icli using your preferred package manager.")
            case .unavailable:
                failure?.readableMessage
            default:
                String(localized: "With a saved passcode, the agent can wake the screen, unlock this device and go to the Home Screen during testing. The passcode stays in this device’s keychain, and the agent never sees it.")
            }
        case .entry:
            String(localized: "To test the passcode before saving, Apelin locks the screen and tries this passcode only once to unlock it. A wrong passcode counts as one failed passcode attempt on this device.")
        case .saved:
            String(localized: "If you change this device’s passcode, remove the saved passcode here and save the new one.")
        }
    }

    // MARK: - Testing

    @objc private dynamic func confirmTest() {
        guard canTest else { return }
        let passcode = passcodeField.text ?? ""
        view.endEditing(true)
        presentConfirmation(
            title: "Test Device Passcode?",
            message: "Apelin will lock the screen and unlock it with this passcode. Don’t use the device until it unlocks. A wrong passcode counts as one failed attempt.",
            confirmTitle: "Lock and Test",
        ) { [weak self] in
            self?.startTest(passcode)
        }
    }

    @objc private dynamic func startTest(_ passcode: String) {
        passcodeField.text = ""
        isTesting = true
        updateRows()
        Task { [weak self] in
            let answer: Result<DevicePasscodeSaveResponse, Error>
            do {
                answer = try await .success(ApelinService.app.devicePasscodeSave(DevicePasscodeSaveRequest(passcode: passcode)))
            } catch {
                answer = .failure(error)
            }
            // The device locked meanwhile: say what happened once the reader
            // is back in Apelin.
            self?.whenActive { [weak self] in self?.finishTest(answer) }
        }
    }

    private func finishTest(_ answer: Result<DevicePasscodeSaveResponse, Error>) {
        isTesting = false
        switch answer {
        case let .success(response):
            state = response.state
            failure = nil
            updateRows()
            report(response.outcome)
        case let .failure(error):
            updateRows()
            Task { [weak self] in await self?.reportLost(error) }
        }
    }

    private func report(_ outcome: DevicePasscodeTestOutcome) {
        switch outcome {
        case .saved:
            SPIndicator.present(title: String(localized: "Passcode Saved"), preset: .done, haptic: .success)
        case .noPasscode:
            presentNotice(title: "No Passcode Needed", message: "This device has no passcode, so the agent can unlock it without one.")
        case .rejected:
            presentNotice(title: "Passcode Not Saved", message: "This passcode didn’t unlock the device and counted as one failed attempt. Check the passcode and try again.")
        case .refused:
            presentNotice(title: "Passcode Not Tested", message: "This device has a failed passcode attempt on record, so Apelin didn’t try the passcode. Unlock the device with its passcode, then try again.")
        case .didNotLock:
            presentNotice(title: "Passcode Not Tested", message: "After locking, the device didn’t ask for its passcode in time, so Apelin didn’t try it. Make sure Require Passcode is set to Immediately, then try again.")
        case .icliOutdated:
            presentNotice(title: "Update icli", message: "Unlocking with a passcode requires icli 0.11.0 or later. Update icli using your preferred package manager.")
        case .failed:
            presentNotice(title: "Passcode Not Saved", message: "The unlock test didn’t finish, so the passcode wasn’t saved. Try again.")
        }
    }

    /// The reply did not come (the app was away longer than a call waits,
    /// or the service restarted): what the test left is read instead.
    private func reportLost(_ error: Error) async {
        if let refusal = error as? ApelinError, refusal.code == .badRequest {
            presentNotice(title: "Passcode Not Saved", message: refusal.message)
            return
        }
        do {
            let answer = try await ApelinService.app.devicePasscodeState()
            state = answer
            failure = nil
            updateRows()
            report(answer.saved ? .saved : .failed)
        } catch {
            failure = error
            updateRows()
            report(.failed)
        }
    }

    // MARK: - Removing

    @objc private dynamic func confirmRemoval() {
        presentConfirmation(
            title: "Remove Device Passcode?",
            message: "The agent will no longer be able to unlock this device.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            self?.removePasscode()
        }
    }

    @objc private dynamic func removePasscode() {
        Task { [weak self] in
            do {
                try await ApelinService.app.devicePasscodeRemove()
                SPIndicator.present(title: String(localized: "Removed"), preset: .done, haptic: .success)
            } catch {
                self?.presentNotice(title: "Unable to Remove Passcode", message: error.readableMessage)
            }
            self?.load()
        }
    }

    // MARK: - Table

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row.id {
        case .status:
            let cell = tableView.dequeueReusableCell(withIdentifier: "status")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "status")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Status")
            content.secondaryText = row.status.map(Self.title)
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .field:
            return fieldCell
        case .test, .remove:
            let cell = tableView.dequeueReusableCell(withIdentifier: "action")
                ?? UITableViewCell(style: .default, reuseIdentifier: "action")
            var content = cell.defaultContentConfiguration()
            let removing = row.id == .remove
            content.text = removing ? String(localized: "Remove Passcode") : String(localized: "Test and Save")
            content.textProperties.color = row.enabled ? (removing ? .systemRed : .tintColor) : .tertiaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = row.enabled ? .default : .none
            cell.accessibilityTraits = row.enabled ? [.button] : [.button, .notEnabled]
            return cell
        }
    }

    private static func title(_ status: Status) -> String {
        switch status {
        case .checking: String(localized: "Checking…")
        case .testing: String(localized: "Testing…")
        case .saved: String(localized: "Saved")
        case .notSaved: String(localized: "Not Saved")
        case .notNeeded: String(localized: "Not Needed")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return false }
        return (row.id == .test || row.id == .remove) && row.enabled
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath), row.enabled else { return }
        switch row.id {
        case .test: confirmTest()
        case .remove: confirmRemoval()
        case .field: passcodeField.becomeFirstResponder()
        case .status: break
        }
    }
}
