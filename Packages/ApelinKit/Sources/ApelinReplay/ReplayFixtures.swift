import ApelinCore
import ApelinProtocol
import Foundation

/// What a device answered, captured by the console and cleaned of anything
/// that names the device (Documents/Console/demo/make-replay-fixtures.py):
/// the plain replies, and every task with the request that started it and
/// all of its events. `ReplayTransport` answers from it.
///
/// On disk, a folder holding `replies.json` (an array of `Reply`) and
/// `tasks/<name>.json` (one `TaskRecording` each). The copy in this package
/// is `ReplayFixtures.bundled()`.
public struct ReplayFixtures: Sendable {
    /// One operation's answer, as a script asked it.
    public struct Reply: Codable, Sendable, Equatable {
        public var operation: AppOperation
        /// The request, `${…}` references filled in as the run filled them.
        public var request: JSONValue
        public var response: JSONValue?
        public var error: ApelinError?
        /// The script and step that asked it.
        public var source: String
    }

    /// The step that started a task, and what it answered: a `TaskHandle`,
    /// or a response carrying one as `task` (`agentOpen`, `ptyOpen`), or for
    /// a log stream its opening batch.
    public struct TaskStart: Codable, Sendable, Equatable {
        public var operation: AppOperation
        public var request: JSONValue
        public var response: JSONValue
    }

    /// One task, every event numbered from 1 with no gap.
    public struct TaskRecording: Codable, Sendable, Equatable {
        /// `<script prefix>-<label of the step that started it>`: `d1-tweak-build`.
        public var name: String
        public var source: String
        public var taskID: TaskID
        public var kind: TaskKind
        public var start: TaskStart
        /// The state the capture last saw: the final `state` event's, or a
        /// task still open when the run ended (a terminal never closed).
        public var state: TaskState
        public var events: [TaskEvent]

        /// The session an agent or terminal task belongs to, from its start.
        public var sessionID: String? {
            start.response["sessionID"]?.stringValue
        }
    }

    public var replies: [Reply]
    public var tasks: [TaskRecording]

    public init(replies: [Reply], tasks: [TaskRecording]) {
        self.replies = replies
        self.tasks = tasks
    }

    /// Reads a fixtures folder: `replies.json` and `tasks/*.json`, in name order.
    public init(directory: URL) throws {
        let replies = try JSONCoding.decode(
            [Reply].self,
            from: Data(contentsOf: directory.appendingPathComponent("replies.json")),
        )
        let taskFolder = directory.appendingPathComponent("tasks", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: taskFolder.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        let tasks = try names.map { name in
            do {
                // persisted-read: a test fixture, which must read whole
                return try JSONCoding.decode(
                    TaskRecording.self,
                    from: Data(contentsOf: taskFolder.appendingPathComponent(name)),
                )
            } catch {
                throw ApelinError(.internal, "replay fixture tasks/\(name) does not decode: \(error)")
            }
        }
        self.init(replies: replies, tasks: tasks)
    }

    /// The folder this package carries.
    public static var bundledDirectory: URL? {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)
    }

    /// The fixtures this package carries.
    public static func bundled() throws -> ReplayFixtures {
        guard let directory = bundledDirectory else {
            throw ApelinError(.internal, "the replay fixtures are missing from the ApelinReplay bundle")
        }
        return try ReplayFixtures(directory: directory)
    }

    public func task(named name: String) -> TaskRecording? {
        tasks.first { $0.name == name }
    }
}
