// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// The composer's text band: the text view between its icons, laid out one
/// of three ways. At rest, the camera, the text and More;
/// focused and empty, the camera goes and the text takes its room; with
/// text, More gives way to Send. Right to left, the band is mirrored.
class ComposerInputView: ComposerSectionView {
    let font = UIFont.preferredFont(forTextStyle: .body)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = 200

    let elementClipper = UIView()

    let cameraButton = ComposerIconButton(iconName: "ComposerCamera", label: String(localized: "Camera"))
    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    let moreButton = ComposerIconButton(iconName: "ComposerMore", label: String(localized: "More"))
    let sendButton = ComposerIconButton(iconName: "ComposerSend", label: String(localized: "Send"))

    let inset: UIEdgeInsets = .init(top: 10, left: 10, bottom: 10, right: 10)
    let iconSpacing: CGFloat = 10
    let iconSize = CGSize(width: 30, height: 30)

    enum LayoutStatus {
        case standard
        case preFocusText
        case editingText
    }

    var layoutStatus: LayoutStatus = .standard {
        didSet {
            guard oldValue != layoutStatus else { return }
            setNeedsLayout()
        }
    }

    weak var delegate: Delegate?

    @objc dynamic var hasAttachments = false {
        didSet {
            if hasAttachments != oldValue {
                switchToRequiredStatus()
            }
        }
    }

    @objc dynamic func showPanelState(_ open: Bool) {
        moreButton.change(iconName: open ? "ComposerClose" : "ComposerMore")
        moreButton.accessibilityLabel = open ? String(localized: "Close") : String(localized: "More")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        delegate = nil
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
    }

    override func initializeViews() {
        super.initializeViews()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateReturnKeyType),
            name: .composerBehaviorChanged,
            object: nil,
        )

        cameraButton.tapAction = { [weak self] in
            self?.delegate?.onComposerInputCameraButtonTapped()
        }
        addSubview(elementClipper)
        elementClipper.clipsToBounds = true
        elementClipper.addSubview(cameraButton)
        textView.font = font
        textView.delegate = self
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.textColor = .label
        textView.textAlignment = .natural
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainer.lineFragmentPadding = .zero
        textView.textContainer.maximumNumberOfLines = 0
        textView.clipsToBounds = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.onReturnKeyPressed = { [weak self] in
            guard let self else { return }
            if ComposerBehavior.useConfirmationOnSend {
                textView.insertText("\n")
            } else {
                sendButton.tapAction()
            }
        }
        textView.onCommandReturnKeyPressed = { [weak self] in
            self?.sendButton.tapAction()
        }
        textView.onImagePasted = { [weak self] image in
            self?.delegate?.onComposerInputPastingImage(image: image)
        }
        elementClipper.addSubview(textView)
        let placeholder = String(localized: "Ask anything")
        placeholderLabel.text = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        // the text view is named by it instead; read twice otherwise
        placeholderLabel.isAccessibilityElement = false
        textView.accessibilityLabel = placeholder
        elementClipper.addSubview(placeholderLabel)
        moreButton.tapAction = { [weak self] in
            self?.delegate?.onComposerInputMoreButtonTapped()
        }
        elementClipper.addSubview(moreButton)
        sendButton.tapAction = { [weak self] in
            self?.delegate?.onComposerInputSubmitButtonTapped()
        }
        elementClipper.addSubview(sendButton)

        // the icons and the rest of the band share a height of 30;
        // the band is max(30, textHeight) plus the insets
        textHeight.removeDuplicates()
            .compactMap { [weak self] textHeight -> CGFloat? in
                guard let self else { return nil }
                return max(textLayoutHeight(textHeight), iconSize.height)
                    + inset.top + inset.bottom
            }
            .ensureMainThread()
            .sink { [weak self] height in self?.heightPublisher.send(height) }
            .store(in: &cancellables)
        updateReturnKeyType()
        updateTextHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        elementClipper.frame = bounds

        switch layoutStatus {
        case .standard:
            layoutAsStandard()
        case .preFocusText:
            layoutAsPreEditingText()
        case .editingText:
            layoutAsEditingText()
        }
        // laid out left to right; right to left the camera is on the right
        // and More and Send on the left, as the placeholder reads
        elementClipper.mirrorForLayoutDirection([cameraButton, textView, placeholderLabel, moreButton, sendButton])

        updatePlaceholderAlpha()
    }

    @objc dynamic func set(text: String) {
        textView.text = text
        updatePlaceholderAlpha()
        switchToRequiredStatus()
        updateTextHeight()
    }

    @objc dynamic func updateReturnKeyType() {
        switch ComposerBehavior.useConfirmationOnSend {
        case true:
            textView.returnKeyType = .default
        case false:
            textView.returnKeyType = .send
        }
    }
}
