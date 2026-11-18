import ApelinCore
import Darwin
import notify
import Foundation

/// Apelin's activity on the reader's Discord profile, through Menzen's API
/// (Menzen's `docs/API.md`): what the agent of the conversation that most
/// needs a look is doing, in which project, for how long.
///
/// Menzen is optional, so its library is loaded at run time and its classes
/// looked up by name; without it this does nothing. The client lives as long
/// as the session host, so the activity clears when the host exits idle. The
/// reader turns it on in Menzen's settings (Connected Apps) and picks what
/// shows in Apelin's (`MenzenStatusOptions`).
actor MenzenStatus {
    /// What Menzen's settings list Apelin as.
    static let identifier = "wiki.qaq.apelin"
    static let name = "Apelin"
    /// Apelin's icon among the art of Menzen's Discord application.
    static let imageURL = URL(string: "https://cdn.discordapp.com/app-assets/1564329461036617748/1566639708623085718.png")
    /// An agent that stopped writing without finishing was stopped some
    /// other way; one waiting for an approval waits as long as it takes.
    static let staleAge: TimeInterval = 10 * 60

    private struct Session {
        var project: String?
        var headless: Bool
        /// Nil while the agent is idle.
        var activity: String?
        var waiting = false
        /// When this run of the agent began.
        var since = Date()
        var updated = Date()
    }

    /// What one publish shows; nothing is sent again while it holds.
    private struct Shown: Equatable {
        var project: String?
        var activity: String?
        var since: Date?
    }

    private let library: String
    private let folder: DataFolder
    private var sessions: [String: Session] = [:]
    private var client: NSObject?
    private var loaded = false
    private var options: MenzenStatusOptions
    private var shown: Shown?
    private var check: Task<Void, Never>?

    /// `installRoot`: the bootstrap root Menzen's package installs into.
    init(installRoot: String, folder: DataFolder) {
        library = installRoot + "/usr/lib/libmenzen.dylib"
        self.folder = folder
        options = MenzenStatusOptions.read(from: folder)
    }

    /// Follows the app's changes to the options.
    func start() {
        var token: Int32 = 0
        notify_register_dispatch(MenzenStatusOptions.changedNotification, &token, .global()) { [weak self] _ in
            Task { await self?.optionsChanged() }
        }
    }

    /// An agent session's task, before its worker hears of it.
    func opened(session: String, project: ResolvedProject, headless: Bool) {
        let name = project.isTemporary ? nil : Self.displayName(project)
        sessions[session] = Session(project: name, headless: headless)
    }

    /// One event the host relayed into an agent session's task, in order.
    func relayed(session: String, kind: String, payload: JSONValue?) {
        guard var entry = sessions[session], !entry.headless,
              let next = MenzenAgentActivity.after(kind, payload: payload)
        else { return }
        let now = Date()
        if entry.activity == nil, next != nil {
            entry.since = now
        }
        entry.activity = next
        entry.waiting = kind == "approvalRequested"
        entry.updated = now
        sessions[session] = entry
        publish()
    }

    /// The session's worker exited: its agent is idle until it opens again.
    func exited(session: String?) {
        guard let session, sessions[session]?.activity != nil else { return }
        sessions[session]?.activity = nil
        sessions[session]?.waiting = false
        publish()
    }

    private func optionsChanged() {
        options = MenzenStatusOptions.read(from: folder)
        publish()
    }

    /// Waiting for an approval first, then working; among those the one the
    /// agent wrote last. Nothing when every agent is idle.
    private func current() -> Session? {
        let now = Date()
        let live = sessions.values.filter { entry in
            entry.activity != nil && (entry.waiting || now.timeIntervalSince(entry.updated) < Self.staleAge)
        }
        return live.max { ($0.waiting ? 1 : 0, $0.updated) < ($1.waiting ? 1 : 0, $1.updated) }
    }

    private func publish() {
        let entry = current()
        let next = entry.map { entry in
            Shown(
                project: options.showsProject ? entry.project : nil,
                activity: options.showsActivity ? entry.activity : nil,
                since: options.showsElapsedTime ? entry.since : nil,
            )
        }
        scheduleCheck(working: entry != nil)
        guard next != shown, let client = connect() else { return }
        shown = next
        client.setValue(next.flatMap(Self.activity), forKey: "activity")
    }

    /// While an agent works, look again now and then: one that stops writing
    /// goes stale without another event to say so.
    private func scheduleCheck(working: Bool) {
        guard working else {
            check?.cancel()
            check = nil
            return
        }
        guard check == nil else { return }
        check = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await self?.checked()
        }
    }

    private func checked() {
        check = nil
        publish()
    }

    private static func activity(_ shown: Shown) -> NSObject? {
        guard let type = NSClassFromString("MenzenClientActivity") as? NSObject.Type else { return nil }
        let activity = type.init()
        activity.setValue(shown.project, forKey: "details")
        activity.setValue(shown.activity, forKey: "state")
        activity.setValue(imageURL, forKey: "largeImageURL")
        activity.setValue(name, forKey: "largeText")
        activity.setValue(shown.since, forKey: "startDate")
        return activity
    }

    /// The client, made the first time something shows. Menzen's library is
    /// loaded only from where its package put it: root's, and writable by no
    /// one else.
    private func connect() -> NSObject? {
        if loaded {
            return client
        }
        loaded = true
        var metadata = stat()
        guard let path = CanonicalPath.resolve(library), lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == 0,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0,
              dlopen(path, RTLD_NOW) != nil,
              let type = NSClassFromString("MenzenClient"),
              class_addProtocol(type, MenzenClientMaking.self) || class_conformsToProtocol(type, MenzenClientMaking.self),
              let making = type as? MenzenClientMaking.Type
        else { return nil }
        client = making.init(identifier: Self.identifier, name: Self.name) as? NSObject
        return client
    }

    /// The name the sidebar shows: the manifest's `displayName`, else the
    /// folder's.
    private static func displayName(_ project: ResolvedProject) -> String {
        let manifest = try? AgentProjects.readManifest(project.path + "/apelin-project.json")
        let name = manifest?["displayName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 } ?? project.name
    }
}

