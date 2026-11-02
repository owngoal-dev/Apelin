import ApelinProtocol
import CoreImage.CIFilterBuiltins
import UIKit

/// What the package repository's card shows: the icon and title the user
/// chose (`RepositoryCardStyle`), the source address, the GitHub owner, and
/// a QR code a camera opens in Irisin as
/// `irisin://repository/add?url=<source address>`, which adds the source.
struct RepositoryCard {
    var title: String
    /// The source address without its scheme or trailing slash.
    var address: String
    var owner: String
    var icon: UIImage
    /// The QR code's modules, row by row, without the quiet zone.
    let modules: [[Bool]]

    init(repository: DistributionRepository, style: RepositoryCardStyle) {
        let parts = repository.fullName.split(separator: "/", maxSplits: 1).map(String.init)
        owner = parts.first ?? repository.fullName
        title = style.title ?? parts.last ?? repository.fullName
        address = repository.sourceURL
            .replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        icon = style.icon.flatMap(UIImage.init(data:)) ?? UIImage(named: "AppIconMark") ?? UIImage()
        modules = Self.modules(for: Self.irisinLink(source: repository.sourceURL))
    }

    /// Irisin's add-repository link (`IrisinLink` in Irisin): the address
    /// whole, with its own scheme, as the one `url` item.
    static func irisinLink(source: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#%")
        return "irisin://repository/add?url=" + (source.addingPercentEncoding(withAllowedCharacters: allowed) ?? source)
    }

    private static func modules(for text: String) -> [[Bool]] {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return [] }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0,
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn, width > 2, height > 2 else { return [] }
        // the generator leaves one module of quiet zone on each side; the
        // card's white is the quiet zone instead
        return (1 ..< height - 1).map { y in (1 ..< width - 1).map { x in pixels[y * width + x] < 128 } }
    }
}

/// The card's own choices, per repository, in the app's defaults: a title
/// in place of the repository's name, and an icon in place of Apelin's.
struct RepositoryCardStyle: Codable, Equatable {
    var title: String?
    /// A square PNG, at most `iconSide` pixels a side.
    var icon: Data?

    static let iconSide: CGFloat = 256

    private static func key(_ repository: DistributionRepository) -> String {
        "repositoryCard." + repository.fullName
    }

    static func load(for repository: DistributionRepository) -> RepositoryCardStyle {
        UserDefaults.standard.data(forKey: key(repository))
            // persisted-read: one preference, a card's look; its default is harmless
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? RepositoryCardStyle()
    }

    func save(for repository: DistributionRepository) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(repository))
    }

    /// `image` cropped to its centre square and scaled to `iconSide`, as PNG.
    static func iconData(from image: UIImage) -> Data? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let scale = min(1, iconSide / side)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let target = CGSize(width: side * scale, height: side * scale)
        return UIGraphicsImageRenderer(size: target, format: format).pngData { _ in
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(
                x: (target.width - drawn.width) / 2,
                y: (target.height - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height,
            ))
        }
    }
}
