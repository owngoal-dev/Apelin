// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import ImageIO
import QuickLook
import UniformTypeIdentifiers

/// Quick Look owns the view; this controller owns the temporary preview copy.
final class ComposerAttachmentPreview: QLPreviewController, QLPreviewControllerDataSource {
    private let directory: URL
    private let files: [URL]

    convenience init(attachment: ComposerAttachment) throws {
        try self.init(attachments: [attachment], selectedID: attachment.id)
    }

    init(attachments: [ComposerAttachment], selectedID: UUID) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.directory = directory
        do {
            files = try attachments.enumerated().map { index, attachment in
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var name = (attachment.name as NSString).lastPathComponent
                if attachment.isImage, (name as NSString).pathExtension.isEmpty,
                   let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
                   let type = CGImageSourceGetType(source),
                   let suffix = UTType(type as String)?.preferredFilenameExtension
                {
                    name += "." + suffix
                }
                let file = folder.appendingPathComponent(name)
                try attachment.data.write(to: file, options: .atomic)
                return file
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        currentPreviewItemIndex = attachments.firstIndex { $0.id == selectedID } ?? 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(attachment:)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @objc dynamic func numberOfPreviewItems(in _: QLPreviewController) -> Int {
        files.count
    }

    @objc dynamic func previewController(_: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        files[index] as NSURL
    }
}
