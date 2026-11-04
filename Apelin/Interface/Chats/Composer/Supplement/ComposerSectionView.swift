// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// One band of the composer. Each publishes the height it wants, and the
/// view holding it lays it out again whenever a band's height changes.
class ComposerSectionView: UIView {
    let heightPublisher: CurrentValueSubject<CGFloat, Never> = .init(0)
    var cancellables: Set<AnyCancellable> = .init()

    /// How far the band reaches past the composer's spacing on each side.
    @objc dynamic var horizontalAdjustment: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    required init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        clipsToBounds = false
        layer.masksToBounds = false

        initializeViews()

        for view in subviews {
            guard let view = view as? ComposerSectionView else { continue }
            view.heightPublisher
                .removeDuplicates()
                .ensureMainThread()
                .sink { [weak self] _ in self?.subviewHeightDidChange() }
                .store(in: &cancellables)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    /// Builds the band's subviews, from `init`. Overrides call `super` first.
    @objc dynamic func initializeViews() {
        setNeedsLayout()
    }

    /// Inside an animation the layout waits for the block's own, so bands
    /// that change together are placed once, at their final heights.
    @objc dynamic func subviewHeightDidChange() {
        setNeedsLayout()
        if UIView.inheritedAnimationDuration == 0 {
            layoutIfNeeded()
        }
    }
}
