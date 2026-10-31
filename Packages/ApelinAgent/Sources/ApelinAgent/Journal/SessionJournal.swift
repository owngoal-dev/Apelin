import struct ApelinCore.DataFolder
import struct ApelinProtocol.ApelinError
import Foundation
import KWWKAgent
import KWWKAI

/// How a tool call ended, as its journal line says.
enum ToolCallStatus: String, Sendable {
    case succeeded
    case failed
    /// The approval policy, the user, the host or the tool's own rules
    /// refused it.
    case denied
    case cancelled
    case timedOut = "timed-out"
    /// It never ended: the conversation closed, or the process that ran it
    /// went, while it was running.
    case interrupted

    var level: DiagnosticLevel {
        switch self {
        case .succeeded, .cancelled: .info
        case .failed, .denied, .timedOut: .warning
        case .interrupted: .error
        }
    }
}

/// What the runner decided about a call before kwwk ends it, where that
/// was decided: a refusal, a stop or a timeout, and by what. A call that
/// returns or throws anything else ends as kwwk says it did.
struct ToolCallOutcome: Sendable, Equatable {
    var status: ToolCallStatus
    var detail: String?

    init(_ status: ToolCallStatus, _ detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    /// What a call that threw `error` came to; `stopped` when the run was
    /// stopped while it went.
    static func of(_ error: any Error, stopped: Bool) -> ToolCallOutcome {
        if stopped || error is CancellationError {
            return ToolCallOutcome(.cancelled, "the run was stopped")
        }
        switch error {
        case let refusal as ApelinError:
            return switch refusal.code {
            case .denied: ToolCallOutcome(.denied, "the session host refused it")
            case .timeout: ToolCallOutcome(.timedOut, "the session host's time ran out")
            case .cancelled: ToolCallOutcome(.cancelled, "the session host cancelled it")
            default: ToolCallOutcome(.failed, "the session host answered \(refusal.code.rawValue)")
            }
        case is ToolDeniedError:
            return ToolCallOutcome(.denied, "the tool refused it")
        case is HostRefusedPresetError:
            return ToolCallOutcome(.denied, "the session host does not count it as a preset")
        case let failure as ToolExtensionError where failure.code == "timeout":
            return ToolCallOutcome(.timedOut, "the extension did not answer in time")
        case is ToolTimeoutError:
            return ToolCallOutcome(.timedOut)
        case let failure as URLError where failure.code == .timedOut:
            return ToolCallOutcome(.timedOut, "the request timed out")
        default:
            return ToolCallOutcome(.failed)
        }
    }
}

/// A call that ran out of time before it answered: thrown where the time
/// is kept, so the journal says timed out rather than failed. The model
/// reads its message as it would any refusal's.
struct ToolTimeoutError: Error, LocalizedError {
    var message: String
    var errorDescription: String? {
        message
    }
}

/// What a session writes into its diagnostic journal (`DiagnosticJournal`)
/// for Settings ▸ Logs: the session's opening and closing, each run, the
/// model requests that failed or were made again, every tool call from its
/// start to how it ended, the approvals asked and answered, and every
/// compaction, automatic or asked for. Each line is redacted before it is
/// written (`JournalRedaction`).
///
/// A call is ended by kwwk's `toolExecutionEnd`, with the outcome the
/// runner noted for it where one was decided; one still running when the
/// conversation closes or the process goes ends `interrupted`, and one the
/// journal shows started and never ended is ended so when the
/// conversation is opened again.
public final class SessionJournal: @unchecked Sendable {
    enum Category: String {
        case session = "Session"
        case model = "Model"
        case tool = "Tool"
        case approval = "Approval"
        case compaction = "Compaction"
    }

    /// What started a compaction.
    enum CompactionTrigger: String {
        /// kwwk, as the context filled.
        case automatic
        /// The app's Compact….
        case requested
    }

    let sessionID: String
    let redaction: JournalRedaction
    private let file: DiagnosticJournal?
    private let lock = NSLock()
    /// The time of a call's start and end to the millisecond, which Dog's
    /// line has only to the second; under its own lock.
    private let clock = DiagnosticJournal.formatter("HH:mm:ss.SSS")
    private let clockLock = NSLock()
    /// Calls started and not ended, by call ID.
    private var calls: [String: (tool: String, started: Date)] = [:]
    private var outcomes: [String: ToolCallOutcome] = [:]
    /// Approvals asked and not answered, by approval ID.
    private var approvals: [String: (call: String, tool: String, asked: Date)] = [:]
    private var runs = 0
    private var run: (number: Int, started: Date, calls: Int)?
    private var compaction: Compaction?

