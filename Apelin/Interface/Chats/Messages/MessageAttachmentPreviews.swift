import ImageIO
import PDFKit
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// Presentation thumbnails never replace the original attachment or its MIME type.
@MainActor
final class MessageAttachmentPreviews {
    static let shared = MessageAttachmentPreviews()
    private final class Result: NSObject {
        let image: UIImage?
        /// The original's pixels, upright, when ImageIO read it: the
        /// thumbnail is never larger than 1080 pixels a side.
        let pixelSize: CGSize?
        init(_ image: UIImage?, pixelSize: CGSize? = nil) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    private let cache = NSCache<NSUUID, Result>()
    private var pending: [UUID: [() -> Void]] = [:]

    private init() {
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for attachment: ComposerAttachment) -> UIImage? {
        result(for: attachment).image
    }

    /// The original image's size in pixels, upright; nil for a PDF page or a
    /// Quick Look thumbnail.
    func pixelSize(for attachment: ComposerAttachment) -> CGSize? {
        result(for: attachment).pixelSize
    }

    private func result(for attachment: ComposerAttachment) -> Result {
        if let result = cache.object(forKey: attachment.id as NSUUID) {
            return result
        }
        let result: Result
        if let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
           let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 1080,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary)
        {
            result = Result(UIImage(cgImage: thumbnail), pixelSize: Self.uprightPixelSize(source))
        } else if attachment.data.starts(with: Data("%PDF".utf8)),
                  let page = PDFDocument(data: attachment.data)?.page(at: 0)
        {
            result = Result(page.thumbnail(of: CGSize(width: 540, height: 720), for: .mediaBox))
        } else {
            // left uncached, so `prepare` can still ask Quick Look
            return Result(nil)
        }
        store(result, for: attachment.id)
        return result
    }

    private static func uprightPixelSize(_ source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return nil }
        // EXIF orientations 5 to 8 turn the picture a quarter
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5 ... 8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    func prepare(_ attachment: ComposerAttachment, completion: @escaping () -> Void) {
        guard image(for: attachment) == nil,
              cache.object(forKey: attachment.id as NSUUID) == nil,
              attachment.text == nil,
              UTType(filenameExtension: (attachment.name as NSString).pathExtension)?.conforms(to: .text) != true
        else { return }
        if pending[attachment.id] != nil {
            pending[attachment.id]?.append(completion)
            return
        }
        pending[attachment.id] = [completion]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent((attachment.name as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try attachment.data.write(to: file, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { [self] in finish(nil, for: attachment.id) }
            return
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: file,
            size: CGSize(width: 540, height: 540),
            scale: 2,
            representationTypes: .thumbnail,
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let image = representation?.type == .thumbnail ? representation?.uiImage : nil
            DispatchQueue.main.async { [self] in
                try? FileManager.default.removeItem(at: directory)
                finish(image, for: attachment.id)
            }
        }
    }

    @objc dynamic private func store(_ result: Result, for id: UUID) {
        let cost = result.image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        cache.setObject(result, forKey: id as NSUUID, cost: cost)
    }

    @objc dynamic private func finish(_ image: UIImage?, for id: UUID) {
        store(Result(image), for: id)
        let callbacks = pending.removeValue(forKey: id) ?? []
        callbacks.forEach { $0() }
    }
}
