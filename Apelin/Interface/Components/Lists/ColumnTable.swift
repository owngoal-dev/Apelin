import Then
import UIKit

// Inspector's process list as a component: a name, then figures in columns
// that line up from row to row under a heading row (Inspector's
// ProcessListColumns, ProcessListHeaderView and ProcessRowCell, without the
// icon and the sorting). A column is as wide as the widest sample it was
// given, measured once per text size and never from the row being drawn. At
// the accessibility sizes there is no room for columns: a row stacks its
// figures under the name, and the headings go.

/// A column after the name: its heading and the widest values it holds.
struct TableColumn {
    let title: String
    let samples: [String]
}

final class ColumnTableMetrics {
    let isStacked: Bool
    let nameLines: Int
    let symbolSize: CGFloat
    let nameFont: UIFont
    let valueFont: UIFont
    let titleFont: UIFont
    let columnSpacing: CGFloat
    let rowHeight: CGFloat
    private let minimumNameWidth: CGFloat
    private let widths: [CGFloat]
    /// Room at the trailing edge for a row's symbol (`plus.circle`); the
    /// heading keeps it empty, so the figures stay under their titles.
    let trailingSymbolWidth: CGFloat

    static let rowPadding: CGFloat = 16
    static let lineSpacing: CGFloat = 4

    init(columns: [TableColumn], category: UIContentSizeCategory, trailingSymbol: Bool = false, nameLines: Int = 1, availableWidth: CGFloat? = nil) {
        // a view outside a window reports no text size; the app's stands in
        let category = category == .unspecified ? UIApplication.shared.preferredContentSizeCategory : category
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        self.nameLines = nameLines
        nameFont = .preferredFont(forTextStyle: .body, compatibleWith: traits)
        valueFont = .monospacedDigitSystemFont(ofSize: nameFont.pointSize, weight: .regular)
        let caption = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        titleFont = .systemFont(ofSize: caption.pointSize, weight: .semibold)
        columnSpacing = 12
        minimumNameWidth = Self.width(of: nameLines > 1 ? "Swift 5.7.2" : "88.8", in: nameFont)
        symbolSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: 20, compatibleWith: traits)
        trailingSymbolWidth = trailingSymbol ? ceil(symbolSize) : 0
        let nameLine = ceil(nameFont.lineHeight) * CGFloat(nameLines) + CGFloat(nameLines - 1) * Self.lineSpacing
        let valueLine = ceil(valueFont.lineHeight)
        widths = columns.map { [valueFont, titleFont] in
            ($0.samples.map { Self.width(of: $0, in: valueFont) }
                + [Self.width(of: $0.title, in: titleFont)]).max() ?? 0
        }
        let neededWidth = minimumNameWidth + widths.reduce(0, +)
            + CGFloat(columns.count) * columnSpacing
            + (trailingSymbol ? trailingSymbolWidth + columnSpacing : 0)
        isStacked = category.isAccessibilityCategory || availableWidth.map { $0 < neededWidth } == true
        rowHeight = isStacked
            ? nameLine + CGFloat(max(columns.count, 1)) * (Self.lineSpacing + valueLine) + 2 * Self.rowPadding
            : max(nameLine, valueLine, symbolSize) + 2 * Self.rowPadding
    }

    /// The name's span, each column's and the trailing symbol's, across
    /// `content`: the symbol at the trailing edge, figures filling in before
    /// it, and the last ones going first when the name would be left less
    /// than its minimum. A column left out is nil.
    func layout(in content: CGRect, isRightToLeft: Bool) -> (name: CGRect, columns: [CGRect?], symbol: CGRect?) {
        var trailing = content.maxX
        var symbol: CGRect?
        if trailingSymbolWidth > 0 {
            symbol = CGRect(
                x: trailing - trailingSymbolWidth,
                y: content.minY,
                width: trailingSymbolWidth,
                height: content.height,
            )
            trailing -= trailingSymbolWidth + columnSpacing
        }
        let room = trailing - content.minX
        var shown = widths.count
        while shown > 0 {
            let needed = widths.prefix(shown).reduce(0) { $0 + $1 + columnSpacing }
            if room - needed >= minimumNameWidth {
                break
            }
            shown -= 1
        }
        var columns = [CGRect?](repeating: nil, count: widths.count)
        for index in (0 ..< shown).reversed() {
            let leading = trailing - widths[index]
            columns[index] = CGRect(x: leading, y: content.minY, width: widths[index], height: content.height)
            trailing = leading - columnSpacing
        }
        var name = CGRect(
            x: content.minX,
            y: content.minY,
            width: max(0, trailing - content.minX),
            height: content.height,
        )
        if isRightToLeft {
            name = name.mirrored(across: content)
            columns = columns.map { $0?.mirrored(across: content) }
            symbol = symbol?.mirrored(across: content)
        }
        return (name, columns, symbol)
    }

    @objc private dynamic static func width(of text: String, in font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// The heading row above a section of `ColumnTableCell`s: Name (or the
/// caller's word for it) over the names, each column's title right-aligned
/// over its figures.
final class ColumnTableHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "columnHeader"
    private static let bottomSpacing: CGFloat = 7

    private let nameLabel = UILabel()
    @objc private dynamic var titleLabels: [UILabel] = []
    private var metrics: ColumnTableMetrics?

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        nameLabel.text = String(localized: "Name")
        contentView.addSubview(nameLabel)
        // the rows say what each figure is; the headings are only drawn
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(reuseIdentifier:)")
    }

    func configure(columns: [TableColumn], metrics: ColumnTableMetrics, nameTitle: String? = nil) {
        self.metrics = metrics
        nameLabel.text = nameTitle ?? String(localized: "Name")
        titleLabels.forEach { $0.removeFromSuperview() }
        titleLabels = columns.map { column in
            UILabel().then {
                $0.text = column.title
                $0.textAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft ? .left : .right
                contentView.addSubview($0)
            }
        }
        for label in [nameLabel] + titleLabels {
            label.font = metrics.titleFont
            label.textColor = .secondaryLabel
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metrics else { return }
        let hidden = metrics.isStacked
        nameLabel.isHidden = hidden
        titleLabels.forEach { $0.isHidden = hidden }
        guard !hidden else { return }
        // one line of headings, sitting just over the rows as a section's
        // title does
        var content = contentView.bounds.inset(by: contentView.layoutMargins)
        let line = ceil(metrics.titleFont.lineHeight)
        content.origin.y = contentView.bounds.maxY - line - Self.bottomSpacing
        content.size.height = line
        let layout = metrics.layout(in: content, isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft)
        nameLabel.frame = layout.name
        for (label, frame) in zip(titleLabels, layout.columns) {
            label.isHidden = frame == nil
            label.frame = frame ?? .zero
        }
    }
}

