import ApelinProtocol
import Foundation

/// One setup's stage record (§3.4), kept beside its staging under
/// `Toolchains/jobs/<key>/job.json` until it reaches ready. The key is the
/// source and the components, so a setup asked again after a failure, a
/// cancel or a killed worker picks up the same staging: the backend reuses
/// a verified download and a verified tree, and nothing else is trusted.
/// Its first stage may be `sdk`, an SDK fetched for the self-test; the SDK
/// registry is that stage's record, so a run again finds it registered.
/// `installationID` is the bridge's record of an install this job made and
/// has neither registered nor rolled back, so a worker that stops between
/// irisind's answer and the registry does not lose what removal needs.
public struct ToolchainJob: Codable, Sendable, Equatable {
    public var key: String
    public var productID: String
    public var components: [ToolchainComponentKind]
    public var stage: String
    public var taskID: String
    public var toolchainID: String?
    public var installationID: String?
    /// The host's install task, from `installPackage` answering to its end.
    public var installTaskID: String?
    public var updated: Date
    public var failure: String?
}

/// The latest install one setup made.
final class InstallTracker: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc private dynamic var id: String?

    @objc dynamic func add(_ id: String) {
        lock.withLock { self.id = id }
    }

    @objc dynamic var latest: String? {
        lock.withLock { id }
    }
}

/// The job keys this worker is running: one setup per source and components.
final class RunningJobs: @unchecked Sendable {
    static let shared = RunningJobs()
    private let lock = PthreadLock()
    @objc private dynamic var keys: Set<String> = []

    @objc dynamic func claim(_ key: String) -> Bool {
        lock.withLock { keys.insert(key).inserted }
    }

    @objc(apelin_release:) dynamic func release(_ key: String) {
        _ = lock.withLock { keys.remove(key) }
    }
}

/// The job record, written on every stage change.
final class JobJournal: @unchecked Sendable {
    private let lock = PthreadLock()
    private var job: ToolchainJob
    private let url: URL

    init(job: ToolchainJob, url: URL) {
        self.job = job
        self.url = url
    }

    @objc dynamic var toolchainID: String? {
        get { lock.withLock { job.toolchainID } }
        set { lock.withLock { job.toolchainID = newValue }; save() }
    }

    @objc dynamic var installationID: String? {
        get { lock.withLock { job.installationID } }
        set { lock.withLock { job.installationID = newValue }; save() }
    }

    @objc dynamic var installTaskID: String? {
        get { lock.withLock { job.installTaskID } }
        set { lock.withLock { job.installTaskID = newValue }; save() }
    }

    /// Records `stage`; true when it is a new one.
    @objc dynamic func enter(_ stage: String) -> Bool {
        let changed: Bool = lock.withLock {
            guard job.stage != stage else { return false }
            job.stage = stage
            job.updated = Date()
            return true
        }
        if changed {
            save()
        }
        return changed
    }

    @objc dynamic func fail(_ message: String) {
        lock.withLock { job.failure = message; job.updated = Date() }
        save()
    }

    @objc dynamic func save() {
        let snapshot = lock.withLock { job }
        try? JSONFile.write(snapshot, to: url)
    }
}
