// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Copied from Irisin; only app names, localization calls and flow callbacks differ.
//
//  WelcomeController.swift
//  Irisin
//
//  The first page of onboarding: the app icon, a two-line title, what
//  Irisin does, and one button. Onboarding is a navigation stack in a form
//  sheet; a page after this one is pushed by its button, and the last
//  page's button finishes.
//

import AlertController
import SnapKit
import Then
import UIKit

class WelcomeController: UIViewController {
    struct Feature {
        let symbol: String
        let title: String.LocalizationValue
        let detail: String.LocalizationValue
    }

    private let flow: WelcomeFlow

    /// Ordered by how much a user cares, most first.
    private static let features: [Feature] = [
        .init(
            symbol: "text.bubble",
            title: "Describe What You Want",
            detail: "Work with an agent to write and understand your code.",
        ),
        .init(
            symbol: "hammer",
            title: "Build Apps and Tweaks",
            detail: "Set up a compiler and SDK, then start from a project template.",
        ),
        .init(
            symbol: "hand.raised",
            title: "Stay in Control",
            detail: "Review changes, test results, and approve actions that affect your device.",
        ),
    ]

    private let contentInsets = UIEdgeInsets(top: 28, left: 24, bottom: 28, right: 24)
    private let scrollView = UIScrollView().then { $0.alwaysBounceVertical = true }
    private let contentView = UIView()
    private let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 18
        $0.alignment = .fill
        // each view at its own height; proportional distribution measures
        // every arranged view at zero width first, which none of them fit
        $0.distribution = .fill
    }

    @objc private dynamic var featureRows: [UIView] = []

    init(flow: WelcomeFlow) {
        self.flow = flow
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        modalTransitionStyle = .coverVertical
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 520, height: 620)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = WelcomeStyle.background
        view.tintColor = WelcomeStyle.accent
        setupLayout()
        setupContent()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.tintColor = WelcomeStyle.accent
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !UIAccessibility.isReduceMotionEnabled else {
            featureRows.forEach { $0.alpha = 1 }
            return
        }
        for (index, row) in featureRows.enumerated() {
            UIView.animate(
                withDuration: 0.5,
                delay: 0.1 * Double(index),
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0.4,
                options: [.curveEaseInOut],
            ) {
                row.alpha = 1
            }
        }
    }

    @objc private dynamic func setupLayout() {
        let actionBar = WelcomeActionBar(title: String(localized: "Next")) { [weak self] in
            self?.showNextPage()
        }

        view.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stackView)
        view.addSubview(actionBar)

        // the navigation bar stays for the pages after this one, empty here:
        // the page starts at the top of the sheet and scrolls under it
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.snp.makeConstraints { x in
            x.top.equalToSuperview()
            x.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            x.bottom.equalTo(actionBar.snp.top)
        }
        contentView.snp.makeConstraints { x in
            x.edges.equalToSuperview()
            x.width.equalTo(scrollView.snp.width)
        }
        stackView.snp.makeConstraints { x in
            x.edges.equalToSuperview().inset(contentInsets)
        }
        actionBar.snp.makeConstraints { x in
            x.leading.trailing.bottom.equalToSuperview()
        }
    }

    @objc private dynamic func setupContent() {
        let icon = UIImageView(image: AlertControllerConfiguration.alertImage).then {
            $0.contentMode = .scaleAspectFill
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
            $0.layer.shadowColor = WelcomeStyle.iconShadow.cgColor
            $0.layer.shadowRadius = 4
            $0.layer.shadowOffset = .zero
            $0.layer.shadowOpacity = 0.1
            $0.clipsToBounds = true
        }
        let iconContainer = UIView()
        iconContainer.addSubview(icon)
        icon.snp.makeConstraints { x in
            x.width.height.equalTo(64)
            x.top.bottom.equalToSuperview().inset(64)
            x.centerX.equalToSuperview()
            x.leading.greaterThanOrEqualToSuperview().inset(64)
        }
        stackView.addArrangedSubview(iconContainer)
        stackView.setCustomSpacing(0, after: iconContainer)

        // the translation places the line break and the name; the name is
        // tinted wherever it lands
        let title = String(localized: "Welcome to\nApelin")
        let titleText = NSMutableAttributedString(string: title, attributes: [
            .font: WelcomeStyle.titleFont,
            .foregroundColor: WelcomeStyle.titleColor,
        ])
        titleText.addAttribute(
            .foregroundColor,
            value: WelcomeStyle.accent,
            range: (title as NSString).range(of: "Apelin"),
        )
        stackView.addArrangedSubview(UILabel().then {
            $0.numberOfLines = 0
            $0.textAlignment = .natural
            $0.attributedText = titleText
            // the page has no navigation title: this is its heading
            $0.accessibilityTraits = .header
        })

        stackView.addArrangedSubview(UILabel().then {
            $0.text = String(localized: "Build on your device, with an agent beside you.")
            $0.font = WelcomeStyle.subtitleFont
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = WelcomeStyle.detailColor
            $0.numberOfLines = 0
        })

        let rule = UIView().then { $0.backgroundColor = .separator }
        rule.snp.makeConstraints { x in
            x.height.equalTo(0.75)
        }
        stackView.addArrangedSubview(rule)

        for (index, feature) in Self.features.enumerated() {
            let row = WelcomeFeatureRow(feature: feature)
            row.alpha = 0
            featureRows.append(row)
            stackView.addArrangedSubview(row)
            if index < Self.features.count - 1 {
                stackView.setCustomSpacing(18, after: row)
            }
        }

        // room under the last row before the button bar
        let spacer = UIView()
        spacer.snp.makeConstraints { x in
            x.height.greaterThanOrEqualTo(12)
        }
        stackView.addArrangedSubview(spacer)
    }

    @objc private dynamic func showNextPage() {
        flow.showEnvironment()
    }
}