/// Menzen's `-[MenzenClient initWithIdentifier:name:]`, declared here since
/// the class is only known at run time.
@objc private protocol MenzenClientMaking: NSObjectProtocol {
    init?(identifier: String, name: String)
}

/// What an agent is doing, as its task events tell it. The words are the
/// status line Discord shows, so they stay short.
enum MenzenAgentActivity {
    /// Nil for an event that says nothing new (token counts, titles); `.some(nil)`
    /// for one after which the agent is idle.
    static func after(_ kind: String, payload: JSONValue?) -> String?? {
        switch kind {
        case "finished", "messageDiscarded", "queueDropped":
            .some(nil)
        case "prompt", "steer", "messageStarted", "thinking", "message", "toolResult", "approvalResolved",
             "compactionFinished":
            "Thinking"
        case "text":
            "Responding"
        case "toolCallPreparing":
            "Running tools"
        case "toolCall":
            tool(payload?["tool"]?.stringValue)
        case "approvalRequested":
            "Waiting for approval"
        case "compactionStarted":
            "Compacting"
        case "reconnecting":
            "Reconnecting"
        default:
            nil
        }
    }

    private static func tool(_ name: String?) -> String {
        switch name {
        case "apelin_project_build": "Building"
        case "apelin_package_install": "Installing a package"
        case "apelin_package_publish": "Packaging"
        case "apelin_package_remove": "Removing a package"
        case "apelin_device_respring": "Respringing"
        case "file_edit", "file_write": "Editing files"
        case "file_read": "Reading files"
        case "git_clone": "Cloning a repository"
        default: "Running tools"
        }
    }
}
