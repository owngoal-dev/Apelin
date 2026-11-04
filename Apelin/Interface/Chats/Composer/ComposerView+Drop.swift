// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// Files, images and text dropped on the card, tinted while a drag is over
/// it. The delegate imports them as it imports a pick from Files.
extension ComposerView: UIDropInteractionDelegate {
    @objc dynamic func dropInteraction(_: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        ComposerDropPolicy.accepts(
            session.items.map(\.itemProvider),
            fromThisApp: session.localDragSession != nil,
            inputCovered: approvalSection.isPresentingRequest,
        )
    }

    @objc dynamic func dropInteraction(_: UIDropInteraction, sessionDidUpdate _: UIDropSession) -> UIDropProposal {
        // `canHandle` is asked once; a request can take the input's place
        // while the drag is still over it
        guard !approvalSection.isPresentingRequest else {
            dropColorView.alpha = 0
            return .init(operation: .forbidden)
        }
        return .init(operation: .copy)
    }

    @objc dynamic func dropInteraction(_: UIDropInteraction, sessionDidEnter _: UIDropSession) {
        UIView.animate(withDuration: 0.25) { self.dropColorView.alpha = 1 }
    }

    @objc dynamic func dropInteraction(_: UIDropInteraction, sessionDidExit _: any UIDropSession) {
        UIView.animate(withDuration: 0.25) { self.dropColorView.alpha = 0 }
    }

    @objc dynamic func dropInteraction(_: UIDropInteraction, sessionDidEnd _: UIDropSession) {
        UIView.animate(withDuration: 0.25) { self.dropColorView.alpha = 0 }
    }

    @objc dynamic func dropInteraction(_: UIDropInteraction, performDrop session: any UIDropSession) {
        UIView.animate(withDuration: 0.25) { self.dropColorView.alpha = 0 }
        delegate?.onComposerDropped(session.items.map(\.itemProvider))
    }
}
