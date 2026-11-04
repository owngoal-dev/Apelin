// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import ApelinCore
import ApelinProtocol
import PDFKit
import PhotosUI
import ScrubberKit
import UIKit
import UniformTypeIdentifiers

/// FlowDown's camera, photo, file, webpage and drop imports. Each instance
/// keeps the callback for the draft that opened it, including after a chat
/// switch.
final class ComposerAttachmentImport: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate
{
    @objc dynamic private weak var presenter: UIViewController?
    private let receive: (ComposerAttachment) -> Void

    init(presenter: UIViewController, receive: @escaping (ComposerAttachment) -> Void) {
        self.presenter = presenter
        self.receive = receive
    }

    @objc dynamic func camera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            presenter?.presentNotice(
                title: "Camera Unavailable",
                message: String(localized: "This device does not have an available camera."),
            )
            return
        }
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.image.identifier]
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func photos() {
        var configuration = PHPickerConfiguration()
        configuration.selectionLimit = 4
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func files() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .image, .text, .pdf, .audio])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    @objc dynamic func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any],
    ) {
        picker.dismiss(animated: true)
        if let image = info[.originalImage] as? UIImage {
            importImage(image)
        }
    }

    @objc dynamic func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            result.itemProvider.loadObject(ofClass: UIImage.self) { [self] reading, _ in
                Task { @MainActor in
                    guard let image = reading as? UIImage else { return }
                    importImage(image)
                }
            }
        }
    }

    @objc dynamic func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        Task { @MainActor [self] in
            for url in urls {
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer {
                            if scoped {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        return try Self.readAttachment(at: url, name: url.lastPathComponent)
                    }.value
                    receive(attachment)
                } catch {
                    presenter?.presentNotice(title: "Unable to Import File", message: error.readableMessage)
                }
            }
        }
    }

    /// FlowDown's drop: each item's file, read as a pick from Files is,
    /// except that an image goes in as a photo does (`importImage`), as
    /// FlowDown's own import treats one. Bound to the draft that took the
    /// drop, as a picker is.
    @objc dynamic func drop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { [self] url, error in
                // the system deletes its copy once this returns
                let read = Result { () throws -> ComposerAttachment in
                    guard let url else {
                        throw error ?? ApelinError(
                            .badRequest,
                            String(localized: "The dropped item could not be read."),
                        )
                    }
                    return try Self.readAttachment(at: url, name: url.lastPathComponent)
                }
                Task { @MainActor in
                    do {
                        let attachment = try read.get()
                        if attachment.isImage, let image = UIImage(data: attachment.data) {
                            importImage(image)
                        } else {
                            receive(attachment)
                        }
                    } catch {
                        presenter?.presentNotice(title: "Unable to Import File", message: error.readableMessage)
                    }
                }
            }
        }
    }

    /// `url` as an attachment named `name`: a regular file of at most 32 MB,
    /// read by its canonical path, an image or else text (a PDF's own).
    nonisolated static func readAttachment(at url: URL, name: String) throws -> ComposerAttachment {
        guard let path = CanonicalPath.resolve(url.path) else {
            throw ApelinError(.badRequest, String(localized: "The selected file could not be read."))
        }
        let source = URL(fileURLWithPath: path)
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 32 * 1024 * 1024 else {
            throw ApelinError(
                .badRequest,
                String(localized: "Choose a regular file smaller than 32 MB."),
            )
        }
        let data = try Data(contentsOf: source)
        guard data.count <= 32 * 1024 * 1024 else {
            throw ApelinError(.badRequest, String(localized: "Choose a file smaller than 32 MB."))
        }
        let image = UIImage(data: data) != nil
        let text = source.pathExtension.lowercased() == "pdf"
            ? PDFDocument(data: data)?.string
            : String(data: data, encoding: .utf8)
        return ComposerAttachment(
            name: name,
            data: data,
            text: image ? nil : text,
            isImage: image,
        )
    }

    @objc dynamic func importImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85), data.count <= 32 * 1024 * 1024 else {
            presenter?.presentNotice(
                title: "Unable to Import Image",
                message: String(localized: "Choose an image smaller than 32 MB."),
            )
            return
        }
        receive(ComposerAttachment(name: String(localized: "Image") + ".jpeg", data: data, text: nil, isImage: true))
    }

    @objc dynamic func importText(_ text: String, name: String = String(localized: "Pasted Text")) {
        guard !text.isEmpty else { return }
        receive(ComposerAttachment(name: name + ".txt", data: Data(text.utf8), text: text))
    }

    @objc dynamic func paste() {
        let pasteboard = UIPasteboard.general
        if let image = pasteboard.image {
            importImage(image)
        } else if let text = pasteboard.string {
            importText(text)
        }
    }

    @objc dynamic func web() {
        let alert = UIAlertController(
            title: String(localized: "Capture Web Content"),
            message: String(localized: "Enter the webpage address to attach its text."),
            preferredStyle: .alert,
        )
        alert.addTextField {
            $0.placeholder = "https://"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.accessibilityLabel = String(localized: "Web Address")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Capture"), style: .default) { [self, weak alert] _ in
            let value = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased()),
                  url.host != nil
            else {
                presenter?.presentNotice(
                    title: "Invalid Web Address",
                    message: String(localized: "Enter a complete http or https address."),
                )
                return
            }
            Task { @MainActor [self] in
                guard let presenter else { return }
                do {
                    let document: Scrubber.Document? = try await ProgressCard.run(
                        title: String(localized: "Fetching Content"),
                        message: value,
                        cancellable: false,
                        from: presenter,
                    ) { _ in
                        await withCheckedContinuation { continuation in
                            Scrubber.document(for: url) { continuation.resume(returning: $0) }
                        }
                    }
                    guard let document, !document.textDocument.isEmpty else {
                        throw ApelinError(
                            .unavailable,
                            String(localized: "The webpage did not return readable content."),
                        )
                    }
                    importText(document.textDocument, name: document.title)
                } catch {
                    presenter.presentNotice(title: "Unable to Capture Webpage", message: error.readableMessage)
                }
            }
        })
        presenter?.present(alert, animated: true)
    }
}
