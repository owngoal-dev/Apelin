import ApelinCore
import ApelinProtocol
import Foundation

/// An `ApelinTransport` that answers from `ReplayFixtures`, for the UI where
/// no apelind runs (a vphone or device without the package). Behind
/// `ApelinService` it looks like the session host:
///
/// - A plain operation answers the latest recorded reply whose request is
///   the same (both read as the operation's request type and written back,
///   so field order and defaults do not matter), else the latest reply of
///   that operation, else `unavailable`.
/// - An operation that started a task (`buildStart`, `agentOpen`,
///   `logStream` with a `filter`, …) picks a recording the same way and
///   answers what it answered then; the task's clock starts at that call,
///   and starting it again replays it again under the same task ID.
/// - An attach answers the events after `afterSeq` that have been released,
///   waiting up to `waitMilliseconds` for one, and `finished` once the final
///   `state` is out — the long poll of `TaskEventBatch`. A task attached to
///   without being started is one from before this run: all of it is out.
/// - Events keep their recorded `time`. With `.recorded` pacing they come
///   out as far apart as they were recorded (gaps capped, so a respring or a
///   model's pause does not stall the screen); with `.immediate`, all at once.
/// - An agent session stops after each `state` `waitingForApproval` until
///   `agentApprove` names that session, whatever the pacing: nothing
///   approves by itself here either.
///
/// Descriptors are never passed: an attach that asks for one gets none.
public final class ReplayTransport: ApelinTransport, @unchecked Sendable {
    public enum Pacing: Sendable, Equatable {
        /// Every event is out as soon as its task starts.
        case immediate
        /// Events as far apart as recorded, divided by `speed`: no gap longer
        /// than `maxGap` seconds, and none shorter than `minGap` — times are
        /// recorded to the second, and streamed text should still stream.
        case recorded(speed: Double = 1, maxGap: TimeInterval = 1.5, minGap: TimeInterval = 0.05)
    }

    private struct Playback {
        var recording: ReplayFixtures.TaskRecording
        /// Seconds from the task's start to each event's release.
        var offsets: [TimeInterval]
        /// Event indexes of each `waitingForApproval`: nothing after one is
        /// out until it is approved.
        var gates: [Int]
        /// nil: a task from before this run, all of it out.
        var startedAt: TimeInterval?
        var approvals = 0
    }

    private let fixtures: ReplayFixtures
    private let clock: @Sendable () -> TimeInterval
    private let lock = PthreadLock()
    private var playbacks: [TaskID: Playback] = [:]
    private var canonicalRequests: [String: JSONValue] = [:]

    /// - Parameter clock: seconds on any monotonic scale; the pacing reads
    ///   it, so a test can move time by hand. Long polls wait in real time.
    public init(
        fixtures: ReplayFixtures,
        pacing: Pacing = .recorded(),
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    ) {
        self.fixtures = fixtures
        self.clock = clock
        for recording in fixtures.tasks {
            playbacks[recording.taskID] = Playback(
                recording: recording,
                offsets: Self.offsets(of: recording.events, pacing: pacing),
                gates: recording.events.indices.filter { Self.state(of: recording.events[$0]) == .waitingForApproval },
            )
        }
    }

    public func call(
        _ request: WireRequest,
        descriptors _: [OwnedDescriptor],
    ) async throws -> (WireReply, [OwnedDescriptor]) {
        let payload = (try? JSONCoding.decode(JSONValue.self, from: request.payload)) ?? .object([:])
        do {
            let answer = try await answer(request.operation, payload: payload)
            return try (WireReply(requestID: request.requestID, result: .success(JSONCoding.encode(answer))), [])
        } catch let error as ApelinError {
            return (.failure(request.requestID, error), [])
        }
    }

    // MARK: - Answering

    private func answer(_ operation: AppOperation, payload: JSONValue) async throws -> JSONValue {
        if operation == .logStream, payload["stream"] == nil {
            let recording = try start(operation, payload: payload)
            return try await attach(recording.taskID, payload: payload)
        }
        if operation.requestType is any TaskAttachRequest.Type {
            guard let id = payload["taskID"]?.stringValue ?? payload["stream"]?.stringValue else {
                throw ApelinError(.badRequest, "\(operation.rawValue) names no task")
            }
            return try await attach(TaskID(id), payload: payload)
        }
        if fixtures.tasks.contains(where: { $0.start.operation == operation }) {
            return try start(operation, payload: payload).start.response
        }
        if operation == .agentApprove, let session = payload["sessionID"]?.stringValue {
            approve(session: session)
        }
        let replies = fixtures.replies.filter { $0.operation == operation }
        let request = canonical(operation, payload)
        guard let reply = replies.last(where: { canonical(operation, $0.request) == request }) ?? replies.last else {
            throw ApelinError(.unavailable, "the replay has no recording of \(operation.rawValue)")
        }
        if let error = reply.error {
            throw error
        }
        return reply.response ?? .object([:])
    }

