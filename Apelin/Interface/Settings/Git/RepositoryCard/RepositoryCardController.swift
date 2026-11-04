import AlertController
import ApelinProtocol
import Photos
import PhotosUI
import SnapKit
import SPIndicator
import Then
import UIKit

/// Settings ▸ Git ▸ the package repository ▸ Repository Card…: a card
/// someone points the Camera at to add the source in Irisin. Save writes
/// it to Photos; `…` opens Irisin on this device with the same link the
/// card's code holds, chooses the card's icon (or removes it, back to
/// Apelin's) and edits its title, kept per repository
/// (`RepositoryCardStyle`). Nothing sits under the card: an iPad's form
/// sheet has no height to spare.
final class RepositoryCardController: UIViewController, PHPickerViewControllerDelegate {
    private let repository: DistributionRepository
    private var style: RepositoryCardStyle
    private let cardView = RepositoryCardView()

    @objc private dynamic lazy var saveItem = UIBarButtonItem(
        title: String(localized: "Save"),
        primaryAction: UIAction { [weak self] _ in self?.saveToPhotos() },
    )

    /// Remove Icon only while the card has an icon of the user's own.
    @objc private dynamic lazy var moreItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis"),
        menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuActions() ?? [])
        }]),
    ).then { $0.accessibilityLabel = String(localized: "More") }

    @objc private dynamic func menuActions() -> [UIMenuElement] {
        let open = UIAction(
            title: String(localized: "Open in Irisin…"),
            image: UIImage(systemName: "arrow.up.forward.app"),
        ) { [weak self] _ in
            self?.openInIrisin()
        }
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "Choose Icon…"), image: UIImage(systemName: "photo")) { [weak self] _ in
                self?.chooseIcon()
            },
        ]
        if style.icon != nil {
            actions.append(UIAction(
                title: String(localized: "Remove Icon"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
            ) { [weak self] _ in
                self?.change { $0.icon = nil }
            })
        }
        actions.append(UIAction(
            title: String(localized: "Edit Title…"),
            image: UIImage(systemName: "character.cursor.ibeam"),
        ) { [weak self] _ in
            self?.editTitle()
        })
        return [UIMenu(options: .displayInline, children: [open]), UIMenu(options: .displayInline, children: actions)]
    }

    init(repository: DistributionRepository) {
        self.repository = repository
        style = RepositoryCardStyle.load(for: repository)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(repository:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Repository Card")
        view.backgroundColor = .systemGroupedBackground
        // Save rightmost, `…` beside it
        navigationItem.rightBarButtonItems = [saveItem, moreItem]
        view.addSubview(cardView)
        let canvas = RepositoryCardView.canvas
        cardView.snp.makeConstraints { make in
            make.centerX.equalTo(view.safeAreaLayoutGuide)
            make.centerY.equalTo(view.safeAreaLayoutGuide).priority(.high)
            make.top.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(24)
            make.bottom.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-24)
            make.width.equalTo(cardView.snp.height).multipliedBy(canvas.width / canvas.height)
            make.width.lessThanOrEqualTo(canvas.width)
            make.width.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-48)
            make.width.equalTo(canvas.width).priority(.high)
        }
        updateCard()
    }

    @objc private dynamic func updateCard() {
        cardView.card = RepositoryCard(repository: repository, style: style)
    }

    private func change(_ edit: (inout RepositoryCardStyle) -> Void) {
        edit(&style)
        style.save(for: repository)
        updateCard()
    }

    /// Irisin is a dependency of Apelin's, so it is there to take the link.
    @objc private dynamic func openInIrisin() {
        guard let url = URL(string: RepositoryCard.irisinLink(source: repository.sourceURL)) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Title and icon

    @objc private dynamic func editTitle() {
        present(AlertInputViewController(
            title: "Edit Title",
            message: "Leave it empty to use the repository’s name.",
            placeholder: "Title",
            text: style.title ?? "",
            doneButtonText: "Save",
            onConfirm: { [weak self] text in
                let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.change { $0.title = title.isEmpty ? nil : title }
            },
        ), animated: true)
    }

    @objc private dynamic func chooseIcon() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            let data = (object as? UIImage).flatMap(RepositoryCardStyle.iconData(from:))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let data else {
                    presentNotice(title: "Unable to Choose Icon", message: "The image could not be read.")
                    return
                }
                change { $0.icon = data }
            }
        }
    }

    // MARK: - Saving

    @objc private dynamic func saveToPhotos() {
        guard let card = cardView.card, let data = RepositoryCardView.image(of: card).pngData() else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { [weak self] in
                    self?.presentNotice(title: "Unable to Save Image", message: "Allow Apelin to add photos in Settings.")
                }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) { saved, error in
                DispatchQueue.main.async { [weak self] in
                    if saved {
                        SPIndicator.present(title: String(localized: "Saved"), preset: .done, haptic: .success)
                    } else {
                        self?.presentNotice(title: "Unable to Save Image", message: error?.readableMessage ?? "")
                    }
                }
            }
        }
    }
}
