// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

extension ComposerInputView {
    @objc dynamic func textLayoutHeight(_ input: CGFloat) -> CGFloat {
        var finalHeight = input
        finalHeight = max(font.lineHeight, finalHeight)
        finalHeight = min(finalHeight, maxTextEditorHeight)
        return ceil(finalHeight)
    }

    @objc dynamic func switchToRequiredStatus() {
        assert(Thread.isMainThread)
        // avoid flickering animation if set twice
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(switchToRequiredStatusEx),
            object: nil,
        )
        perform(#selector(switchToRequiredStatusEx), with: nil, afterDelay: 0.1)
    }

    @objc dynamic private func switchToRequiredStatusEx() {
        doWithAnimation { [self] in
            cameraButton.transform = .identity
            moreButton.transform = .identity
            sendButton.transform = .identity
            if textView.isFirstResponder {
                if textView.text.isEmpty, !hasAttachments {
                    layoutStatus = .preFocusText
                } else {
                    layoutStatus = .editingText
                }
            } else {
                if textView.text.isEmpty, !hasAttachments {
                    layoutStatus = .standard
                } else {
                    layoutStatus = .editingText
                }
            }
        }
    }

    @objc dynamic func layoutAsEditingText() {
        // textField | sendButton
        sendButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.alpha = 1
        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height,
        )
        defer { moreButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        moreButton.alpha = 0

        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: (bounds.height - textLayoutHeight) / 2,
            width: sendButton.frame.minX - inset.left - iconSpacing,
            height: textLayoutHeight,
        )
        placeholderLabel.frame = textView.frame

        // invisible element
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0
    }

    @objc dynamic func layoutAsPreEditingText() {
        defer { cameraButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        // invisible elements
        cameraButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 0

        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        moreButton.alpha = 1
        // reset textField width to fill the space
        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: (bounds.height - textLayoutHeight) / 2,
            width: moreButton.frame.minX - inset.left - iconSpacing,
            height: textLayoutHeight,
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame

        // invisible element
        sendButton.frame = CGRect(
            x: bounds.width + iconSpacing + inset.right,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.alpha = 0
    }

    @objc dynamic func layoutAsStandard() {
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        // captureButton | textField | moreButton
        cameraButton.frame = CGRect(
            x: inset.left,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        cameraButton.alpha = 1
        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        moreButton.alpha = 1
        moreButton.transform = .identity
        // reset textField width to fill the space
        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: cameraButton.frame.maxX + iconSpacing,
            y: (bounds.height - textLayoutHeight) / 2,
            width: moreButton.frame.minX - cameraButton.frame.maxX - iconSpacing * 2,
            height: textLayoutHeight,
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame

        // invisible element
        sendButton.frame = CGRect(
            x: bounds.width + inset.right,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height,
        )
        sendButton.alpha = 0
    }
}
