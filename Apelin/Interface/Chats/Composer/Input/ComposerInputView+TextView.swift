// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    /// The text view, with a hardware keyboard's return keys: return sends
    /// (or breaks the line, by `ComposerBehavior`), ⌘ return sends, ⌥ return
    /// breaks the line. A pasted image, or a long paste, goes to the
    /// composer instead of the text.
    class TextEditorView: UITextView {
        init() {
            super.init(frame: .zero, textContainer: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Use init()")
        }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(insertNewLine)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed)),
                UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnPressed)),
            ]
        }

        @objc dynamic var onReturnKeyPressed: () -> Void = {}
        @objc dynamic var onCommandReturnKeyPressed: () -> Void = {}
        @objc dynamic var onImagePasted: (UIImage) -> Void = { _ in }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                // no need to check the pasteboard: reading it asks the user
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if let image = UIPasteboard.general.image {
                onImagePasted(image)
                return
            }
            if ComposerBehavior.pasteLargeTextContentAsFile,
               let text = UIPasteboard.general.string,
               text.count > ComposerBehavior.longPasteThreshold
            {
                var superView: UIView? = self
                while superView != nil, !(superView is ComposerInputView) {
                    superView = superView?.superview
                }
                guard let editor = superView as? ComposerInputView else { return }
                editor.delegate?.onComposerInputPastingLargeTextAsDocument(content: text)
                return
            }
            super.paste(sender)
        }

        @objc dynamic private func insertNewLine() {
            insertText("\n")
        }

        @objc dynamic private func returnPressed() {
            onReturnKeyPressed()
        }

        @objc dynamic private func commandReturnPressed() {
            onCommandReturnKeyPressed()
        }
    }
}

extension ComposerInputView: UITextViewDelegate {
    @objc dynamic func textViewDidBeginEditing(_ textView: UITextView) {
        delegate?.onComposerInputBeginEditing()
        updateTextHeight()
        delegate?.onComposerInputTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    @objc dynamic func textViewDidEndEditing(_ textView: UITextView) {
        clearAttributedText()
        updateTextHeight()
        delegate?.onComposerInputTextChanged(text: textView.text)
        delegate?.onComposerInputEndEditing()
        switchToRequiredStatus()
    }

    @objc dynamic func textViewDidChange(_ textView: UITextView) {
        updatePlaceholderAlpha()
        updateTextHeight()
        delegate?.onComposerInputTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    @objc dynamic func textView(
        _ textView: UITextView,
        editMenuForTextIn _: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        let pasteboard = UIPasteboard.general
        let canPasteAttachment = pasteboard.hasStrings

        let actions: [UIAction] = [
            UIAction(title: String(localized: "Insert New Line")) { _ in
                textView.insertText("\n")
            },
            UIAction(
                title: String(localized: "Paste as Attachment"),
                attributes: canPasteAttachment ? [] : [.disabled],
            ) { [weak self] _ in
                self?.delegate?.onComposerInputPasteAsAttachmentTapped()
            },
            UIAction(title: String(localized: "More")) { [weak self] _ in
                self?.delegate?.onComposerInputMoreButtonTapped()
            },
        ]
        return UIMenu(children: suggestedActions + actions)
    }

    @objc dynamic func textView(_ textView: UITextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
        if text == "\n", !ComposerBehavior.useConfirmationOnSend {
            textView.resignFirstResponder()
            delegate?.onComposerInputSubmitButtonTapped()
            return false
        }
        return true
    }

    @objc dynamic func updatePlaceholderAlpha() {
        placeholderLabel.alpha = textView.text.isEmpty ? 1 : 0
    }

    @objc dynamic func updateTextHeight() {
        let attrText = textView.attributedText ?? .init()
        let textHeight = TextMeasurement.shared.measureSize(
            of: attrText,
            usingWidth: textView.frame.width,
        ).height
        let decision = ceil(max(textHeight, font.lineHeight))
        doWithAnimation { self.textHeight.send(decision) }
    }

    @objc dynamic func clearAttributedText() {
        let currentText = textView.text
        textView.attributedText = NSAttributedString(
            string: currentText ?? "",
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.label,
            ],
        )
    }
}
