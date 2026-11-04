// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
import SnapKit
import UIKit

/// The two recommendation rows keep their views and constraints in every
/// state. The text's mask uses the same shimmer as ThinkingStatusLabel; it
/// sits on a plain view around the stack, because a UIStackView's layer is a
/// CATransformLayer, which renders no mask.
final class WelcomeToolRow: UITableViewCell {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusImage = UIImageView()
    private let words = UIStackView()
    private let wordsBox = MaskedBox()
    private let shimmer = CAGradientLayer()
    @objc private dynamic var loading = false

    init() {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        words.axis = .vertical
        words.spacing = 2
        words.addArrangedSubview(titleLabel)
        words.addArrangedSubview(detailLabel)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.numberOfLines = 1
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.adjustsFontForContentSizeCategory = true
        statusImage.contentMode = .scaleAspectFit
        statusImage.tintColor = WelcomeStyle.accent
        wordsBox.addSubview(words)
        contentView.addSubview(wordsBox)
        contentView.addSubview(statusImage)
        words.snp.makeConstraints { $0.edges.equalToSuperview() }
        wordsBox.snp.makeConstraints {
            $0.leading.equalTo(contentView.layoutMarginsGuide)
            $0.trailing.equalTo(statusImage.snp.leading).offset(-12)
            $0.centerY.equalToSuperview()
        }
        statusImage.snp.makeConstraints {
            $0.size.equalTo(20)
            $0.trailing.equalTo(contentView.layoutMarginsGuide)
            $0.centerY.equalToSuperview()
        }
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [
            UIColor.white.withAlphaComponent(0.4).cgColor,
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.4).cgColor,
        ]
        isAccessibilityElement = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateShimmer),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc dynamic func configure(title: String, detail: String, loading: Bool, installed: Bool) {
        titleLabel.text = title
        detailLabel.text = detail
        self.loading = loading
        statusImage.image = installed ? UIImage(systemName: "checkmark") : nil
        accessibilityLabel = title
        let state = installed ? String(localized: "Installed") : ""
        accessibilityValue = [detail, state == detail ? "" : state].filter { !$0.isEmpty }.joined(separator: ", ")
        updateShimmer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateShimmer()
    }

    @objc private dynamic func updateShimmer() {
        shimmer.removeAllAnimations()
        guard loading, window != nil, !UIAccessibility.isReduceMotionEnabled else { wordsBox.layer.mask = nil; return }
        wordsBox.layer.mask = shimmer
        wordsBox.setNeedsLayout()
        // swept from the leading edge
        let rightToLeft = wordsBox.laysOutRightToLeft
        shimmer.startPoint = CGPoint(x: rightToLeft ? 1 : 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: rightToLeft ? 0 : 1, y: 0.5)
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0]
        animation.toValue = [1, 1.2, 1.4]
        animation.duration = 1.5
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        shimmer.add(animation, forKey: "loading")
    }
}

/// Keeps its layer's mask the size of its bounds.
private final class MaskedBox: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask?.frame = bounds
        CATransaction.commit()
    }
}