    /// The compaction under way.
    private struct Compaction {
        var trigger: CompactionTrigger
        var started: Date
        /// Whose summary it is: `native`, the provider's, once the provider
        /// was asked and answered or failed; `local`, kwwk's, otherwise.
        var summary = "local"
        /// The HTTP status of a request that failed meanwhile.
        var status: Int?
    }

    init(sessionID: String, file: DiagnosticJournal?, redaction: JournalRedaction) {
        self.sessionID = sessionID
        self.file = file
        self.redaction = redaction
        Self.live.add(self)
    }

    deinit {
        Self.live.remove(self)
    }

    /// The journal of `sessionID` in the data folder's `Journal/Agent/`,
    /// its missing levels made as mobile without following a link, the
    /// folder pruned to the journals written last. One that cannot be made
    /// writes nothing; the conversation goes on without it.
    static func open(dataRoot: ApelinDataRoot, sessionID: String, installRoot: String?) -> SessionJournal {
        let redaction = JournalRedaction(home: dataRoot.home.path, installRoot: installRoot)
        let folder = dataRoot.agentJournals
        do {
            try DataFolder(root: dataRoot.url).makeLevels(to: folder)
        } catch {
            return SessionJournal(sessionID: sessionID, file: nil, redaction: redaction)
        }
        DiagnosticJournal.prune(folder: folder, sparing: sessionID)
        return SessionJournal(sessionID: sessionID, file: DiagnosticJournal(folder: folder, name: sessionID), redaction: redaction)
    }

    // MARK: - Session

    func sessionOpened(
        _ configuration: AgentSessionConfiguration,
        model: Model,
        reopened: Bool,
        historyMessages: Int,
    ) {
        let tier = configuration.serviceTier?.rawValue ?? "default"
        write(.session, """
        \(reopened ? "Reopened" : "Opened") session=\(sessionID) project="\(configuration.project.name.rawValue)" \
        (\(configuration.project.id)) provider=\(Self.provider(configuration.provider)) \(Self.describe(model)) \
        mode=\(configuration.approval.mode.rawValue) thinking=\(configuration.thinking.rawValue) tier=\(tier) \
        history=\(historyMessages) messages
        """)
    }

    /// The model could not be resolved: no sign-in, or one that would not
    /// refresh. Nothing else of the session runs.
    func sessionOpenFailed(_ error: any Error) {
        write(.session, "Could not open session=\(sessionID): \(errorText(error.localizedDescription))", level: .error)
    }

    func modelChanged(to model: Model) {
        write(.session, "Model is now \(Self.describe(model))")
    }

    func modeChanged(to mode: ApprovalMode) {
        write(.session, "Approval mode is now \(mode.rawValue)")
    }

    /// The session closes: calls still running are interrupted.
    func sessionClosed() {
        interruptOpenCalls(reason: "the conversation closed while it ran")
        write(.session, "Closed session=\(sessionID)")
    }

    // MARK: - Runs and model requests

    func runStarted(model: Model, messages: Int) {
        let number = locked {
            runs += 1
            run = (runs, Date(), 0)
            return runs
        }
        write(.model, "Run \(number) started \(Self.describe(model)) messages=\(messages)")
    }

    func runEnded(_ reason: FinishReason) {
        guard let run = locked({ () -> (number: Int, started: Date, calls: Int)? in
            defer { self.run = nil }
            return self.run
        }) else { return }
        write(
            .model,
            "Run \(run.number) ended reason=\(reason.rawValue) duration=\(Self.seconds(since: run.started)) tools=\(run.calls)",
            level: reason == .failed ? .warning : .info,
        )
    }

    func runFailed(_ message: String) {
        let number = locked { run?.number }
        write(
            .model,
            "Run\(number.map { " \($0)" } ?? "") failed: \(redaction.text(message, limit: JournalRedaction.errorBytes))",
            level: .error,
        )
    }

    /// A reply ended on the provider's error: the run's own failure.
    func replyFailed(_ message: AssistantMessage) {
        let error = message.errorMessage ?? message.providerFailure?.message ?? "the provider returned an error"
        let fields = "\(Self.failureFields(message.providerFailure)) \(Self.describe(message))"
        write(.model, "Reply failed \(fields) error=\(errorText(error))", level: .error)
    }

    func retrying(attempt: Int, delayMs: UInt64, reason: String) {
        write(
            .model,
            "Retrying the request (attempt \(attempt + 2)) in \(JournalRedaction.grouped(Int(delayMs))) ms: \(errorText(reason))",
            level: .warning,
        )
    }

    func waitingForNetwork() {
        write(.model, "Waiting for the network before the request goes again", level: .warning)
    }

