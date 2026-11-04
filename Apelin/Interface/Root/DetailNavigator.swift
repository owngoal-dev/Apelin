import UIKit

/// The detail column. The page the sidebar picks is the stack's root, so
/// there is nothing under it to go back to: no back button, no swipe, and
/// a page that pops itself stops there. `NothingSelectedController` until
/// there is a page.
final class DetailNavigator: UINavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()
        viewControllers = [NothingSelectedController()]
        // the detail side never grows a large title, whatever a page asks for
        navigationBar.prefersLargeTitles = false
    }

    /// Puts `page` at the root of the column.
    @objc dynamic func show(_ page: UIViewController) {
        guard topViewController !== page else { return }
        // one step: a pop followed by a push lands on a stack two screens
        // deep only after the next touch
        let transitionFromPlaceholder = viewControllers.first is NothingSelectedController
            && !(page is NothingSelectedController)
        parent?.view.layoutIfNeeded()
        view.layoutIfNeeded()
        let placeholder = transitionFromPlaceholder && view.window != nil && !UIAccessibility.isReduceMotionEnabled
            ? view.snapshotView(afterScreenUpdates: false) : nil

        // Settle the incoming page outside the fade. Its keyboard guide,
        // safe area and initial transcript position need the final column
        // bounds before any of its pixels become visible.
        UIView.performWithoutAnimation {
            setViewControllers([page], animated: false)
            view.setNeedsLayout()
            view.layoutIfNeeded()
            page.view.layoutIfNeeded()
        }
        if let placeholder {
            placeholder.frame = view.bounds
            placeholder.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            placeholder.isUserInteractionEnabled = false
            placeholder.accessibilityElementsHidden = true
            view.addSubview(placeholder)
            UIView.animate(withDuration: 0.2, animations: {
                placeholder.alpha = 0
            }, completion: { _ in
                placeholder.removeFromSuperview()
            })
        }
    }
}
