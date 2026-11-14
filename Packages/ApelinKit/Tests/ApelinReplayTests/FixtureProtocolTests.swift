import ApelinCore
import ApelinProtocol
import ApelinReplay
import Foundation
import XCTest

/// The replay fixtures stay in step with the protocol: every reply and
/// every task start reads as its operation's request and response types,
/// every event as a `TaskEvent` whose payload has its kind's shape, the
/// events of a task are numbered from 1 with no gap and end in a final
/// `state`, and nothing in them names the device or the Mac that made them.
///
/// "Reads as" is strict: a value is decoded, written back, and every field
/// it had must still be there with the same value — a field the type does
/// not know, or one renamed, fails. Where ApelinProtocol has a type for an
/// event payload (`BuildArtifact`, `ProjectDiagnostic`, `InstallResult`,
/// `ConfirmLoadedResponse`) it is read the same way; the other payloads are
/// written by hand in their producers as JSON, and `Self.shapes` holds what
/// those write (AGENTS.md ▸ Decisions lists them).
final class FixtureProtocolTests: XCTestCase {
    /// Recordings whose task was still open when the capture ended, and why.
    private static let stillOpen: [String: String] = [
        "d1-pty": "the run read the terminal once and closed it; its exit was never read",
    ]

    private func fixtures() throws -> ReplayFixtures {
        let fixtures = try ReplayFixtures.bundled()
        XCTAssertFalse(fixtures.replies.isEmpty, "no replies in the replay fixtures")
        XCTAssertFalse(fixtures.tasks.isEmpty, "no tasks in the replay fixtures")
        return fixtures
    }

    func testRepliesReadAsTheirOperation() throws {
        for reply in try fixtures().replies {
            let place = "replies.json \(reply.operation.rawValue) (\(reply.source))"
            XCTAssertFalse(reply.operation.requestType is any TaskAttachRequest.Type, "\(place): an attach is a task's, not a reply")
            XCTAssertTrue((reply.response == nil) != (reply.error == nil), "\(place): a reply is a response or an error")
            Self.check(reply.operation.requestType, request: reply.request, response: reply.response, place: place)
        }
    }

    func testTasksStartAsRecorded() throws {
        for task in try fixtures().tasks {
            let place = "tasks/\(task.name).json"
            let start = task.start
            Self.check(start.operation.requestType, request: start.request, response: start.response, place: place)
            let handle = start.response["task"] ?? start.response
            let id = handle["taskID"]?.stringValue
            XCTAssertEqual(id, task.taskID.rawValue, "\(place): the start answered another task")
            if let kind = handle["kind"]?.stringValue {
                XCTAssertEqual(kind, task.kind.rawValue, "\(place): the start answered another kind")
            } else {
                XCTAssertEqual(start.operation, .logStream, "\(place): only a log stream opens with a batch")
            }
            if start.operation.requestType is any TaskAttachRequest.Type {
                XCTAssertEqual(start.operation, task.kind.attachOperation, "\(place): opened by another kind's attach")
            }
        }
    }

    func testEventsAreNumberedWithoutGapsAndEndInState() throws {
        for task in try fixtures().tasks {
            let place = "tasks/\(task.name).json"
            XCTAssertEqual(task.events.map(\.seq.rawValue), Array(1 ... UInt64(task.events.count)), "\(place): seq must run from 1 with no gap")
            let terminal = task.events.indices.filter { Self.state(of: task.events[$0])?.isTerminal == true }
            if task.state.isTerminal {
                XCTAssertNil(Self.stillOpen[task.name], "\(place) ended; take it out of stillOpen")
                XCTAssertEqual(terminal, [task.events.count - 1], "\(place): exactly the last event is a final state")
                XCTAssertEqual(task.events.last.flatMap(Self.state(of:)), task.state, "\(place): the last event is not its state")
            } else {
                XCTAssertNotNil(Self.stillOpen[task.name], "\(place) never ends; capture it to its end or say why in stillOpen")
                XCTAssertTrue(terminal.isEmpty, "\(place) is \(task.state.rawValue) but has a final state event")
            }
        }
    }