    func replyDiscarded() {
        write(.model, "Discarded a partial reply; the request goes again")
    }

    func titleFailed(_ error: any Error) {
        write(.model, "Title request failed: \(errorText(error.localizedDescription))", level: .warning)
    }

    /// `inner` with every request that ends on an error journaled: its
    /// status, request ID and the provider's words. A compaction under way
    /// keeps the status for its own line.
    func observingRequests(_ inner: @escaping StreamFn) -> StreamFn {
        { [weak self] model, context, options in
            let attempt = try await inner(model, context, options)
            guard let self else { return attempt }
            let (stream, out) = AssistantMessageStream.makeStream()
            Task {
                for await event in attempt {
                    out.push(event)
                }
                let final = await attempt.result()
                if final.stopReason == .error {
                    self.requestFailed(final, model: model)
                }
                out.end(final)
            }
            return stream
        }
    }

    private func requestFailed(_ message: AssistantMessage, model: Model) {
        let failure = message.providerFailure
        if let status = failure?.httpStatus {
            locked { compaction?.status = status }
        }
        let error = failure?.message ?? message.errorMessage ?? "unknown error"
        write(.model, "Request failed \(Self.failureFields(failure)) \(Self.describe(model)) error=\(errorText(error))", level: .warning)
    }

    // MARK: - Tool calls

    func toolStarted(id: String, name: String, arguments: JSONValue) {
        let started = Date()
        locked {
            calls[id] = (name, started)
            run?.calls += 1
        }
        write(.tool, """
        Started call=\(Self.token(id)) tool=\(Self.token(name)) session=\(sessionID) at=\(time(started)) \
        arguments=\(redaction.arguments(arguments, tool: name))
        """)
    }

    /// What the runner decided about call `id`; the first noted stands.
    func note(_ outcome: ToolCallOutcome, for id: String) {
        locked {
            if outcomes[id] == nil {
                outcomes[id] = outcome
            }
        }
    }

    /// kwwk ended call `id`: as the runner noted, else as `isError` says;
    /// an error while the run was being stopped is the stop's.
    func toolEnded(id: String, name: String, result: AgentToolResult, isError: Bool, runStopped: Bool) {
        let (call, noted) = locked { (calls.removeValue(forKey: id), outcomes.removeValue(forKey: id)) }
        let outcome = noted ?? (isError
            ? (runStopped ? ToolCallOutcome(.cancelled, "the run was stopped") : ToolCallOutcome(.failed))
            : ToolCallOutcome(.succeeded))
        let ended = Date()
        var fields = "Ended call=\(Self.token(id)) tool=\(Self.token(name)) session=\(sessionID) status=\(outcome.status.rawValue)"
        if let call {
            fields += " started=\(time(call.started)) ended=\(time(ended)) duration=\(Self.seconds(since: call.started, to: ended))"
        } else {
            fields += " ended=\(time(ended))"
        }
        if let detail = outcome.detail {
            fields += " detail=\"\(detail)\""
        }
        write(.tool, fields + " result=" + redaction.result(result), level: outcome.status.level)
    }

    /// Every call still running ends `interrupted`, for `reason`.
    func interruptOpenCalls(reason: String) {
        let open = locked { () -> [(id: String, tool: String, started: Date)] in
            defer {
                calls.removeAll()
                outcomes.removeAll()
            }
            return calls.map { ($0.key, $0.value.tool, $0.value.started) }.sorted { $0.started < $1.started }
        }
        let ended = Date()
        for call in open {
            write(.tool, """
            Ended call=\(Self.token(call.id)) tool=\(Self.token(call.tool)) session=\(sessionID) status=interrupted \
            started=\(time(call.started)) ended=\(time(ended)) duration=\(Self.seconds(since: call.started, to: ended)) \
            detail="\(reason)"
            """, level: .error)
        }
    }

    /// The calls the journal shows started and never ended, by an earlier
    /// process of this conversation that went while they ran, are ended
    /// `interrupted` now, so a crash leaves no call that looks as if it
    /// were still going.
    func closeUnfinishedCalls() {
        guard let file else { return }
        for call in Self.unfinishedCalls(in: file.contents(), session: sessionID) {
            write(.tool, """
            Ended call=\(call.id) tool=\(call.tool) session=\(sessionID) status=interrupted \
            detail="the process that ran it ended before the call did; found when the conversation opened again"
            """, level: .error)
        }
    }

