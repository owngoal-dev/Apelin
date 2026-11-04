import ApelinProtocol
import SPIndicator
import UIKit

/// The package repository's flows, from Settings ▸ Git and from the welcome
/// pages alike: Create asks whose it is when the account is in an
/// organization, then for a name, and follows the creation; Link picks
/// one of the account's repositories (`DistributionRepositoryPickerController`)
/// and follows the link; Update overwrites the files the template maintains
/// after a warning; Unlink asks first. Each task is followed on
/// `EnvironmentTaskController`, pushed onto the presenter's navigation, and
/// `onChange` is told when anything may have changed.
@MainActor
final class DistributionRepositoryFlow {
    @objc private dynamic weak var presenter: UIViewController?
    private let onChange: () -> Void
    @objc private dynamic var isPreparingCreation = false

    init(presenter: UIViewController, onChange: @escaping () -> Void) {
        self.presenter = presenter
        self.onChange = onChange
    }

    /// The account or one of its organizations, when it has any, then the name.
    @objc dynamic func create(onLoadingChange: @escaping (Bool) -> Void = { _ in }) {
        guard !isPreparingCreation else { return }
        isPreparingCreation = true
        onLoadingChange(true)
        Task { [weak self] in
            guard let self else {
                onLoadingChange(false)
                return
            }
            // without the list (no network, say) the account is the owner
            let answer = try? await ApelinService.app.distributionRepositoryList(repositories: true)
            isPreparingCreation = false
            onLoadingChange(false)
            guard let account = answer?.account, let organizations = answer?.organizations, !organizations.isEmpty else {
                askName(owner: nil)
                return
            }
            chooseOwner(account: account, organizations: organizations)
        }
    }

    @objc private dynamic func chooseOwner(account: String, organizations: [String]) {
        let alert = UIAlertController(
            title: String(localized: "Choose an Owner"),
            message: String(localized: "Create the repository on your account or in one of your organizations."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: account, style: .default) { [weak self] _ in
            self?.askName(owner: nil)
        })
        for organization in organizations {
            alert.addAction(UIAlertAction(title: organization, style: .default) { [weak self] _ in
                self?.askName(owner: organization)
            })
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        presenter?.present(alert, animated: true)
    }

    /// The name field, filled with a name that reads as a source.
    @objc private dynamic func askName(owner: String?) {
        let message = if let owner {
            String(localized: "A public repository in the organization \(owner), published with GitHub Pages as a package source.")
        } else {
            String(localized: "A public repository on your GitHub account, published with GitHub Pages as a package source.")
        }
        let alert = UIAlertController(
            title: String(localized: "Create Distribution Repository"),
            message: message,
            preferredStyle: .alert,
        )
        alert.addTextField {
            $0.text = "packages"
            $0.placeholder = "packages"
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.keyboardType = .asciiCapable
            $0.clearButtonMode = .whileEditing
            $0.accessibilityLabel = String(localized: "Repository Name")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Create"), style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            self?.start(
                work: .distributionCreate,
                title: String(localized: "Creating Repository"),
                doneTitle: String(localized: "Repository Ready"),
            ) { try await ApelinService.app.distributionRepositoryCreate(name: name, owner: owner) }
        })
        presenter?.present(alert, animated: true)
    }

    /// The account's repositories to link one.
    @objc dynamic func pick() {
        let picker = DistributionRepositoryPickerController { [weak self] candidate in
            self?.confirmLink(candidate)
        }
        presenter?.navigationController?.pushViewController(picker, animated: true)
    }

    private func confirmLink(_ candidate: DistributionRepositoryCandidate) {
        presenter?.presentConfirmation(
            title: "Link \(candidate.fullName)?",
            message: "Apelin clones it as a project, adds the package index’s files it lacks — a GitHub Pages workflow and an index script — without changing any it has, pushes them, and turns on GitHub Pages.",
            confirmTitle: "Link",
        ) { [weak self] in
            self?.start(
                work: .distributionLink,
                title: String(localized: "Linking Repository"),
                doneTitle: String(localized: "Repository Linked"),
            ) { try await ApelinService.app.distributionRepositoryLink(fullName: candidate.fullName) }
        }
    }

    /// Apelin's current template over the files it maintains, after a
    /// warning that whatever the user changed in them is replaced.
    func confirmUpdate(_ repository: DistributionRepository) {
        presenter?.presentConfirmation(
            title: "Update \(repository.fullName)?",
            message: "This overwrites the repository’s home page, README, icon, GitHub Pages workflow and index script with Apelin’s current template, replacing any changes made to them, then commits and pushes. Packages, depictions and banners stay as they are.",
            confirmTitle: "Update",
            destructive: true,
        ) { [weak self] in
            self?.start(
                work: .distributionLink,
                title: String(localized: "Updating Repository"),
                doneTitle: String(localized: "Repository Updated"),
            ) { try await ApelinService.app.distributionRepositoryLink(fullName: repository.fullName, overwrite: true) }
        }
    }

    func confirmUnlink(_ repository: DistributionRepository) {
        presenter?.presentConfirmation(
            title: "Unlink \(repository.fullName)?",
            message: "“Distribute…” stops publishing to it. The repository on GitHub and its project stay as they are.",
            confirmTitle: "Unlink",
            destructive: true,
        ) { [weak self] in
            Task { [weak self] in
                do {
                    try await ApelinService.app.distributionRepositoryUnlink()
                    SPIndicator.present(title: String(localized: "Unlinked"), preset: .done, haptic: .success)
                } catch {
                    self?.presenter?.presentNotice(title: "Unable to Unlink", message: error.readableMessage)
                }
                self?.onChange()
            }
        }
    }

    /// Starts the task and follows it on its own page, which replaces the
    /// picker when a link came from there.
    private func start(
        work: EnvironmentTaskProgress.Work,
        title: String,
        doneTitle: String,
        _ request: @escaping () async throws -> TaskHandle,
    ) {
        Task { [weak self] in
            guard let self, let navigation = presenter?.navigationController else { return }
            do {
                let handle = try await request()
                let page = EnvironmentTaskController(handle: handle, work: work, title: title, doneTitle: doneTitle)
                page.onFinish = { [weak self] in self?.onChange() }
                var stack = navigation.viewControllers
                if stack.last is DistributionRepositoryPickerController {
                    stack.removeLast()
                }
                navigation.setViewControllers(stack + [page], animated: true)
            } catch {
                presenter?.presentNotice(title: "Unable to Start", message: error.readableMessage)
            }
        }
    }
}
