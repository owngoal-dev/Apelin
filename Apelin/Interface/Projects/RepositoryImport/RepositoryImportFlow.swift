import AlertController
import SPIndicator
import UIKit

/// Open in Apelin for a Git repository (`apelin://import`): the link's
/// confirmation (`RepositoryImportController`), one at a time whatever
/// number of links come in. A link for the repository already shown or
/// importing starts nothing again; a link for another says an import is
/// under way and leaves it be.
@MainActor
enum RepositoryImportFlow {
    /// The confirmation shown, or whose import runs.
    private weak static var current: RepositoryImportController?

    /// Shows the confirmation for `request` over whatever the window shows;
    /// `onOpen` opens the project the user picks or imports.
    static func open(
        _ request: RepositoryImportPlan.Request,
        from root: UIViewController,
        onOpen: @escaping (ProjectSummary, _ imported: Bool) -> Void,
    ) {
        switch RepositoryImportPlan.arrival(of: request, current: current?.openRequest) {
        case .showCurrent:
            return
        case .busy:
            SPIndicator.present(
                title: String(localized: "Import Under Way"),
                message: String(localized: "Finish or cancel the current import first."),
                preset: .error,
                haptic: .warning,
            )
        case .start:
            let page = RepositoryImportController(request: request)
            page.onOpen = onOpen
            current = page
            present(page, over: root)
        }
    }

    /// Says that a link named no repository Apelin can import; what was
    /// shown stays.
    static func reportUnreadableLink() {
        SPIndicator.present(
            title: String(localized: "Unable to Import"),
            message: String(localized: "This link names no HTTPS repository Apelin can import."),
            preset: .error,
            haptic: .error,
        )
    }

    /// On the next turn, once a sheet on its way in or out has settled: the
    /// welcome hands a link on just before it closes, and a sheet presented
    /// over one that is closing is closed with it.
    private static func present(_ page: RepositoryImportController, over root: UIViewController) {
        DispatchQueue.main.async { [weak root] in
            guard let root, current === page else { return }
            var top = root
            while let presented = top.presentedViewController {
                // never over an alert, a progress card's among them: its
                // dismissal would take the sheet with it
                if presented is AlertViewController || presented is UIAlertController {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { present(page, over: root) }
                    return
                }
                if presented.isBeingDismissed || presented.isBeingPresented {
                    if let transition = presented.transitionCoordinator {
                        transition.animate(alongsideTransition: nil) { _ in present(page, over: root) }
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { present(page, over: root) }
                    }
                    return
                }
                top = presented
            }
            top.presentPageAsFormSheet(page)
        }
    }
}