    /// The `Started` lines of `text` with no `Ended` line for their call,
    /// in the order they started.
    static func unfinishedCalls(in text: String, session: String) -> [(id: String, tool: String)] {
        var started: [(id: String, tool: String)] = []
        var ended: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let message = message(of: line) else { continue }
            let isStart = message.hasPrefix("Started call=")
            guard isStart || message.hasPrefix("Ended call=") else { continue }
            // `Started call=<id> tool=<name> session=<id> …`
            let fields = message.split(separator: " ", maxSplits: 4)
            guard fields.count >= 4, fields[2].hasPrefix("tool="), fields[3] == "session=\(session)" else { continue }
            let id = String(fields[1].dropFirst("call=".count))
            if isStart {
                started.append((id, String(fields[2].dropFirst("tool=".count))))
            } else {
                ended.insert(id)
            }
        }
        var seen: Set<String> = []
        return started.filter { !ended.contains($0.id) && seen.insert($0.id).inserted }
    }

    /// The message of an entry written Dog's way, `* |<level>| <time>|
    /// <message>`, as Settings ▸ Logs reads it; nil for a category line or
    /// anything else.
    private static func message(of line: Substring) -> Substring? {
        guard line.hasPrefix("* |") else { return nil }
        let body = line.dropFirst(3)
        guard let level = body.firstIndex(of: "|") else { return nil }
        let rest = body[body.index(after: level)...]
        guard let time = rest.firstIndex(of: "|") else { return nil }
        let message = rest[rest.index(after: time)...]
        return message.first == " " ? message.dropFirst() : message
    }

    // MARK: - Approvals

    /// The approval gate's events: asked and answered.
    func record(_ event: AgentSessionEvent) {
        switch event {
        case let .approvalRequested(request): approvalAsked(request)
        case let .approvalResolved(id, decision): approvalResolved(id: id, decision: decision)
        default: break
        }
    }

    func approvalAsked(_ request: ApprovalRequest) {
        locked { approvals[request.id] = (request.toolCallID, request.tool, Date()) }
        write(.approval, """
        Asked approval=\(Self.token(request.id)) call=\(Self.token(request.toolCallID)) tool=\(Self.token(request.tool)) \
        reason="\(redaction.text(request.reason, limit: JournalRedaction.argumentBytes))"
        """)
    }

    func approvalResolved(id: String, decision: ApprovalDecision) {
        let asked = locked { approvals.removeValue(forKey: id) }
        let answer = switch decision {
        case .approve(.once): "approved once"
        case .approve(.session): "approved for the session"
        case let .deny(reason): "denied" + (reason.map { ": " + redaction.text($0, limit: JournalRedaction.argumentBytes) } ?? "")
        }
        var fields = "Resolved approval=\(Self.token(id))"
        if let asked {
            fields += " call=\(Self.token(asked.call)) tool=\(Self.token(asked.tool)) after=\(Self.seconds(since: asked.asked))"
        }
        write(.approval, fields + " decision=\"\(answer)\"")
    }

    // MARK: - Compaction

    func compactionStarted(_ trigger: CompactionTrigger, model: Model, messages: Int, usage: AgentContextUsage) {
        locked { compaction = Compaction(trigger: trigger, started: Date()) }
        write(.compaction, """
        Started trigger=\(trigger.rawValue) messages=\(messages) tokens≈\(JournalRedaction.grouped(usage.tokens)) \
        window=\(JournalRedaction.grouped(usage.window)) \(Self.describe(model))
        """)
    }

    /// How the compaction ended; `usage` is the context's after it, and
    /// `stopped` says the run or compaction was stopped meanwhile.
    func compactionEnded(_ outcome: AgentContextCompactionOutcome, usage: AgentContextUsage, stopped: Bool) {
        guard let compaction = locked({ () -> Compaction? in
            defer { self.compaction = nil }
            return self.compaction
        }) else { return }
        let fields = "trigger=\(compaction.trigger.rawValue) duration=\(Self.seconds(since: compaction.started))"
        switch outcome {
        case let .compacted(messagesCompacted, _):
            write(.compaction, """
            Ended outcome=compacted \(fields) summary=\(compaction.summary) messages=\(messagesCompacted) \
            tokens≈\(JournalRedaction.grouped(usage.tokens))
            """)
        case let .refusedTooFewMessages(count):
            write(.compaction, "Ended outcome=tooShort \(fields) messages=\(count)")
        case .failed where stopped:
            write(.compaction, "Ended outcome=cancelled \(fields)")
        case .refusedAgentBusy:
            write(.compaction, "Failed \(fields) error=\"the chat was busy\"", level: .error)
        case let .failed(reason):
            let status = compaction.status.map { " status=\($0)" } ?? ""
            write(
                .compaction,
                "Failed \(fields) summary=\(compaction.summary)\(status) error=\(errorText(reason))",
                level: .error,
            )
        }
    }

