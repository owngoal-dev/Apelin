import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

/// #67: the app's Stop (`agentAbort`) reaches the worker's stop watch. A run
/// that does not answer its cancellation (a model request, a sign-in's
/// renewal, a compaction) still ends: the worker ends its task with an
/// error saying so. With 0.4.7 the app's Stop stopped the session past the
/// watch, which only the host's task cancel reached, so such a run went on
/// working however often Stop was tapped.
@Suite("The app's Stop is timed by the worker", .serialized)
struct StopWatchTests {
    /// A provider whose request ends only when the test lets it, and hears
    /// its cancellation only when `hears` is set.
    final class Provider: APIProvider, @unchecked Sendable {
        let api = "stop-watch-test-\(UUID().uuidString.prefix(8))"
        let hears: Bool
        private let lock = NSLock()
        private var waiting: [(AssistantMessageStream.Continuation, Model)] = []

        init(hears: Bool) {
            self.hears = hears
        }

        var model: Model {
            Model(id: "stop-watch", api: api, provider: api)
        }

        func stream(model: Model, context _: Context, options: StreamOptions?) -> AssistantMessageStream {
            let (stream, out) = AssistantMessageStream.makeStream()
            out.push(.start(partial: Self.message(model, .stop)))
            lock.withLock { waiting.append((out, model)) }
            if hears {
                options?.cancellation?.onCancel { [weak self] _ in self?.release(.aborted) }
            }
            return stream
        }

        /// Ends every request still going.
        func release(_ reason: StopReason = .stop) {
            let waiting = lock.withLock {
                defer { self.waiting = [] }
                return self.waiting
            }
            for (out, model) in waiting {
                out.end(Self.message(model, reason))
            }
        }

        private static func message(_ model: Model, _ reason: StopReason) -> AssistantMessage {
            AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id, stopReason: reason)
        }
    }

    /// What the host heard of the task, in order.
    final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(kind: String, payload: ApelinCore.JSONValue?)] = []

        func add(_ frame: ChannelFrame) {
            guard let kind = frame.header.name else { return }
            let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(ApelinCore.JSONValue.self, from: frame.body)
            lock.withLock { events.append((kind, payload)) }
        }

        var kinds: [String] {
            lock.withLock { events.map(\.kind) }
        }

        func payloads(_ kind: String) -> [ApelinCore.JSONValue?] {
            lock.withLock { events.filter { $0.kind == kind }.map(\.payload) }
        }

        /// Waits until `kind` is heard, for `limit` at most.
        func wait(for kind: String, within limit: Duration) async -> Bool {
            let deadline = ContinuousClock.now + limit
            while ContinuousClock.now < deadline {
                if kinds.contains(kind) {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }

    final class Exited: @unchecked Sendable {
        private let lock = NSLock()
        private var exited = false

        func set() {
            lock.withLock { exited = true }
        }

        var value: Bool {
            lock.withLock { exited }
        }
    }

    struct Worker {
        let state: WorkerState
        let session: AgentSession
        let host: ApelinService
        let heard: Heard
        let exited: Exited
        let close: @Sendable () -> Void
    }

    /// A worker serving one session over a real channel, its host on the
    /// other end hearing the task's events.
    static func worker(_ provider: Provider, home: URL) async throws -> Worker {
        await APIRegistry.shared.register(provider, scope: provider.api)
        let project = try ApelinAgent.ProjectIdentity(id: "6f1c5b0e-0000-4000-8000-000000000002", name: ApelinAgent.ProjectName("Hello"))
        let dataRoot = ApelinDataRoot(home: home)
        let projectURL = dataRoot.project(named: project.name)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let facade = ApelinService(transport: FakeHost())
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: project,
                provider: .registered(provider.model),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: dataRoot,
                network: NetworkPath { true },
            ),
            backend: ChannelHostBackend(service: facade, sessionID: "unused", project: project, projectURL: projectURL),
            digests: HostDigestLedger(service: facade, projectURL: projectURL, dataFolder: dataRoot.url),
            credentials: DeliveredCredentialSource(),
        )
        let (local, remote) = try WorkerChannel.makePair()
        let hostEnd = WorkerChannel(adopting: local)
        let workerEnd = WorkerChannel(adopting: remote)
        let heard = Heard()
        hostEnd.onEvent { heard.add($0) }
        let exited = Exited()
        let state = WorkerState(stopPatience: .milliseconds(500)) { exited.set() }
        let context = WorkerContext(
            assignment: WorkerAssignment(role: .agent, installRoot: "/", home: home.path, sessionID: session.id),
            channel: workerEnd,
        )
        workerEnd.onRequest { request in
            await AgentWorker.handle(request, context: context, state: state)
        }
        hostEnd.start()
        workerEnd.start()
        try await state.serve(session, taskID: TaskID("agent-task"), context: context)
        return Worker(
            state: state,
            session: session,
            host: ApelinService(transport: ChannelTransport(channel: hostEnd)),
            heard: heard,
            exited: exited,
        ) {
            hostEnd.close()
            workerEnd.close()
        }
    }

    static func home() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("apelin-stop-watch-\(UUID().uuidString)", isDirectory: true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `a run that does not hear Stop is ended by the worker`() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = Provider(hears: false)
        let worker = try await Self.worker(provider, home: home)
        defer { worker.close() }
        try await worker.session.prompt("Hi")
        #expect(await worker.heard.wait(for: "messageStarted", within: .seconds(10)))

        let stopped = ContinuousClock.now
        try await worker.host.agentAbort(sessionID: worker.session.id)
        #expect(await worker.heard.wait(for: TaskEvent.stateKind, within: .seconds(10)))
        #expect(ContinuousClock.now - stopped < .seconds(5))
        #expect(worker.heard.payloads(TaskEvent.stateKind).last??["state"]?.stringValue == TaskState.cancelled.rawValue)
        let error = try #require(worker.heard.payloads("error").last ?? nil)
        #expect(error["reason"]?.stringValue == ApelinError.Reason.unstopped.rawValue, "said in the reader's language")
        #expect(error["message"]?.stringValue?.contains("did not stop in time") == true, "and in words an older app shows")
        #expect(!worker.heard.kinds.contains("finished"), "the run itself never ended")
        try await Task.sleep(for: .milliseconds(800))
        #expect(worker.exited.value, "and the process goes")
        provider.release()
        await worker.session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a run that ends on Stop is left to end in its own words`() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = Provider(hears: true)
        let worker = try await Self.worker(provider, home: home)
        defer { worker.close() }
        try await worker.session.prompt("Hi")
        #expect(await worker.heard.wait(for: "messageStarted", within: .seconds(10)))

        try await worker.host.agentAbort(sessionID: worker.session.id)
        #expect(await worker.heard.wait(for: "finished", within: .seconds(5)))
        #expect(worker.heard.payloads("finished").last??["reason"]?.stringValue == "aborted")
        // past the worker's patience, nothing more
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!worker.heard.kinds.contains(TaskEvent.stateKind))
        #expect(!worker.exited.value)
        await worker.session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a stop for another session is refused`() async throws {
        let home = Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let worker = try await Self.worker(Provider(hears: true), home: home)
        defer { worker.close() }
        await #expect(throws: ApelinError.self) {
            try await worker.host.agentAbort(sessionID: UUID().uuidString)
        }
        await worker.session.close()
    }
}
