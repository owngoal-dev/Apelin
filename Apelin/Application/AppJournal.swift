import ApelinCore
import Dog
import UIKit

/// Dog's journal, `~/Documents/wiki.qaq.apelin/Journal/Dog_<date>_<id>.log`:
/// one file a launch, the 100 newest kept, every line mirrored to the
/// unified log under `com.lakr233.dog`. The app's alone — apelind and the
/// workers keep their own logging — and read back by Settings ▸ Logs.
enum AppJournal {
    static var directory: URL {
        DataFolder.app.root.appendingPathComponent("Journal", isDirectory: true)
    }

    /// `Journal/Agent/`: the journal each conversation's agent writes
    /// (apelin-agent's `SessionJournal`), which Settings ▸ Logs lists too.
    static var agentDirectory: URL {
        directory.appendingPathComponent("Agent", isDirectory: true)
    }

    /// What the app's lines never name: credentials, e-mail addresses,
    /// mobile's home, on roothide the install root, network names and
    /// device identifiers, the device's own name (`LogRedaction`). A
    /// journal is shared to report a problem.
    static let redaction = LogRedaction(
        home: DataFolder.app.root.deletingLastPathComponent().deletingLastPathComponent().path,
        installRoot: RoothideRoot.containing(Bundle.main.bundlePath),
        names: PrivateShapes.currentHostName().map { [$0] } ?? [],
    )

    /// Opens this launch's file, once, early in `didFinishLaunching`. In
    /// the data folder the package made, `DataFolder.app`: Dog's default is
    /// `.documentDirectory`, the app's own home's — mobile's shared
    /// `~/Documents` with no container, the data container's on rootless —
    /// and `NSHomeDirectory()` on roothide is the system's `/var/mobile`,
    /// not the bootstrap's.
    @MainActor
    static func start() {
        let folder = DataFolder.app
        do {
            try folder.makeLevels(to: directory)
            try Dog.shared.initialization(writableDir: folder.root)
            // Include this launch: Dog's initialization prunes before creating it.
            Dog.shared.maximumLogCount = 100
        } catch {
            NSLog("Apelin: the journal could not be opened: %@", String(describing: error))
            return
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        Dog.shared.join(
            "App",
            """
            Apelin \(version) (\(build)) launched
            System: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
            Location:
                [*] \(redaction.redacted(Bundle.main.bundleURL.path))
                [*] \(redaction.redacted(folder.root.path))
            Environment: uid \(getuid()) gid \(getgid())
            """,
            level: .info,
        )
    }

    /// What this launch moved from the data folder an earlier version kept
    /// in the app's data container (`ContainerDataFolder`), path by path.
    static func note(_ recovery: ContainerDataFolder.Recovery) {
        func list(_ title: String, _ paths: [String]) -> String {
            guard !paths.isEmpty else { return "" }
            let shown = paths.prefix(200).map { "\n    [*] " + redaction.redacted($0) }.joined()
            let more = paths.count > 200 ? "\n    … and \(paths.count - 200) more" : ""
            return "\n\(title) (\(paths.count)):" + shown + more
        }
        let aside = recovery.setAside.map { "renamed \($0)" } ?? "not renamed, so the next launch tries again"
        Dog.shared.join(
            "App",
            "Moved the data folder an earlier version kept in the app's data container; that folder was \(aside)"
                + list("Moved", recovery.moved)
                + list("Newer than mobile's, which was kept aside", recovery.replaced)
                + list("Older than mobile's, kept aside", recovery.kept)
                + list("Left in the container", recovery.left)
                + "\nMemories: \(recovery.memories) added, \(recovery.memoriesLeft) left in the container",
            level: recovery.left.isEmpty && recovery.memoriesLeft == 0 && recovery.setAside != nil ? .info : .warning,
        )
    }
}
