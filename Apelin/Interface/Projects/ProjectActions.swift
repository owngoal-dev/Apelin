import AlertController
import ApelinCore
import ApelinProtocol
import UIKit

/// Actions for the project behind the current chat. Folder names are stable
/// identities; links are made from their canonical path, never an install prefix.
@MainActor
enum ProjectActions {
    /// `chatActions` form the first group;
    /// `distributionBlocker` says why a project with no build description
    /// or script (`ProjectBuildMethod`), which has nothing to package,
    /// cannot be distributed.
    /// `onPrepareDistribution` sends the distribution page's request to the
    /// project's conversation. `instructions` opens what the conversation
    /// loads, the project's custom instructions among it, after Rename….
    static func menu(
        projectName: String,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        distributionBlocker: String? = nil,
        chatActions: [UIKit.UIAction] = [],
        instructions: UIKit.UIAction? = nil,
        onPrepareDistribution: ((String) -> Void)? = nil,
    ) -> UIMenu {
        let folders = folderActions(from: presenter, failureTitle: "Unable to Open Project") {
            try directory(named: projectName)
        }
        let renameAction = UIAction(
            title: String(localized: "Rename…"),
            image: UIImage(systemName: "pencil"),
        ) { [weak presenter] _ in
            guard let presenter else { return }
            rename(projectName, from: presenter)
        }
        let export = UIAction(
            title: String(localized: "Export…"),
            image: UIImage(systemName: "square.and.arrow.up"),
        ) { [weak presenter, weak anchor] _ in
            guard let presenter, let anchor else { return }
            TransferExporter.confirmAndExport(
                kind: .project,
                id: projectName,
                name: projectName,
                from: presenter,
                anchor: anchor,
            )
        }
        let distribute = UIAction(
            title: String(localized: "Distribute…"),
            subtitle: distributionBlocker,
            image: UIImage(systemName: "shippingbox"),
            attributes: distributionBlocker == nil ? [] : .disabled,
        ) { [weak presenter] _ in
            presenter?.presentPageAsFormSheet(
                ProjectDistributionController(projectName: projectName, onPrepare: onPrepareDistribution),
            )
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: chatActions),
            UIMenu(options: .displayInline, children: folders),
            UIMenu(
                title: String(localized: "Project"),
                options: .displayInline,
                children: [renameAction] + (instructions.map { [$0] } ?? []) + [export, distribute],
            ),
        ])
    }

    /// Open in iGhostVT and Open in Fila, for the folder `folder` answers
    /// when one is picked; a folder it cannot answer is `failureTitle`'s
    /// notice. `UIKit.UIAction` is spelled out in types here: ApelinProtocol
    /// has a `UIAction` of its own, the wire's.
    static func folderActions(
        from presenter: UIViewController,
        failureTitle: String.LocalizationValue,
        folder: @escaping () throws -> String,
    ) -> [UIKit.UIAction] {
        let openFolder = { [weak presenter] (scheme: String) in
            guard let presenter else { return }
            do {
                try open(folder(), in: scheme, from: presenter)
            } catch {
                presenter.presentNotice(title: failureTitle, message: error.readableMessage)
            }
        }
        return [
            UIAction(title: String(localized: "Open in iGhostVT"), image: UIImage(systemName: "terminal")) { _ in
                openFolder("ighostvt")
            },
            UIAction(title: String(localized: "Open in Fila"), image: UIImage(systemName: "folder")) { _ in
                openFolder("fila")
            },
        ]
    }

    static func rename(_ projectName: String, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let presenter else { return }
            let current = try? await ProjectSummary.load().first { $0.name == projectName }
            presenter.present(AlertInputViewController(
                title: "Rename Project",
                message: "Choose a display name. The project folder and build settings stay the same.",
                placeholder: "Project Name",
                text: current?.displayTitle ?? projectName,
                doneButtonText: "Rename",
                onConfirm: { [weak presenter] name in
                    Task { [weak presenter] in
                        do {
                            _ = try await ApelinService.app.projectRename(.init(
                                projectID: current?.projectID ?? projectName,
                                displayName: name,
                            ))
                            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                        } catch {
                            presenter?.presentNotice(title: "Unable to Rename Project", message: error.readableMessage)
                        }
                    }
                },
            ), animated: true)
        }
    }

    static func directory(named name: String) throws -> String {
        guard let folder = DataFolder.app.project(named: name),
              let projects = CanonicalPath.resolve(DataFolder.app.projects.path),
              let path = CanonicalPath.resolve(folder.path),
              path == projects + "/" + name
        else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ApelinError(.notFound, String(localized: "The project folder is no longer available."))
        }
        return path
    }

    /// A temporary conversation's working folder, `Temporary/<id>/`, made
    /// when it is not there yet: what a General Chat opens in iGhostVT and
    /// Fila. Made level by level as `ChatRuntime` makes it, never through a
    /// link, and the one real directory directly inside `Temporary/`.
    static func temporaryDirectory(of id: UUID) throws -> String {
        let folder = DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString)
        guard (try? DataFolder.app.makeLevels(to: folder)) != nil,
              let root = CanonicalPath.resolve(DataFolder.app.root.path),
              let path = CanonicalPath.resolve(folder.path),
              path == root + "/Temporary/" + id.uuidString
        else {
            throw ApelinError(.notFound, String(localized: "The chat’s folder is not available."))
        }
        return path
    }

    /// `path` in iGhostVT (`ighostvt://new?directory=`, a directory and no
    /// command) or Fila (`fila://open?path=&tab=new`).
    private static func open(_ path: String, in scheme: String, from presenter: UIViewController) {
        var components = URLComponents()
        components.scheme = scheme
        components.host = scheme == "fila" ? "open" : "new"
        components.queryItems = scheme == "fila"
            ? [URLQueryItem(name: "path", value: path), URLQueryItem(name: "tab", value: "new")]
            : [URLQueryItem(name: "directory", value: path)]
        guard let url = components.url else { return }
        UIApplication.shared.open(url) { [weak presenter] opened in
            guard !opened, let presenter else { return }
            presenter.presentNotice(title: "Unable to Open App", message: String(localized: "Install or update the required app with your preferred package manager, then try again."))
        }
    }
}
