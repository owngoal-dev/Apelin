import ApelinCore
import ApelinProtocol
import SPIndicator
import UIKit

/// Sharing and publishing release packages, from the distribution page and
/// the build page alike: to the share sheet, to the linked package
/// repository, or as a GitHub Release of the project's repository. Each
/// package is the file its build made, read back against the digest the
/// build recorded first: nothing is built or packaged again.
@MainActor
enum DistributionPublishing {
    /// A package's file and the digest its build recorded.
    struct Item {
        var path: String?
        var digest: String
        var version: String
        /// The line a confirmation names it by.
        var title: String

        init(path: String?, digest: String, packageID: String, version: String, bootstrap: BuildBootstrap) {
            self.path = path
            self.digest = digest
            self.version = version
            title = "\(packageID) \(version) (\(bootstrap.rawValue))"
        }
    }

    /// The share sheet with the package, pointing at `anchor`; a share that
    /// completes makes it Shared (`SharedPackages`) and calls `onShared`.
    static func share(
        _ item: Item,
        from presenter: UIViewController,
        anchor: any UIPopoverPresentationControllerSourceItem,
        onShared: @escaping () -> Void = {},
    ) async {
        do {
            let file = try await Task.detached {
                try DistributionPackages.verify(path: item.path, digest: item.digest)
            }.value
            let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceItem = anchor
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                guard completed else { return }
                SharedPackages.record(item.digest)
                onShared()
            }
            presenter.present(sheet, animated: true)
        } catch {
            presenter.presentNotice(title: "Unable to Share", message: error.readableMessage)
        }
    }

    /// The packages into the linked package repository in one commit: read
    /// back, named with the repository in a confirmation, then followed as
    /// a task on `presenter`'s navigation. A package the repository already
    /// holds with the same bytes is skipped, and one it holds with other
    /// bytes refused (`distributionPublish`). With no repository linked,
    /// Settings ▸ Git instead.
    static func publish(_ items: [Item], from presenter: UIViewController) async {
        do {
            guard let linked = try await ApelinService.app.distributionRepositoryList(repositories: false).linked else {
                openRepositorySetup(from: presenter)
                return
            }
            let files = try await Task.detached { () throws -> [(path: String, digest: String)] in
                try items.map { item -> (path: String, digest: String) in
                    let file = try DistributionPackages.verify(path: item.path, digest: item.digest)
                    return (file.path, item.digest)
                }
            }.value
            let packages = items.map(\.title).joined(separator: "\n")
            presenter.presentConfirmation(
                title: "Publish to \(linked.fullName)?",
                message: "\(packages)\n\nEach package goes into the repository’s debs folder as it was built, in one commit that is pushed. Devices with \(linked.sourceURL) see the update within a few minutes.",
                confirmTitle: "Publish",
            ) { [weak presenter] in
                guard let presenter else { return }
                start(files, to: linked.fullName, from: presenter)
            }
        } catch {
            presenter.presentNotice(title: "Unable to Publish", message: error.readableMessage)
        }
    }

    /// `files`, read back already, each with the digest its build recorded,
    /// which apelin-environment checks the bytes against again before any
    /// goes in; `repository` is the one the confirmation named, so a link
    /// changed meanwhile publishes nothing.
    private static func start(
        _ files: [(path: String, digest: String)],
        to repository: String,
        from presenter: UIViewController,
    ) {
        Task { [weak presenter] in
            do {
                let handle = try await ApelinService.app.distributionPublish(
                    files: files.map(\.path),
                    digests: files.map(\.digest),
                    repository: repository,
                )
                let page = EnvironmentTaskController(
                    handle: handle,
                    work: .distributionPublish,
                    title: String(localized: "Publishing Package"),
                    doneTitle: String(localized: "Published"),
                )
                presenter?.navigationController?.pushViewController(page, animated: true)
            } catch {
                presenter?.presentNotice(title: "Unable to Publish", message: error.readableMessage)
            }
        }
    }

    /// Settings ▸ Git over `presenter`, which stays as it is: Publishing
    /// there creates or links a repository, after Sign In when GitHub has
    /// no account yet. The indicator says why it opened.
    private static func openRepositorySetup(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        SPIndicator.present(title: String(localized: "No Package Repository"), preset: .error, haptic: .warning)
        SettingsViewController.presentGit(from: presenter)
    }

    // MARK: A GitHub Release

    /// What a release of `projectName`'s packages names before it is
    /// confirmed: the tag their version makes and the commit it names.
    private struct ReleaseDraft {
        var projectID: String
        var tag: String
        var commit: String
        /// Read back already, each with the digest its build recorded.
        var files: [(path: String, digest: String)]
        var titles: [String]
    }

    /// The packages, one version of them, as a GitHub Release of the
    /// project's repository (`distributionRelease`), tagged at the
    /// project's commit, which must be pushed there already: the
    /// repository its github.com remote names (origin first), else the one
    /// the reader types; named with the tag and the commit in a
    /// confirmation, then followed on the progress card, and the release
    /// offered to open. Without a GitHub sign-in, Settings ▸ Git instead.
    static func release(_ items: [Item], projectName: String, from presenter: UIViewController) async {
        do {
            let settings = try await ApelinService.app.gitSettings()
            guard settings.credentials.contains(where: { $0.host == "github.com" }) else {
                openGitHubSignIn(from: presenter)
                return
            }
            let versions = Set(items.map(\.version))
            guard versions.count == 1, let version = versions.first else {
                presenter.presentNotice(
                    title: "Packages of Different Versions",
                    message: "A release holds one version of a package. Choose packages of the same version.",
                )
                return
            }
            guard let tag = DistributionReleaseRequest.tag(forVersion: version) else {
                presenter.presentNotice(
                    title: "Unsupported Version",
                    message: "The release tag is v followed by the version, which can use only letters, digits, periods, hyphens and underscores. Change version \(version), then build again.",
                )
                return
            }
            let project = try await DistributionProject.resolve(named: projectName)
            guard let commit = try await ApelinService.app.gitStatus(projectID: project.id).head else {
                presenter.presentNotice(
                    title: "No Commit to Release",
                    message: "Commit this project and push it to GitHub, then publish the release.",
                )
                return
            }
            let files = try await Task.detached { () throws -> [(path: String, digest: String)] in
                try items.map { item -> (path: String, digest: String) in
                    let file = try DistributionPackages.verify(path: item.path, digest: item.digest)
                    return (file.path, item.digest)
                }
            }.value
            let remotes = try await ApelinService.app.gitRemoteList(projectID: project.id).remotes
            let draft = ReleaseDraft(projectID: project.id, tag: tag, commit: commit, files: files, titles: items.map(\.title))
            if let repository = gitHubRepository(of: remotes) {
                confirm(draft, repository: repository, from: presenter)
            } else {
                askRepository(from: presenter) { [weak presenter] repository in
                    guard let presenter else { return }
                    confirm(draft, repository: repository, from: presenter)
                }
            }
        } catch {
            presenter.presentNotice(title: "Unable to Publish Release", message: error.readableMessage)
        }
    }

    /// `owner/name` of the project's remote on github.com, origin first.
    private static func gitHubRepository(of remotes: [GitRemoteSummary]) -> String? {
        let ordered = remotes.filter { $0.name == "origin" } + remotes.filter { $0.name != "origin" }
        return ordered.lazy.compactMap { $0.url.flatMap(GitHubName.fullName(remoteURL:)) }.first
    }

    /// The repository to publish to, as `owner/name`, for a project with no
    /// remote on github.com.
    private static func askRepository(from presenter: UIViewController, then: @escaping @MainActor (String) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "GitHub Repository"),
            message: String(localized: "This project has no GitHub remote. Enter the repository to publish to as owner/name. This project’s commit must already be pushed there."),
            preferredStyle: .alert,
        )
        alert.addTextField {
            $0.placeholder = "owner/name"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.keyboardType = .asciiCapable
            $0.clearButtonMode = .whileEditing
            $0.accessibilityLabel = String(localized: "GitHub Repository")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Continue"), style: .default) { [weak alert, weak presenter] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            guard GitHubName.isFullName(name) else {
                presenter?.presentNotice(
                    title: "Invalid Repository",
                    message: "Enter the repository as owner/name, such as octocat/hello-world.",
                )
                return
            }
            then(name)
        })
        presenter.present(alert, animated: true)
    }

    private static func confirm(_ draft: ReleaseDraft, repository: String, from presenter: UIViewController) {
        let packages = draft.titles.joined(separator: "\n")
        let commit = String(draft.commit.prefix(7))
        presenter.presentConfirmation(
            title: "Publish \(draft.tag) to GitHub?",
            message: "\(packages)\n\nThe release \(draft.tag) of \(repository) is tagged at commit \(commit), which must already be on GitHub. Each package is uploaded as it was built, with a SHA256SUMS file.",
            confirmTitle: "Publish",
        ) { [weak presenter] in
            guard let presenter else { return }
            start(draft, repository: repository, from: presenter)
        }
    }

    /// The release followed on the progress card, whose Cancel stops the
    /// task; a draft it leaves is filled in by the next release.
    private static func start(_ draft: ReleaseDraft, repository: String, from presenter: UIViewController) {
        Task { [weak presenter] in
            guard let presenter else { return }
            do {
                let result = try await ProgressCard.run(
                    title: String(localized: "Publishing to GitHub…"),
                    message: "\(repository) \(draft.tag)",
                    cancellable: true,
                    from: presenter,
                ) { update in
                    try await follow(draft, repository: repository, update: update)
                }
                offer(result, from: presenter)
            } catch is CancellationError {
                // stopped from the card; the worker cleans its own staging
            } catch {
                presenter.presentNotice(title: "Unable to Publish Release", message: error.readableMessage)
            }
        }
    }

    /// Starts the release and reads it to its end; a cancel of the card
    /// stops the host's task too.
    private static func follow(
        _ draft: ReleaseDraft,
        repository: String,
        update: @escaping @MainActor (ProgressCard.Status) -> Void,
    ) async throws -> DistributionReleaseResult {
        let handle = try await ApelinService.app.distributionRelease(DistributionReleaseRequest(
            projectID: draft.projectID,
            repository: repository,
            files: draft.files.map(\.path),
            digests: draft.files.map(\.digest),
            tag: draft.tag,
            commit: draft.commit,
        ))
        var progress = EnvironmentTaskProgress(work: .distributionRelease)
        var result: DistributionReleaseResult?
        try await withTaskCancellationHandler {
            for try await event in ApelinService.app.events(of: handle) {
                progress.apply(event)
                if event.kind == "result" {
                    result = try? event.payload?.decode(DistributionReleaseResult.self)
                } else if event.kind == TaskEvent.stateKind, let value = event.payload?["result"] {
                    result = (try? value.decode(DistributionReleaseResult.self)) ?? result
                }
                update(ProgressCard.Status(subtitle: progress.stage.map(EnvironmentTaskProgress.activeTitle(of:)) ?? ""))
            }
        } onCancel: {
            Task { try? await ApelinService.app.environmentCancel(taskID: handle.taskID) }
        }
        try Task.checkCancellation()
        guard progress.state == .succeeded, let result else {
            throw ApelinError(.internal, progress.outcomeMessage)
        }
        return result
    }

    /// Done, with the release to open on GitHub, and what the release said
    /// that did not stop it.
    private static func offer(_ result: DistributionReleaseResult, from presenter: UIViewController) {
        let summary = if result.uploaded.isEmpty, result.checksums == "unchanged", !result.created {
            String(localized: "The release \(result.tag) of \(result.repository) already had these packages.")
        } else {
            String(localized: "The release \(result.tag) of \(result.repository) is published.")
        }
        let message = ([summary] + result.warnings).joined(separator: "\n\n")
        guard let url = URL(string: result.url), url.scheme?.lowercased() == "https" else {
            presenter.presentNotice(title: "Release Published", message: message)
            return
        }
        presenter.presentConfirmation(
            title: "Release Published",
            message: String.LocalizationValue(message),
            cancelTitle: "Done",
            confirmTitle: "Open Release",
        ) {
            UIApplication.shared.open(url)
        }
    }

    /// Settings ▸ Git over `presenter`, where Sign In with GitHub is; the
    /// indicator says why it opened.
    private static func openGitHubSignIn(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil else { return }
        SPIndicator.present(title: String(localized: "Sign In with GitHub First"), preset: .error, haptic: .warning)
        SettingsViewController.presentGit(from: presenter)
    }
}