    /// The compaction `configuration` with its native compaction journaled:
    /// whether the provider summarised, had nothing, or failed and how.
    func observingCompaction(_ configuration: AgentContextCompactionConfig) -> AgentContextCompactionConfig {
        guard let native = configuration.nativeCompaction else { return configuration }
        var configuration = configuration
        configuration.nativeCompaction = { [weak self] model, context, instructions, options in
            let started = Date()
            do {
                let result = try await native(model, context, instructions, options)
                self?.nativeCompactionAnswered(result != nil, model: model, started: started)
                return result
            } catch {
                self?.nativeCompactionFailed(error, model: model, started: started)
                throw error
            }
        }
        return configuration
    }

    private func nativeCompactionAnswered(_ summarised: Bool, model: Model, started: Date) {
        locked { compaction?.summary = summarised ? "native" : "local" }
        let fields = "\(Self.describe(model)) duration=\(Self.seconds(since: started))"
        write(.compaction, summarised
            ? "Native compaction answered \(fields)"
            : "Native compaction brought no summary back; kwwk summarises instead \(fields)")
    }

    private func nativeCompactionFailed(_ error: any Error, model: Model, started: Date) {
        let failure = error as? ProviderFailure
        locked {
            compaction?.summary = "native"
            if let status = failure?.httpStatus {
                compaction?.status = status
            }
        }
        write(.compaction, """
        Native compaction failed \(Self.failureFields(failure)) \(Self.describe(model)) \
        duration=\(Self.seconds(since: started)) error=\(errorText(failure?.message ?? error.localizedDescription))
        """, level: .warning)
    }

    // MARK: - Writing

    private func write(_ category: Category, _ message: String, level: DiagnosticLevel = .info) {
        file?.write(category.rawValue, redaction.redacted(message), level: level)
    }

    private func errorText(_ text: String) -> String {
        "\"" + redaction.text(text, limit: JournalRedaction.errorBytes) + "\""
    }

    private func time(_ date: Date) -> String {
        clockLock.withLock { clock.string(from: date) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.withLock(body)
    }

    /// An ID as one word of a line: a provider's call IDs have no spaces,
    /// but nothing promises it.
    static func token(_ id: String) -> String {
        id.isEmpty ? "-" : String(id.map { $0.isWhitespace || $0 == "|" ? "_" : $0 })
    }

    /// `model=<id> api=<wire> host=<endpoint>`: the model, how it is asked,
    /// and where; never a key.
    static func describe(_ model: Model) -> String {
        "model=\(token(model.id)) api=\(token(model.api)) host=\(host(of: model.baseURL))"
    }

    private static func describe(_ message: AssistantMessage) -> String {
        "model=\(token(message.model)) api=\(token(message.api))"
    }

    private static func host(of address: String) -> String {
        URL(string: address)?.host.map(token) ?? "-"
    }

    private static func provider(_ provider: ProviderConfiguration) -> String {
        switch provider {
        case .registered: "registered"
        default: provider.storeID ?? "-"
        }
    }

    /// `status=<HTTP status> request=<ID>` as far as the failure says.
    private static func failureFields(_ failure: ProviderFailure?) -> String {
        var fields = "status=\(failure?.httpStatus.map(String.init) ?? "-")"
        if let code = failure?.providerCode {
            fields += " code=\(token(code))"
        }
        if let request = failure?.requestId {
            fields += " request=\(token(request))"
        }
        return fields
    }

    /// `1.607s`: from `start` to `end`.
    static func seconds(since start: Date, to end: Date = Date()) -> String {
        String(format: "%.3fs", max(0, end.timeIntervalSince(start)))
    }

    // MARK: - The process going

    /// Every journal open in this process ends its running calls
    /// `interrupted`: the session host closed the worker's channel, and
    /// the worker exits next.
    public static func interruptAll(reason: String) {
        for journal in live.all {
            journal.interruptOpenCalls(reason: reason)
        }
    }

    private static let live = LiveJournals()

    private final class LiveJournals: @unchecked Sendable {
        private let lock = NSLock()
        private var journals: [ObjectIdentifier: Weak] = [:]

        private struct Weak {
            weak var journal: SessionJournal?
        }

        func add(_ journal: SessionJournal) {
            lock.withLock { journals[ObjectIdentifier(journal)] = Weak(journal: journal) }
        }

        func remove(_ journal: SessionJournal) {
            lock.withLock { journals[ObjectIdentifier(journal)] = nil }
        }

        var all: [SessionJournal] {
            lock.withLock { journals.values.compactMap(\.journal) }
        }
    }
}