    func testEventPayloadsHaveTheirKindsShape() throws {
        for task in try fixtures().tasks {
            for event in task.events {
                let place = "tasks/\(task.name).json seq \(event.seq) (\(event.kind))"
                guard let shape = Self.shapes[task.kind]?[event.kind] ?? (event.kind == TaskEvent.stateKind ? Self.state([:]) : nil)
                else {
                    XCTFail("\(place): no \(task.kind.rawValue) task has a \(event.kind) event")
                    continue
                }
                for problem in shape.problems(event.payload) {
                    XCTFail("\(place): \(problem)")
                }
                if task.kind == .terminal, event.kind == "output",
                   let encoded = event.payload?["base64"]?.stringValue, let text = event.payload?["text"]?.stringValue
                {
                    XCTAssertEqual(Data(base64Encoded: encoded), Data(text.utf8), "\(place): base64 and text disagree")
                }
            }
        }
    }

    func testEveryEventReadsAsATaskEvent() throws {
        let folder = try XCTUnwrap(ReplayFixtures.bundledDirectory).appendingPathComponent("tasks")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".json") {
            let raw = try JSONCoding.decode(JSONValue.self, from: Data(contentsOf: folder.appendingPathComponent(name)))
            guard case let .array(events)? = raw["events"] else {
                XCTFail("tasks/\(name) has no events")
                continue
            }
            for (index, event) in events.enumerated() {
                if let problem = Self.problem(reading: event, as: TaskEvent.self) {
                    XCTFail("tasks/\(name) event \(index): \(problem)")
                }
            }
            XCTAssertEqual(Set(raw.objectKeys), ["name", "source", "taskID", "kind", "start", "state", "events"], "tasks/\(name)")
        }
    }

    /// The device and the Mac the capture was made on stay out: the same
    /// list make-replay-fixtures.py refuses to write.
    func testNothingNamesTheDeviceOrTheMac() throws {
        let forbidden: [(String, String)] = [
            ("an API key", #"sk-[A-Za-z0-9]{8}|(?i:bearer)\s+[A-Za-z0-9._-]{12}"#),
            ("a bootstrap folder name", #"\.jbroot-(?!0+\b)[0-9A-Fa-f]+"#),
            ("a Mac path", #"/Users/|/private/tmp/|/var/folders/|\bclaude-\d"#),
            ("a model identifier", #"\b(?:iPhone|iPad|iPod|Watch|AppleTV|RealityDevice)(?!0,0\b)\d+,\d+"#),
            ("a kernel build", #"xnu-(?!00000\.000\.000~0)\d|RELEASE_ARM64_(?!DEVICE\b)\w|VRESEARCH"#),
            ("a hostname", #"\bDarwin (?!device )\S+ \d+\.\d+[.\d]* Darwin Kernel|\\u001b\[\?2004h(?!device:)[^\s:\\]+:"#),
            ("an IPv4 address", #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#),
            ("a MAC address", #"\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b"#),
            ("a device identifier", #"\b[0-9A-F]{8}-[0-9A-F]{16}\b|\b[0-9a-f]{40}\b|(?i:\becid\b|\bserial ?number\b)"#),
            ("an e-mail address", #"[\w.+-]+@[\w-]+\.[A-Za-z]{2,}"#),
        ]
        let root = try XCTUnwrap(ReplayFixtures.bundledDirectory)
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path)).compactMap { $0 as? String }.filter { $0.hasSuffix(".json") }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            for (what, pattern) in forbidden {
                let expression = try NSRegularExpression(pattern: pattern)
                let found = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                XCTAssertFalse(found, "\(file) contains \(what)")
            }
        }
    }

    // MARK: - Reading strictly

    private static func check(_ type: any OperationRequest.Type, request: JSONValue, response: JSONValue?, place: String) {
        if let problem = problems(type, request: request, response: response) {
            XCTFail("\(place): \(problem)")
        }
    }

    private static func problems<R: OperationRequest>(_: R.Type, request: JSONValue, response: JSONValue?) -> String? {
        if let problem = problem(reading: request, as: R.self) {
            return "request: \(problem)"
        }
        if let response, let problem = problem(reading: response, as: R.Response.self) {
            return "response: \(problem)"
        }
        return nil
    }

    /// nil when `value` decodes as `T` and every field survives writing it back.
    static func problem<T: Codable>(reading value: JSONValue, as _: T.Type) -> String? {
        do {
            let back = try JSONValue(encoding: value.decode(T.self))
            return missing(value, in: back, path: "\(T.self)")
        } catch {
            return "does not decode as \(T.self): \(error)"
        }
    }

    private static func missing(_ original: JSONValue, in back: JSONValue, path: String) -> String? {
        switch (original, back) {
        case let (.object(fields), .object(kept)):
            for key in fields.keys.sorted() {
                guard let value = kept[key] else { return "\(path).\(key) is not a field of the type" }
                if let problem = missing(fields[key]!, in: value, path: "\(path).\(key)") {
                    return problem
                }
            }
            return nil
        case let (.array(items), .array(kept)):
            guard items.count == kept.count else { return "\(path) has \(items.count) items, \(kept.count) read back" }
            for (index, item) in items.enumerated() {
                if let problem = missing(item, in: kept[index], path: "\(path).\(index)") {
                    return problem
                }
            }
            return nil
        default:
            return original == back ? nil : "\(path) reads back as \(back), was \(original)"
        }
    }

    private static func state(of event: TaskEvent) -> TaskState? {
        guard event.kind == TaskEvent.stateKind else { return nil }
        return event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))
    }

    // MARK: - Payload shapes

    enum Field {
        case string
        case number
        case bool
        case object
        case array
        case word((String) -> Bool)
        case typed((JSONValue) -> String?)

        static func typed<T: Codable>(_: T.Type) -> Field {
            .typed { FixtureProtocolTests.problem(reading: $0, as: T.self) }
        }

        static func words(_ words: Set<String>) -> Field {
            .word { words.contains($0) }
        }

        func problem(_ value: JSONValue) -> String? {
            switch (self, value) {
            case (.string, .string), (.number, .number), (.bool, .bool), (.object, .object), (.array, .array): nil
            case let (.word(accepts), .string(word)): accepts(word) ? nil : "\(word) is not one of its values"
            case let (.typed(read), _): read(value)
            default: "\(value) is not a \(self)"
            }
        }
    }

    struct Shape {
        var required: [String: Field] = [:]
        var optional: [String: Field] = [:]
        /// No payload at all (`messageStarted`).
        var empty = false
        /// The whole payload is this type.
        var type: Field?

        func problems(_ payload: JSONValue?) -> [String] {
            if empty {
                return payload == nil ? [] : ["carries a payload; it has none"]
            }
            guard let payload else { return ["has no payload"] }
            if let type {
                return type.problem(payload).map { [$0] } ?? []
            }
            guard case let .object(fields) = payload else { return ["the payload is not an object"] }
            var problems: [String] = []
            for (key, field) in required.sorted(by: { $0.key < $1.key }) {
                guard let value = fields[key] else {
                    problems.append("\(key) is missing")
                    continue
                }
                if let problem = field.problem(value) {
                    problems.append("\(key): \(problem)")
                }
            }
            for key in fields.keys.sorted() where required[key] == nil {
                guard let field = optional[key] else {
                    problems.append("\(key) is not a field of this event")
                    continue
                }
                if let problem = field.problem(fields[key]!) {
                    problems.append("\(key): \(problem)")
                }
            }
            return problems
        }
    }

    private static func fields(_ names: String..., as field: Field) -> [String: Field] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, field) })
    }

    /// Every task's `state` {state, message?}, with what its kind adds.
    private static func state(_ extra: [String: Field]) -> Shape {
        Shape(required: ["state": .word { TaskState(rawValue: $0) != nil }], optional: extra.merging(["message": .string]) { a, _ in a })
    }

    private static let text = Shape(required: ["text": .string])

    /// What each producer writes, per task kind and event kind.
    static let shapes: [TaskKind: [String: Shape]] = [
        // ApelinAgentWorker ▸ AgentWorker.events(for:waiting:).
        .agent: [
            "prompt": text, "steer": text, "text": text, "thinking": text, "message": text,
            "messageStarted": Shape(empty: true),
            "toolCall": Shape(required: fields("id", "tool", "arguments", as: .string)),
            "toolResult": Shape(required: fields("id", "tool", "output", as: .string).merging(["isError": .bool]) { a, _ in a }),
            "approvalRequested": Shape(
                required: fields("approvalID", "toolCallID", "tool", "arguments", "workingDirectory", "projectID", "fingerprint", "reason", as: .string)
                    .merging(["allowsSessionScope": .bool]) { a, _ in a },
                optional: ["detail": .object],
            ),
            "approvalResolved": Shape(required: ["approvalID": .string, "decision": .word { ApprovalDecision(rawValue: $0) != nil }]),
            "error": Shape(required: ["message": .string], optional: ["reason": .string]),
            "finished": Shape(required: ["reason": .words(["completed", "aborted", "failed"])]),
            "state": state([:]),
        ],
        // ApelinAgentWorker ▸ SignIn/AccountDesk.swift: what the user must see
        // or open, and the fields of a key; never a secret.
        .signIn: [
            "deviceCode": Shape(required: ["code": .string, "verificationURL": .string, "pageHoldsCode": .bool]),
            "authorize": Shape(required: ["url": .string, "acceptsCallbackURL": .bool]),
            "input": Shape(required: ["fields": .array]),
            "state": state([:]),
        ],
        // ApelinBuild ▸ the build worker; artifact and diagnostic are protocol types.
        .build: [
            "stage": Shape(required: ["stage": .string], optional: ["product": .string, "resumes": .number]),
            "resumed": Shape(required: ["resumes": .number]),
            "log": Shape(required: ["line": .string]),
            "diagnostic": Shape(type: .typed(ProjectDiagnostic.self)),
            "artifact": Shape(type: .typed(BuildArtifact.self)),
            "state": state(fields("artifactID", "digest", "buildID", "packageID", "version", "bootstrap", as: .string)),
        ],
        // Apelind ▸ Session/Install/InstallBridge.swift.
        .install: [
            "stage": Shape(
                required: ["stage": .string],
                optional: fields("digest", "installationID", "packageID", "transactionID", "version", as: .string)
                    .merging(["duplicate": .bool]) { a, _ in a },
            ),
            "irisin": Shape(
                required: ["seq": .number, "kind": .string, "text": .string],
                optional: fields("phase", "step", "package", "version", "problem", as: .string)
                    .merging(fields("done", "total", "exit", as: .number)) { a, _ in a },
            ),
            "result": Shape(type: .typed(InstallResult.self)),
            "conflict": Shape(type: .typed(InstallConflict.self)),
            "state": state(["result": .typed(InstallResult.self)]),
        ],
        // Apelind ▸ Session/Terminal/TerminalHost.swift.
        .terminal: [
            "started": Shape(required: ["pid": .number, "shell": .string, "cwd": .string], optional: fields("uid", "gid", as: .number)),
            "output": Shape(required: ["base64": .string], optional: ["text": .string]),
            "exit": Shape(optional: fields("status", "signal", as: .number)),
            "state": state([:]),
        ],
        // ApelinDiagnostics ▸ the log readers' pump.
        .logStream: [
            "log": Shape(
                required: fields("time", "process", "subsystem", "category", "level", "message", as: .string)
                    .merging(["pid": .number]) { a, _ in a },
            ),
            "truncated": Shape(required: ["limit": .number], optional: ["reason": .string]),
            "state": state([:]),
        ],
        // ApelinDiagnosticsWorker ▸ the load check.
        .confirmLoaded: [
            "stage": Shape(
                required: ["stage": .string],
                optional: fields("marker", "process", "trigger", as: .string).merging(["windowSeconds": .number]) { a, _ in a },
            ),
            "state": state([ConfirmLoadedResponse.stateMember: .typed(ConfirmLoadedResponse.self)]),
        ],
    ]
}

private extension JSONValue {
    var objectKeys: [String] {
        if case let .object(fields) = self {
            return Array(fields.keys)
        }
        return []
    }
}
