// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// Measures attributed text on one TextKit stack kept for the purpose, so
/// the composer can size its text view before the text view lays out.
final class TextMeasurement {
    static let shared = TextMeasurement()

    private let textStorage: NSTextStorage
    private let textContainer: NSTextContainer
    private let layoutManager: NSLayoutManager

    private let lock = NSLock()

    init() {
        textStorage = NSTextStorage()
        textContainer = NSTextContainer(size: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
        layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        textContainer.lineFragmentPadding = 0
    }

    @objc dynamic func measureSize(
        of attributedString: NSAttributedString,
        usingWidth width: CGFloat,
        lineLimit: Int = 0,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail,
    ) -> CGSize {
        lock.lock()
        defer { lock.unlock() }

        textContainer.size = CGSize(width: width, height: .infinity)
        textContainer.maximumNumberOfLines = lineLimit
        textContainer.lineBreakMode = lineBreakMode
        textStorage.beginEditing()
        textStorage.setAttributedString(attributedString)
        textStorage.endEditing()

        let size = layoutManager.usedRect(for: textContainer).size
        return .init(width: ceil(size.width), height: ceil(size.height))
    }
}
