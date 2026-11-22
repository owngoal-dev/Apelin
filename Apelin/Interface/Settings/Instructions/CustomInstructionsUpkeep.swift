import ApelinCore
import Foundation

/// A deleted project's custom instructions go with it, as its conversations
/// do (`DeletedProjects`): whenever the app reads `Projects/` again — at
/// launch and on each change the catalog monitor reports, the app's own
/// Delete included — the instructions of every project no folder names any
/// more are removed (`CustomInstructionsStore.removeGoneProjects`), off the
/// main thread. The agent's Delete removes them itself (`ProjectDeletion`);
/// this takes those a command or another app left behind.
enum CustomInstructionsUpkeep {
    static func removeGoneProjects() {
        let store = CustomInstructionsStore(root: DataFolder.app.root)
        Task.detached(priority: .utility) { store.removeGoneProjects() }
    }
}