/// One row: the name, then its figures under the headings. Laid out by hand,
/// as Inspector's, so the figures sit on the name's baseline.
final class ColumnTableCell: UITableViewCell {
    static let reuseIdentifier = "columnRow"

    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    @objc private dynamic var valueLabels: [UILabel] = []
    private let symbolView = UIImageView().then {
        $0.contentMode = .center
    }

    private var metrics: ColumnTableMetrics?
    @objc private dynamic var titles: [String] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        contentView.addSubview(nameLabel)
        subtitleLabel.textColor = .secondaryLabel
        contentView.addSubview(subtitleLabel)
        contentView.addSubview(symbolView)
        // one stop for the row; the figures are named in the value
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    /// `name` may carry an attachment (a warning mark); `accessibilityName`
    /// is what VoiceOver says for it. `symbol` sits in the metrics' trailing
    /// slot, drawn only: the name says what it means.
    func configure(
        name: NSAttributedString,
        accessibilityName: String,
        subtitle: String? = nil,
        values: [String],
        columns: [TableColumn],
        metrics: ColumnTableMetrics,
        symbol: UIImage? = nil,
        symbolTint: UIColor = .tintColor,
    ) {
        self.metrics = metrics
        symbolView.image = symbol
        symbolView.tintColor = symbolTint
        symbolView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: metrics.symbolSize, weight: .light)
        titles = columns.map(\.title)
        if valueLabels.count != values.count {
            valueLabels.forEach { $0.removeFromSuperview() }
            valueLabels = values.map { _ in
                UILabel().then {
                    $0.textColor = .secondaryLabel
                    $0.adjustsFontSizeToFitWidth = true
                    $0.minimumScaleFactor = 0.7
                    contentView.addSubview($0)
                }
            }
        }
        nameLabel.numberOfLines = 1
        subtitleLabel.text = subtitle
        subtitleLabel.font = metrics.nameFont
        subtitleLabel.isHidden = subtitle == nil
        nameLabel.font = metrics.nameFont
        nameLabel.attributedText = name
        for (label, (title, value)) in zip(valueLabels, zip(titles, values)) {
            label.font = metrics.valueFont
            // under a heading the figure is enough; stacked, it says what it is
            label.text = metrics.isStacked ? "\(title) \(value)" : value
        }
        accessibilityLabel = accessibilityName
        accessibilityValue = zip(titles, values).map { "\($0) \($1)" }.joined(separator: ", ")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metrics else { return }
        let content = contentView.bounds.inset(by: contentView.layoutMargins)
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let nameLineHeight = ceil(metrics.nameFont.lineHeight)
        let nameHeight = nameLineHeight * CGFloat(metrics.nameLines) + CGFloat(metrics.nameLines - 1) * ColumnTableMetrics.lineSpacing
        let valueHeight = ceil(metrics.valueFont.lineHeight)
        if metrics.isStacked {
            symbolView.isHidden = symbolView.image == nil
            symbolView.frame = CGRect(
                x: isRightToLeft ? content.minX : content.maxX - metrics.trailingSymbolWidth,
                y: content.minY,
                width: metrics.trailingSymbolWidth,
                height: metrics.symbolSize,
            )
            let textWidth = content.width - metrics.trailingSymbolWidth - metrics.columnSpacing
            let textX = isRightToLeft ? content.minX + metrics.trailingSymbolWidth + metrics.columnSpacing : content.minX
            var y = contentView.bounds.minY + ColumnTableMetrics.rowPadding
            nameLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: nameLineHeight)
            subtitleLabel.frame = CGRect(x: textX, y: y + nameLineHeight + ColumnTableMetrics.lineSpacing, width: textWidth, height: nameLineHeight)
            y += nameHeight
            for label in valueLabels {
                y += ColumnTableMetrics.lineSpacing
                label.frame = CGRect(x: textX, y: y, width: textWidth, height: valueHeight)
                label.textAlignment = .natural
                label.isHidden = false
                y += valueHeight
            }
            return
        }
        let layout = metrics.layout(in: content, isRightToLeft: isRightToLeft)
        symbolView.isHidden = layout.symbol == nil || symbolView.image == nil
        symbolView.frame = layout.symbol.map {
            CGRect(x: $0.minX, y: contentView.bounds.minY, width: $0.width, height: contentView.bounds.height)
        } ?? .zero
        nameLabel.frame = CGRect(
            x: layout.name.minX,
            y: pixelAligned(contentView.bounds.midY - nameHeight / 2),
            width: layout.name.width,
            height: nameLineHeight,
        )
        subtitleLabel.frame = CGRect(
            x: nameLabel.frame.minX,
            y: nameLabel.frame.maxY + ColumnTableMetrics.lineSpacing,
            width: nameLabel.frame.width,
            height: nameLineHeight,
        )
        // The version and figures share a baseline.
        let baseline = nameLabel.frame.minY + metrics.nameFont.ascender
        let valueY = pixelAligned(baseline - metrics.valueFont.ascender)
        for (label, frame) in zip(valueLabels, layout.columns) {
            label.isHidden = frame == nil
            guard let frame else { continue }
            label.frame = CGRect(x: frame.minX, y: valueY, width: frame.width, height: valueHeight)
            label.textAlignment = isRightToLeft ? .left : .right
        }
    }

    @objc private dynamic func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (value * scale).rounded() / scale
    }
}
