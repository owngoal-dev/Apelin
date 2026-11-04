// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Copied from Irisin; only app names, localization calls, flow callbacks and the
// accent before iOS 26 (`AppAccent`) differ.
//
//  WelcomeActionBar.swift
//  Irisin
//

import SnapKit
import Then
import UIKit

/// The bar under every onboarding page: a rule over a blur, the page's
/// button, with a quiet secondary action above the rule when offered.
final class WelcomeActionBar: UIView {
    private let button = UIButton(type: .system)
    private let rule = UIView().then { $0.backgroundColor = .separator }
    @objc private dynamic var secondary: UIButton?
    @objc private dynamic var action: (() -> Void)?
    @objc dynamic var title: String {
        get { button.configuration?.title ?? "" }
        set { button.configuration?.title = newValue }
    }

    @objc(apelin_isEnabled) dynamic var isEnabled: Bool {
        get { button.isEnabled }
        set { button.isEnabled = newValue }
    }

    /// Hidden, the secondary action gives its room back to the page.
    @objc dynamic var isSecondaryHidden = false {
        didSet {
            guard isSecondaryHidden != oldValue else { return }
            secondary?.isHidden = isSecondaryHidden
            layoutSecondary()
        }
    }

    @objc dynamic func activate() {
        action?()
    }

    init(
        title: String,
        secondaryTitle: String? = nil,
        action: @escaping () -> Void,
        secondaryAction: @escaping () -> Void = {},
    ) {
        super.init(frame: .zero)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        self.action = action
        addSubview(blur)
        addSubview(rule)
        addSubview(button)

        blur.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
            x.top.equalTo(rule.snp.top)
        }
        button.snp.makeConstraints { x in
            x.top.equalTo(rule.snp.bottom).offset(24)
            x.leading.trailing.equalToSuperview().inset(24)
            x.height.equalTo(48)
        }
        if let secondaryTitle {
            var plain = UIButton.Configuration.plain()
            plain.baseForegroundColor = WelcomeStyle.detailColor
            plain.title = secondaryTitle
            let secondary = UIButton(configuration: plain)
            secondary.titleLabel?.font = WelcomeStyle.detailFont
            secondary.addAction(UIAction { _ in secondaryAction() }, for: .touchUpInside)
            addSubview(secondary)
            self.secondary = secondary
        }
        layoutSecondary()
        button.snp.makeConstraints { x in
            x.bottom.equalTo(safeAreaLayoutGuide).inset(28)
        }

        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.titleLabel?.font = WelcomeStyle.buttonFont
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = WelcomeStyle.accent
        configuration.baseForegroundColor = WelcomeStyle.accentForeground
        configuration.title = title
        button.configuration = configuration
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    /// The rule sits under the secondary action when it shows, at the top
    /// otherwise.
    @objc private dynamic func layoutSecondary() {
        let shows = secondary != nil && !isSecondaryHidden
        rule.snp.remakeConstraints { x in
            x.leading.trailing.equalToSuperview()
            x.height.equalTo(0.5)
            if !shows {
                x.top.equalToSuperview()
            }
        }
        guard let secondary else { return }
        secondary.snp.remakeConstraints { x in
            guard shows else { return }
            x.top.equalToSuperview()
            x.centerX.equalToSuperview()
            x.bottom.equalTo(rule.snp.top).offset(-8)
        }
    }
}
