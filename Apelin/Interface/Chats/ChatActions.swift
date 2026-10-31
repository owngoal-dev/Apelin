import AlertController
import ApelinProtocol
import SPIndicator
import UIKit

/// The chat page's `…` menu: Rename… and Compact… for the conversation,
/// then its project's actions (`ProjectActions`). General Chat has no
/// project, so after them come Open in iGhostVT and Open in Fila for the
/// conversation's own working folder, `Temporary/<conversation>/`. Last,
/// in a group of its own, Delete Conversation…, which `onDelete` asks
/// about and carries out as the sidebar's Delete does (`ChatDeletion`).
@MainActor
enum ChatActions {
    static func menu(
        for chat: ChatSummary,
        runtime: ChatRuntime,
        from presenter: UIViewController,
        anchor: UIBarButtonItem,
        onPrepareDistribution: @escaping (String) -> Void,
        onDelete: @escaping (UUID) -> Void,
        completion: @escaping ([UIMenuElement]) -> Void,
    ) {
        let chatActions = [
            renameAction(for: chat.id, runtime: runtime, from: presenter),
            compactAction(for: chat.id, runtime: runtime, from: presenter),
        ]
        let deletion = UIMenu(options: .displayInline, children: [deleteAction(for: chat.id, onDelete: onDelete)])
        guard let projectName = chat.projectName else {
            let folders = ProjectActions.folderActions(from: presenter, failureTitle: "Unable to Open Folder") {
                try ProjectActions.temporaryDirectory(of: chat.id)
            }
            completion([
                UIMenu(options: .displayInline, children: chatActions),
                UIMenu(options: .displayInline, children: folders),
                deletion,
            ])
            return
        }
        // Distribute… is read off the project's own manifest each time: one
        // with no build description or script has nothing to package
        Task { [weak presenter, weak anchor] in
            let project = try? await ProjectSummary.load().first { $0.name == projectName }
            guard let presenter, let anchor else {
                completion([])
                return
            }
            let projectActions = ProjectActions.menu(
                projectName: projectName,
                from: presenter,
                anchor: anchor,
                distributionBlocker: (project?.buildMethod ?? .missingDescription).shortBlocker,
                chatActions: chatActions,
                onPrepareDistribution: onPrepareDistribution,
            )
            completion(projectActions.children + [deletion])
        }
    }

    /// Asked about first, whatever state the conversation is in when it is
    /// picked: one still working is stopped before it goes.
    private static func deleteAction(for id: UUID, onDelete: @escaping (UUID) -> Void) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Delete Conversation…"),
            image: UIImage(systemName: "trash"),
            attributes: .destructive,
        ) { _ in onDelete(id) }
    }

    /// The conversation's name, typed into the alert Rename Project… uses.
    /// It is kept for good: the agent's titles no longer replace it
    /// (`ChatRuntime.rename`).
    private static func renameAction(
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Rename…"),
            image: UIImage(systemName: "character.cursor.ibeam"),
        ) { [weak presenter, weak runtime] _ in
            guard let presenter, let runtime, let chat = runtime.records[id]?.summary else { return }
            presenter.present(AlertInputViewController(
                title: "Rename Chat",
                message: "Choose a name for this chat. Your agent will no longer rename it.",
                placeholder: "Chat Name",
                text: chat.displayTitle,
                doneButtonText: "Rename",
                onConfirm: { [weak runtime] name in runtime?.rename(id, to: name) },
            ), animated: true)
        }
    }

    /// The agent reads a summary of the earlier messages from then on; the
    /// chat still shows them all. Only between runs (`ChatRuntime.canCompact`).
    private static func compactAction(
        for id: UUID,
        runtime: ChatRuntime,
        from presenter: UIViewController,
    ) -> UIKit.UIAction {
        UIKit.UIAction(
            title: String(localized: "Compact Context…"),
            image: UIImage(systemName: "doc.text"),
            attributes: runtime.canCompact(id) ? [] : .disabled,
        ) { [weak presenter, weak runtime] _ in
            guard let presenter else { return }
            presenter.presentConfirmation(
                title: "Compact Context?",
                message: """
                Your agent will continue from a summary of the earlier messages, which frees room for new work. \
                The messages stay in this chat.
                """,
                confirmTitle: "Compact Context",
            ) { [weak presenter, weak runtime] in
                guard let presenter, let runtime else { return }
                Task { await compact(id, runtime: runtime, from: presenter) }
            }
        }
    }

    private static func compact(_ id: UUID, runtime: ChatRuntime, from presenter: UIViewController) async {
        let result: AgentCompactionResult
        do {
            result = try await ProgressCard.run(
                title: String(localized: "Compacting Chat"),
                message: String(localized: "Summarizing the earlier messages…"),
                cancellable: true,
                from: presenter,
            ) { _ in try await runtime.compact(id) }
        } catch is CancellationError {
            return
        } catch {
            ConversationJournal.compactFailed(error, session: runtime.records[id]?.sessionID)
            presenter.presentNotice(title: "Unable to Compact Chat", message: error.readableMessage)
            return
        }
        switch result.outcome {
        case .compacted:
            SPIndicator.present(title: String(localized: "Compacted"), preset: .done, haptic: .success)
        case .tooShort:
            presenter.presentNotice(
                title: "Nothing to Compact",
                message: "This chat is still short enough for your agent to read in full.",
            )
        case .failed:
            presenter.presentNotice(
                title: "Unable to Compact Chat",
                message: result.message ?? String(localized: "Something went wrong. Try again."),
            )
        case .cancelled:
            break
        }
    }
}
