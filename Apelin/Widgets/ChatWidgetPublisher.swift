import ActivityKit
import Foundation
import os
import WidgetKit

/// Mirrors the conversations into the widgets: the snapshot the home screen
/// widget reads from the App Group container, and one Live Activity while
/// any conversation is working or waiting for an approval.
///
/// The runtime says when anything changed; the publisher looks at most once
/// a second, and writes, reloads or updates only when what the widgets show
/// changed — streamed text changes nothing they show. Project display names
/// are read again when a project changes (`.apelinProjectsChanged`).
@MainActor
final class ChatWidgetPublisher {
    static let shared = ChatWidgetPublisher()

    private weak var runtime: ChatRuntime?
    /// Folder name to display name, read from the projects' manifests.
    @objc private dynamic var projectNames: [String: String] = [:]
    @objc private dynamic var isScheduled = false
    @objc private dynamic var lastLook = Date.distantPast
    private var written: ChatWidgetSnapshot?
    private var shownActivity: ChatWidgetSnapshot?
    /// Activity requests and updates, one after another, so two quick
    /// changes never request two activities.
    private var activityWork: Task<Void, Never>?
    /// Set once a quit has ended the activity: a change queued behind the
    /// quit must not bring one back.
    @objc private dynamic static var isClosedForQuit = false
    private let writer = DispatchQueue(label: "wiki.qaq.apelin.widgets.writer", qos: .utility)
    private let log = Logger(subsystem: "wiki.qaq.apelin", category: "widgets")

    /// The most often the widgets are looked at.
    private static let interval: TimeInterval = 1

    private init() {
        NotificationCenter.default.addObserver(
            forName: .apelinProjectsChanged,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { ChatWidgetPublisher.shared.reloadProjectNames() }
        }
    }

    /// Starts mirroring `runtime`, the window's.
    func attach(_ runtime: ChatRuntime) {
        self.runtime = runtime
        reloadProjectNames()
        chatsChanged()
    }

    /// Something in the runtime changed: looks again within a second.
    @objc dynamic func chatsChanged() {
        guard !isScheduled else { return }
        isScheduled = true
        let delay = max(0, Self.interval - Date().timeIntervalSince(lastLook))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            isScheduled = false
            lastLook = Date()
            publish()
        }
    }

    @objc private dynamic func reloadProjectNames() {
        Task {
            guard let projects = try? await ProjectSummary.load() else { return }
            let names = Dictionary(projects.map { ($0.name, $0.displayTitle) }) { first, _ in first }
            guard names != projectNames else { return }
            projectNames = names
            chatsChanged()
        }
    }

    /// Nothing is said until the saved conversations are read and checked
    /// against the host's live sessions: an empty list at launch would end
    /// a Live Activity the last run left showing, and a row saved working
    /// would start one for a turn long over.
    @objc private dynamic func publish() {
        guard let runtime, runtime.isReconciled else { return }
        let listed = runtime.records.values.filter(\.isListedInWidgets).map { record in
            let project = record.summary.projectName.map { projectNames[$0] ?? $0 }
            return (chat: record.widgetChat(projectName: project), updated: record.summary.lastInteraction)
        }
        let snapshot = ChatWidgetSnapshot(chats: listed)
        if snapshot != written {
            written = snapshot
            write(snapshot)
        }
        let activity = snapshot.inProgress
        if activity != shownActivity {
            shownActivity = activity
            showActivity(activity)
        }
    }

    private func write(_ snapshot: ChatWidgetSnapshot) {
        writer.async { [log] in
            do {
                guard try ChatWidgetStore.write(snapshot) else {
                    log.error("No App Group container; the widgets show nothing")
                    return
                }
                DispatchQueue.main.async {
                    WidgetCenter.shared.reloadTimelines(ofKind: ChatWidgetStore.widgetKind)
                }
            } catch {
                log.error("Writing the widget snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showActivity(_ state: ChatWidgetSnapshot) {
        guard #available(iOS 16.2, *), !Self.isClosedForQuit else { return }
        let previous = activityWork
        activityWork = Task {
            await previous?.value
            await Self.apply(state)
        }
    }

    /// One activity while anything is in progress, ended the moment nothing
    /// is. An activity the last run left is updated, or ended, by the first
    /// look after launch.
    @available(iOS 16.2, *)
    private static func apply(_ state: ChatWidgetSnapshot) async {
        guard !isClosedForQuit else { return }
        let existing = Activity<ChatActivityAttributes>.activities
        guard state.totalCount > 0 else {
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = existing.first {
            await activity.update(content)
            for extra in existing.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(attributes: ChatActivityAttributes(), content: content)
    }

    /// The app is quitting: nothing will update the activity after this,
    /// and the conversations go on in apelind out of its sight, so it is
    /// ended rather than left showing work that may be long over. The next
    /// launch shows it again if work is still in progress. Blocking,
    /// bounded by `timeout`, because `applicationWillTerminate` is the
    /// caller and anything still queued dies with the process; a suspended
    /// app gets no such call and keeps its activity.
    @objc dynamic static func endActivitiesForQuit(timeout: TimeInterval = 1) {
        isClosedForQuit = true
        guard #available(iOS 16.2, *) else { return }
        let activities = Activity<ChatActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
}
