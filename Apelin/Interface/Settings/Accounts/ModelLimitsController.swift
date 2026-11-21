import ApelinProtocol
import UIKit

/// One model's context window and largest reply, for an API-key account
/// (#68). A field left empty is automatic, and shows the value the model
/// resolves with where apelin-agent could read it. Saved per model, on the
/// device, only when the user taps Save.
final class ModelLimitsController: TableController {
    @objc dynamic var onSave: (() -> Void)?

    private let provider: AgentProvider
    private let model: String
    private let automatic: AgentModelLimits?
    private let windowField = UITextField()
    private let outputField = UITextField()
    private lazy var cells: [Section: UITableViewCell] = [
        .window: cell(containing: windowField),
        .output: cell(containing: outputField),
    ]

    private enum Section: Hashable {
        case window
        case output
    }

    private lazy var dataSource = TableDataSource<Section, Section, Section>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, section in
        self?.cells[section]
    }

    init(provider: AgentProvider, model: String, automatic: AgentModelLimits?) {
        self.provider = provider
        self.model = model
        self.automatic = automatic
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(provider:model:automatic:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = model
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.saveLimits() },
        )
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        let saved = ModelLimitsStore.limits(for: provider, model: model)
        configure(windowField, title: Self.title(.window), value: saved?.contextWindow, automatic: automatic?.contextWindow)
        configure(outputField, title: Self.title(.output), value: saved?.maxOutputTokens, automatic: automatic?.maxOutputTokens)
        // the automatic reply follows the window typed (at most a quarter of it)
        windowField.addAction(UIAction { [weak self] _ in self?.updateOutputPlaceholder() }, for: .editingChanged)
        updateOutputPlaceholder()
        dataSource.headerTitle = { Self.title($0) }
        dataSource.footerTitle = { section in
            switch section {
            case .window:
                let share = AgentContextBudget.automaticCompaction.formatted(.percent)
                return String(localized: "The total tokens a model can process at once. Apelin compacts the chat when the context reaches \(share) of this window.")
            case .output:
                return String(localized: "The maximum tokens one reply can use, including the model’s thinking. Leave a field empty to use the automatic value. A custom value cannot exceed what the server allows.")
            }
        }
        dataSource.update([(.window, [.window]), (.output, [.output])])
    }

    private static func title(_ section: Section) -> String {
        switch section {
        case .window: String(localized: "Context Window")
        case .output: String(localized: "Maximum Output")
        }
    }

    private func configure(_ field: UITextField, title: String, value: Int?, automatic: Int?) {
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.keyboardType = .numberPad
        field.clearButtonMode = .whileEditing
        field.accessibilityLabel = title
        // plain digits, which read back in every locale
        field.text = value.map(String.init)
        field.placeholder = Self.placeholder(automatic)
    }

    private static func placeholder(_ automatic: Int?) -> String {
        automatic.map { String(localized: "Automatic (\($0.formatted()))") } ?? String(localized: "Automatic")
    }

    /// The automatic reply a session would ask for with the window as it is
    /// typed: the model's own, at most a quarter of a window set
    /// (`AgentModelLimits.automaticOutput`).
    @objc private dynamic func updateOutputPlaceholder() {
        let typed: Int? = switch Self.number(in: windowField) {
        case let .success(window): window.flatMap { AgentModelLimits.contextWindowRange.contains($0) ? $0 : nil }
        case .failure: nil
        }
        outputField.placeholder = Self.placeholder(AgentModelLimits.automaticOutput(automatic?.maxOutputTokens, window: typed))
    }

    @objc private dynamic func cell(containing input: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        input.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(input)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            input.topAnchor.constraint(equalTo: margins.topAnchor),
            input.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case .window: windowField.becomeFirstResponder()
        case .output: outputField.becomeFirstResponder()
        case nil: break
        }
    }

    /// A field's number: nil when it is empty, and a failure when it holds
    /// anything but decimal digits, in any script the keyboard types, with
    /// the locale's grouping and spaces aside.
    private static func number(in field: UITextField) -> Result<Int?, Error> {
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",.'\u{2019}\u{066C}"))
        let scalars = (field.text ?? "").unicodeScalars.filter { !separators.contains($0) }
        guard !scalars.isEmpty else { return .success(nil) }
        var value = 0
        for scalar in scalars {
            guard scalar.properties.numericType == .decimal, let digit = scalar.properties.numericValue,
                  value <= (Int.max - Int(digit)) / 10
            else { return .failure(CocoaError(.formatting)) }
            value = value * 10 + Int(digit)
        }
        return .success(value)
    }

    @objc private dynamic func saveLimits() {
        view.endEditing(true)
        guard case let .success(window) = Self.number(in: windowField),
              case let .success(output) = Self.number(in: outputField)
        else {
            presentNotice(
                title: "Invalid Token Limit",
                message: "Enter a whole number of tokens, or leave the field empty to use the automatic value.",
            )
            return
        }
        let limits = AgentModelLimits(contextWindow: window, maxOutputTokens: output)
        let automaticWindow = automatic?.contextWindow
        if let problem = limits.problems(automaticWindow: automaticWindow).first {
            presentNotice(title: "Invalid Token Limit", message: Self.message(problem))
            return
        }
        confirm(limits.warnings(automaticWindow: automaticWindow)[...]) { [weak self] in
            self?.commit(limits)
        }
    }

    /// Asks about each warning in turn, then `save`s; Cancel on any saves
    /// nothing. One alert a warning, so each message is a catalogue key
    /// AlertController translates itself (a message it is given is looked
    /// up again, never shown as it is).
    private func confirm(_ warnings: ArraySlice<AgentModelLimits.Warning>, then save: @escaping () -> Void) {
        guard let warning = warnings.first else {
            save()
            return
        }
        presentConfirmation(title: "Save Token Limits?", message: Self.message(warning), confirmTitle: "Save") { [weak self] in
            self?.confirm(warnings.dropFirst(), then: save)
        }
    }

    private func commit(_ limits: AgentModelLimits) {
        ModelLimitsStore.save(limits, for: provider, model: model)
        onSave?()
        navigationController?.popViewController(animated: true)
    }

    // The catalogue keys AlertController looks up, with the numbers as
    // the locale writes them.

    private static func message(_ problem: AgentModelLimits.Problem) -> String.LocalizationValue {
        switch problem {
        case .contextWindowOutOfRange:
            let lower = AgentModelLimits.contextWindowRange.lowerBound.formatted()
            let upper = AgentModelLimits.contextWindowRange.upperBound.formatted()
            return "Enter a context window between \(lower) and \(upper) tokens."
        case .maxOutputOutOfRange:
            let lower = AgentModelLimits.maxOutputRange.lowerBound.formatted()
            let upper = AgentModelLimits.maxOutputRange.upperBound.formatted()
            return "Enter a maximum output between \(lower) and \(upper) tokens."
        case .outputNotBelowWindow:
            return "Enter a maximum output smaller than the context window."
        }
    }

    private static func message(_ warning: AgentModelLimits.Warning) -> String.LocalizationValue {
        switch warning {
        case .smallContextWindow:
            let small = AgentModelLimits.smallContextWindow.formatted()
            return "Apelin sends its instructions and tools with every request, so a context window under \(small) tokens leaves little room for the chat."
        case .outputTakesMostOfWindow:
            return "A maximum output above half the context window leaves little room for the chat, and Apelin will compact the chat sooner."
        case .smallMaxOutput:
            let small = AgentModelLimits.smallMaxOutput.formatted()
            return "A maximum output under \(small) tokens may cut off longer replies and the model’s thinking."
        }
    }
}