    /// Picks the recording a starting request names and starts its clock.
    private func start(_ operation: AppOperation, payload: JSONValue) throws -> ReplayFixtures.TaskRecording {
        let candidates = fixtures.tasks.filter { $0.start.operation == operation }
        let request = canonical(operation, payload)
        guard let recording = candidates.last(where: { canonical(operation, $0.start.request) == request })
            ?? candidates.last
        else {
            throw ApelinError(.unavailable, "the replay has no task started by \(operation.rawValue)")
        }
        let now = clock()
        lock.withLock {
            playbacks[recording.taskID]?.startedAt = now
            playbacks[recording.taskID]?.approvals = 0
        }
        return recording
    }

    @objc private dynamic func approve(session: String) {
        let now = clock()
        lock.withLock {
            guard let id = playbacks.first(where: { $0.value.recording.sessionID == session })?.key,
                  var playback = playbacks[id], playback.approvals < playback.gates.count
            else { return }
            // The events after the gate go on from now, as far apart as before.
            let next = playback.gates[playback.approvals] + 1
            if next < playback.offsets.count, let startedAt = playback.startedAt,
               now - startedAt > playback.offsets[next]
            {
                playback.startedAt = now - playback.offsets[next]
            }
            playback.approvals += 1
            playbacks[id] = playback
        }
    }

    private func attach(_ taskID: TaskID, payload: JSONValue) async throws -> JSONValue {
        let after = UInt64(payload["afterSeq"]?.doubleValue ?? 0)
        let wait = TimeInterval(payload["waitMilliseconds"]?.doubleValue ?? 20000) / 1000
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, wait)
        while true {
            guard let batch = batch(taskID, after: after) else {
                throw ApelinError(.notFound, "the replay has no task \(taskID)")
            }
            if !batch.events.isEmpty
                || batch.finished
                || ProcessInfo.processInfo.systemUptime >= deadline
                || Task.isCancelled
            {
                return try JSONValue(encoding: batch)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func batch(_ taskID: TaskID, after: UInt64) -> TaskEventBatch? {
        let now = clock()
        return lock.withLock {
            guard let playback = playbacks[taskID] else { return nil }
            let events = playback.recording.events
            var released = events.count
            if let startedAt = playback.startedAt {
                released = playback.offsets.firstIndex { $0 > now - startedAt } ?? events.count
            }
            if playback.approvals < playback.gates.count {
                released = min(released, playback.gates[playback.approvals] + 1)
            }
            let out = events.prefix(released)
            let state = out.last(where: { $0.kind == TaskEvent.stateKind }).flatMap(Self.state(of:)) ?? .running
            return TaskEventBatch(
                taskID: taskID,
                events: out.filter { $0.seq.rawValue > after },
                state: state,
                lastSeq: out.last?.seq ?? .start,
                finished: released == events.count && state.isTerminal,
            )
        }
    }

    // MARK: - Helpers

    /// A request read as its operation's request type and written back, so
    /// two spellings of one request compare equal.
    private func canonical(_ operation: AppOperation, _ request: JSONValue) -> JSONValue {
        let key = "\(operation.rawValue) \((try? JSONCoding.encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? "")"
        if let known = lock.withLock({ canonicalRequests[key] }) {
            return known
        }
        let value = (try? Self.roundTrip(operation.requestType, request)) ?? request
        lock.withLock { canonicalRequests[key] = value }
        return value
    }

    private static func roundTrip<R: OperationRequest>(_: R.Type, _ request: JSONValue) throws -> JSONValue {
        try JSONValue(encoding: request.decode(R.self))
    }

    private static func state(of event: TaskEvent) -> TaskState? {
        guard event.kind == TaskEvent.stateKind else { return nil }
        return event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:))
    }

    private static func offsets(of events: [TaskEvent], pacing: Pacing) -> [TimeInterval] {
        guard case let .recorded(speed, maxGap, minGap) = pacing, speed > 0 else {
            return Array(repeating: 0, count: events.count)
        }
        var offsets: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for (index, event) in events.enumerated() {
            if index > 0 {
                let gap = event.time.timeIntervalSince(events[index - 1].time)
                elapsed += max(min(gap, maxGap), minGap) / speed
            }
            offsets.append(elapsed)
        }
        return offsets
    }
}

public extension ApelinService {
    /// An `ApelinService` that answers from the captured fixtures.
    static func replay(
        _ fixtures: ReplayFixtures,
        pacing: ReplayTransport.Pacing = .recorded(),
    ) -> ApelinService {
        ApelinService(transport: ReplayTransport(fixtures: fixtures, pacing: pacing))
    }
}
