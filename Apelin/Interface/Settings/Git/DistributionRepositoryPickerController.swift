import ApelinProtocol
import Then
import UIKit

/// The signed-in account's own repositories, most recently updated first,
/// to link one as the package repository. A row says whether it is private
/// (Pages for a private repository needs a paid plan) and whether it has a
/// Pages site already.
final class DistributionRepositoryPickerController: TableController {
    private enum Row: Hashable {
        case loading
        case unavailable(String)
        case empty
        case repository(DistributionRepositoryCandidate)
    }

    private lazy var dataSource = TableDataSource<Int, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    private let onPick: (DistributionRepositoryCandidate) -> Void
    private var loader: Task<Void, Never>?

    init(onPick: @escaping (DistributionRepositoryCandidate) -> Void) {
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(onPick:)")
    }

    deinit {
        loader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Link Repository")
        navigationItem.largeTitleDisplayMode = .never
        dataSource.footerTitle = { _ in
            String(localized: "Choose the repository your packages go to. Apelin adds what the package index needs and leaves everything else as it is.")
        }
        dataSource.update([(0, [.loading])])
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            let rows: [Row]
            do {
                let list = try await ApelinService.app.distributionRepositoryList(repositories: true)
                rows = list.repositories.isEmpty ? [.empty] : list.repositories.map(Row.repository)
            } catch {
                rows = [.unavailable(error.readableMessage)]
            }
            guard !Task.isCancelled, let self else { return }
            dataSource.update([(0, rows)])
        }
    }

    private func cell(for row: Row) -> UITableViewCell {
        switch row {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Repositories Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .empty:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "This account has no repositories of its own.")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case let .repository(candidate):
            return RepositoryCandidateCell(candidate: candidate)
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        if case .repository? = dataSource.value(at: indexPath) {
            return true
        }
        return false
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case let .repository(candidate)? = dataSource.value(at: indexPath) else { return }
        onPick(candidate)
    }
}

/// Repository identity and description, followed by separate capability badges.
private final class RepositoryCandidateCell: UITableViewCell {
    private let badges = UIStackView()

    init(candidate: DistributionRepositoryCandidate) {
        super.init(style: .default, reuseIdentifier: nil)
        accessoryType = .disclosureIndicator
        let style = UIListContentConfiguration.explanatoryCell()
        let title = UILabel()
        title.text = candidate.fullName
        title.font = style.textProperties.font
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.setContentHuggingPriority(.required, for: .vertical)
        let stack = UIStackView(arrangedSubviews: [title])
        stack.axis = .vertical
        stack.spacing = 8
        let description = candidate.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let description, !description.isEmpty {
            let subtitle = UILabel()
            subtitle.text = description
            subtitle.font = style.secondaryTextProperties.font
            subtitle.adjustsFontForContentSizeCategory = true
            subtitle.textColor = .secondaryLabel
            subtitle.numberOfLines = 2
            subtitle.setContentHuggingPriority(.required, for: .vertical)
            stack.addArrangedSubview(subtitle)
            stack.setCustomSpacing(style.textToSecondaryTextVerticalPadding, after: title)
        }
        badges.spacing = 8
        updateBadgeLayout()
        var states: [String] = []
        if candidate.isPrivate {
            let title = String(localized: "Private")
            badges.addArrangedSubview(RepositoryBadge(text: title, color: .systemPurple))
            states.append(title)
        }
        if candidate.hasPages {
            badges.addArrangedSubview(RepositoryBadge(text: String(localized: "GitHub Pages"), color: .systemBlue))
            states.append(String(localized: "Has GitHub Pages"))
        }
        if !states.isEmpty {
            let badgeContainer = UIView()
            badgeContainer.addSubview(badges)
            badges.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                badges.leadingAnchor.constraint(equalTo: badgeContainer.leadingAnchor),
                badges.trailingAnchor.constraint(lessThanOrEqualTo: badgeContainer.trailingAnchor),
                badges.topAnchor.constraint(equalTo: badgeContainer.topAnchor),
                badges.bottomAnchor.constraint(equalTo: badgeContainer.bottomAnchor),
            ])
            stack.addArrangedSubview(badgeContainer)
        }
        contentView.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: margins.topAnchor),
            stack.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = candidate.fullName
        accessibilityValue = ([description].compactMap(\.self).filter { !$0.isEmpty } + states).joined(separator: "\n")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(candidate:)")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBadgeLayout()
    }

    @objc private dynamic func updateBadgeLayout() {
        let stacked = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        badges.axis = stacked ? .vertical : .horizontal
        badges.alignment = stacked ? .leading : .center
    }
}

private final class RepositoryBadge: UILabel {
    private let padding = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)

    init(text: String, color: UIColor) {
        super.init(frame: .zero)
        self.text = text
        font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .medium))
        adjustsFontForContentSizeCategory = true
        textColor = color
        backgroundColor = color.withAlphaComponent(0.12)
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(text:color:)")
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + padding.left + padding.right, height: size.height + padding.top + padding.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
