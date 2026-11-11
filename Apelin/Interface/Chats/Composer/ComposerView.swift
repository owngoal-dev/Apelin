// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Combine
import UIKit

/// The composer at the foot of a conversation: its bands stacked top to
/// bottom on one rounded ground, the whole as tall as they want. FlowDown's
/// model row and its import panel sit above the text band; attachments sit
/// above it too, on the ground the text band shares. Files dropped on the
/// ground are attached (`ComposerView+Drop`).
class ComposerView: ComposerSectionView {
    required init() {
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    let inputEditor = ComposerInputView()
    let approvalSection = ComposerApprovalSection()
    let attachmentsBar = ComposerAttachmentsBar()
    let controlPanel = ComposerControlPanel()
    let modelBar = ComposerModelBar()
    private var currentDraft = ComposerDraft()

    let shadowContainer = UIView()
    @objc dynamic private var glassEffectView: UIVisualEffectView?
    /// Over the ground and everything on it, taking only drags; its colour
    /// shows while one is over it.
    let dropContainer = ComposerDropView()
    let dropColorView = UIView()

    @objc dynamic lazy var sectionSubviews: [ComposerSectionView] = [
        approvalSection,
        attachmentsBar,
        inputEditor,
        modelBar,
        controlPanel,
    ]

    let spacing: CGFloat = 10

    weak var delegate: Delegate?
    @objc dynamic private var submissionID: UUID?
    @objc dynamic var fittingHeightConstraint: NSLayoutConstraint = .init()

    private let handlerColor: UIColor = .init {
        switch $0.userInterfaceStyle {
        case .light:
            .white
        default:
            .gray.withAlphaComponent(0.1)
        }
    }

    override func initializeViews() {
        super.initializeViews()

        shadowContainer.layer.cornerRadius = 16
        shadowContainer.layer.cornerCurve = .continuous
        shadowContainer.clipsToBounds = false
        addSubview(shadowContainer)

        if #available(iOS 26, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.layer.cornerRadius = shadowContainer.layer.cornerRadius
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            addSubview(effectView)
            glassEffectView = effectView
        }

        applyShadowStyle()
        approvalSection.horizontalAdjustment = -ChatMarkdownView.blockSpacing

        dropContainer.clipsToBounds = true
        dropContainer.layer.cornerRadius = shadowContainer.layer.cornerRadius
        dropContainer.layer.cornerCurve = .continuous
        addSubview(dropContainer)
        dropColorView.alpha = 0
        dropColorView.backgroundColor = tintColor.withAlphaComponent(0.05)
        dropContainer.addSubview(dropColorView)
        dropContainer.addInteraction(UIDropInteraction(delegate: self))
        defer { bringSubviewToFront(dropContainer) }

        for subview in sectionSubviews {
            addSubview(subview)
        }

        inputEditor.delegate = self
        controlPanel.cameraButton.actionBlock = { [weak self] in self?.delegate?.onComposerCameraTapped() }
        controlPanel.photoButton.actionBlock = { [weak self] in self?.delegate?.onComposerPhotoTapped() }
        controlPanel.fileButton.actionBlock = { [weak self] in self?.delegate?.onComposerFileTapped() }
        controlPanel.webButton.actionBlock = { [weak self] in self?.delegate?.onComposerWebTapped() }
        controlPanel.isPanelOpen.removeDuplicates().sink { [weak self] open in
            self?.inputEditor.showPanelState(open)
            self?.updateModelBarVisibility()
        }.store(in: &cancellables)
        attachmentsBar.onRemove = { [weak self] id in
            guard let self else { return }
            currentDraft.attachments.removeAll { $0.id == id }
            attachmentsBar.show(currentDraft.attachments)
            publishNewEditorStatus()
        }
        attachmentsBar.onPreview = { [weak self] item in self?.delegate?.onComposerPreviewAttachment(item) }

        heightPublisher
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] output in
                self?.updateHeightConstraint(output)
            }
            .store(in: &cancellables)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let presentingRequest = approvalSection.isPresentingRequest
        // A pending request covers these. They keep their own heights while
        // they fade, so nothing inside them is squeezed as the card changes.
        for band in [attachmentsBar, inputEditor, controlPanel] {
            band.alpha = presentingRequest ? 0 : 1
            band.isUserInteractionEnabled = !presentingRequest
            band.accessibilityElementsHidden = presentingRequest
        }

        // The model row and the import panel it hands over to sit above the
        // text band; the attachments and the text follow below them.
        var y = place(modelBar, at: spacing)
        y = place(controlPanel, at: y)
        let inputTop = place(attachmentsBar, at: y)
        place(inputEditor, at: inputTop)
        // the attachments bar, once it is here, shares the input's ground
        let inputFrame = attachmentsBar.heightPublisher.value > 0
            ? attachmentsBar.frame.union(inputEditor.frame) : inputEditor.frame

        // One card morphs between the input and the request: the request's
        // band is cut off at the card's edge, shown or fading, never
        // collapsed to nothing. It covers the input band's place.
        place(
            approvalSection,
            at: inputEditor.frame.minY,
            height: presentingRequest ? approvalSection.heightPublisher.value : inputFrame.height,
        )
        shadowContainer.frame = presentingRequest
            ? approvalSection.frame.insetBy(dx: approvalSection.horizontalAdjustment, dy: 0)
            : inputFrame
        updateShadowGeometry()
        dropContainer.frame = shadowContainer.frame
        dropColorView.frame = dropContainer.bounds

        // The bands above the input are placed first; the composer ends at
        // the input's edge, or at the request card's while one is shown.
        heightPublisher.send(presentingRequest ? approvalSection.frame.maxY : inputEditor.frame.maxY)
    }

    /// Lays `band` out across the composer at `y`, as tall as it asks unless
    /// told otherwise, and answers where the next band starts.
    @discardableResult
    private func place(_ band: ComposerSectionView, at y: CGFloat, height: CGFloat? = nil) -> CGFloat {
        let height = height ?? band.heightPublisher.value
        let horizontalAdjustment = band.horizontalAdjustment
        band.frame = CGRect(
            x: spacing - horizontalAdjustment,
            y: y,
            width: bounds.width - spacing * 2 + horizontalAdjustment * 2,
            height: height,
        )
        return height > 0 ? band.frame.maxY + spacing : y
    }

    @objc dynamic func updateHeightConstraint(_ height: CGFloat) {
        guard fittingHeightConstraint.constant != height else { return }
        fittingHeightConstraint.isActive = false
        fittingHeightConstraint = heightAnchor.constraint(equalToConstant: height)
        fittingHeightConstraint.priority = .defaultHigh
        fittingHeightConstraint.isActive = true
        hostingViewController?.view.layoutIfNeeded()
        setNeedsLayout()
    }

    /// The controller whose view holds the composer, which lays out again
    /// as the composer's height changes. Not SwifterSwift's
    /// `parentViewController`: importing SwifterSwift anywhere makes its
    /// `UIScrollView.scrollToBottom(animated:)` ambiguous with ListView's
    /// across the whole target, and Litext keeps an internal one by that
    /// name too.
    @objc dynamic private var hostingViewController: UIViewController? {
        var responder = next
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    func showApproval(_ message: ChatMessage?) {
        if message != nil {
            inputEditor.endEditing(true)
            controlPanel.close()
        }
        approvalSection.show(message)
        updateModelBarVisibility()
    }

    @objc dynamic private func updateModelBarVisibility() {
        modelBar.setVisible(!approvalSection.isPresentingRequest && !controlPanel.isPanelOpen.value)
    }

    /// What is typed, trimmed.
    @objc dynamic var text: String {
        (inputEditor.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What is typed, as typed: the draft a conversation keeps.
    var draft: ComposerDraft {
        var draft = currentDraft
        draft.text = inputEditor.textView.text ?? ""
        return draft
    }

    /// The drop's tint, faint: the accent at 5%, the window's once the
    /// composer is in it.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        dropColorView.backgroundColor = tintColor.withAlphaComponent(0.05)
    }

    /// The ground under the composer's bands: glass on iOS 26, a white card
    /// with a soft shadow before it.
    @objc dynamic private func applyShadowStyle() {
        if let glassEffectView {
            shadowContainer.backgroundColor = .clear
            shadowContainer.layer.shadowOpacity = 0
            glassEffectView.isHidden = false
        } else {
            shadowContainer.backgroundColor = handlerColor
            shadowContainer.layer.shadowColor = UIColor.black.cgColor
            shadowContainer.layer.shadowOpacity = 0.08
            shadowContainer.layer.shadowRadius = 8
            shadowContainer.layer.shadowOffset = .zero
        }
    }

    @objc dynamic private func updateShadowGeometry() {
        if let glassEffectView {
            shadowContainer.layer.shadowPath = nil
            glassEffectView.frame = shadowContainer.frame
        } else {
            shadowContainer.layer.shadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: shadowContainer.frame.size),
                cornerRadius: shadowContainer.layer.cornerRadius,
            ).cgPath
        }
    }

    /// Back to empty and at rest.
    @objc dynamic func resetValues() {
        currentDraft = ComposerDraft()
        attachmentsBar.show([])
        controlPanel.close()
        inputEditor.set(text: "")
        inputEditor.endEditing(true)
        setNeedsLayout()
        publishNewEditorStatus()
    }

    /// Shows another conversation's draft. The delegate is not told: the
    /// text is that conversation's already.
    func restore(draft: ComposerDraft) {
        // A reply to the previous conversation must not hold this one's Send.
        submissionID = nil
        currentDraft = draft
        attachmentsBar.show(draft.attachments)
        inputEditor.hasAttachments = !draft.attachments.isEmpty
        controlPanel.close()
        inputEditor.set(text: draft.text)
    }

    /// The keyboard up on the text, as a tap on it would bring it; not
    /// while an approval covers the input.
    @objc dynamic func beginEditing() {
        guard !approvalSection.isPresentingRequest else { return }
        inputEditor.textView.becomeFirstResponder()
    }

    func insertAttachment(_ attachment: ComposerAttachment) {
        currentDraft.attachments.append(attachment)
        attachmentsBar.show(currentDraft.attachments)
        inputEditor.hasAttachments = true
        publishNewEditorStatus()
    }

    @objc dynamic func submitValues() {
        var draft = draft
        draft.text = text
        guard !draft.text.isEmpty || !draft.attachments.isEmpty, submissionID == nil, let delegate else { return }
        if draft.text.isEmpty {
            draft.text = String(localized: "Added \(draft.attachments.count) attachments")
        }
        let id = UUID()
        submissionID = id
        // The message shows in the conversation at once, so the composer
        // empties now; another Send waits until this one is answered.
        delegate.onComposerSubmit(draft: draft) { [weak self] in
            guard let self, submissionID == id else { return }
            submissionID = nil
        }
        // A delegate that answered at once sent nothing: the text stays.
        if submissionID == id {
            resetValues()
        }
    }

    @objc dynamic func publishNewEditorStatus() {
        assert(Thread.isMainThread)
        inputEditor.hasAttachments = !currentDraft.attachments.isEmpty
        delegate?.onComposerUpdateDraft(draft)
    }
}

extension ComposerView: ComposerInputView.Delegate {
    @objc dynamic func onComposerInputCameraButtonTapped() {
        delegate?.onComposerCameraTapped()
    }

    @objc dynamic func onComposerInputMoreButtonTapped() {
        endEditing(true)
        controlPanel.toggle()
    }

    @objc dynamic func onComposerInputBeginEditing() {
        controlPanel.close()
        delegate?.onComposerBeginEditing()
    }

    @objc dynamic func onComposerInputPasteAsAttachmentTapped() {
        delegate?.onComposerPasteAsAttachmentTapped()
    }

    @objc dynamic func onComposerInputSubmitButtonTapped() {
        submitValues()
    }

    @objc dynamic func onComposerInputEndEditing() {
        publishNewEditorStatus()
    }

    @objc dynamic func onComposerInputPastingLargeTextAsDocument(content: String) {
        delegate?.onComposerPastedLongText(content)
    }

    @objc dynamic func onComposerInputPastingImage(image: UIImage) {
        delegate?.onComposerPastedImage(image)
    }

    @objc dynamic func onComposerInputTextChanged(text: String) {
        dropColorView.alpha = 0
        publishNewEditorStatus()
        if text.isEmpty {
            controlPanel.close()
        }
    }
}
