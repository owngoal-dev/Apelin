import enum ApelinCore.PrivateShapes
import struct ApelinCore.DataFolder
import Foundation
import KWWKAgent
import KWWKAI

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
/// conversation is opened again. Starts and ends are paired in order, so
/// a call ID a provider uses twice is two calls.
///
/// Every method returns at once: what it was given, and when, goes to one
/// serial queue, where the journal's state is kept, every text redacted and
/// every line written. Neither the session's actor nor its caller waits on
/// a redaction or the file; `flush` and `drain` wait for what was asked.
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
    /// Where everything below is read and written, in the order asked.
    private let queue = DispatchQueue(label: "wiki.qaq.apelin.agent.journal", qos: .utility)
    /// The time of a call's start and end to the millisecond, which Dog's
    /// line has only to the second.
    private let clock = DiagnosticJournal.formatter("HH:mm:ss.SSS")
    /// Calls started and not ended, by call ID, oldest first.
    private var calls: [String: [(tool: String, started: Date)]] = [:]
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
        /// The provider was asked for its own summary and failed.
        var nativeFailed = false
        /// It answered with one, which kwwk may still set aside as too large.
        var nativeAnswered = false
        /// The HTTP status of a request that failed meanwhile.
        var status: Int?
    }

    /// How much of the journal's end is read to find the calls a process
    /// that went left unended: the calls a run had going are its last lines.
    static let unfinishedTailBytes = 128 * 1024

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
        let names = PrivateShapes.currentHostName().map { [$0] } ?? []
        let redaction = JournalRedaction(home: dataRoot.home.path, installRoot: installRoot, names: names)
        let folder = dataRoot.agentJournals
        do {
            try DataFolder(root: dataRoot.url).makeLevels(to: folder)
        } catch {
            return SessionJournal(sessionID: sessionID, file: nil, redaction: redaction)
        }
        let journal = SessionJournal(sessionID: sessionID, file: DiagnosticJournal(folder: folder, name: sessionID), redaction: redaction)
        journal.queue.async {
            DiagnosticJournal.prune(folder: folder, sparing: sessionID)
        }
        return journal
    }

    /// Returns once everything asked for before is written.
    func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    /// `flush`, blocking: for the worker's last moment and the tests.
    func drain() {
        queue.sync {}
    }

    // MARK: - Session

    func sessionOpened(
        _ configuration: AgentSessionConfiguration,
        model: Model,
        reopened: Bool,
        historyMessages: Int,
    ) {
        perform { journal in
            let tier = configuration.serviceTier?.rawValue ?? "default"
            journal.write(.session, """
            \(reopened ? "Reopened" : "Opened") session=\(journal.sessionID) \
            project="\(configuration.project.name.rawValue)" (\(configuration.project.id)) \
            provider=\(Self.provider(configuration.provider)) \(Self.describe(model)) \
            mode=\(configuration.approval.mode.rawValue) thinking=\(configuration.thinking.rawValue) tier=\(tier) \
            history=\(historyMessages) messages
            """)
        }
    }

    /// The model could not be resolved: no sign-in, or one that would not
    /// refresh. Nothing else of the session runs.
    func sessionOpenFailed(_ error: any Error) {
        let message = error.localizedDescription
        perform { journal in
            journal.write(.session, "Could not open session=\(journal.sessionID): \(journal.errorText(message))", level: .error)
        }
    }

    func modelChanged(to model: Model) {
        perform { $0.write(.session, "Model is now \(Self.describe(model))") }
    }

    func modeChanged(to mode: ApprovalMode) {
        perform { $0.write(.session, "Approval mode is now \(mode.rawValue)") }
    }

    /// The session closes: calls still running are interrupted. `flush`
    /// waits for the lines.
    func sessionClosed() {
        let now = Date()
        perform { journal in
            journal.interruptCalls(reason: "the conversation closed while it ran", at: now)
            journal.write(.session, "Closed session=\(journal.sessionID)", at: now)
        }
    }

    // MARK: - Runs and model requests

    func runStarted(model: Model, messages: Int) {
        let now = Date()
        perform { journal in
            journal.runs += 1
            journal.run = (journal.runs, now, 0)
            journal.write(.model, "Run \(journal.runs) started \(Self.describe(model)) messages=\(messages)", at: now)
        }
    }

    func runEnded(_ reason: FinishReason) {
        let now = Date()
        perform { journal in
            guard let run = journal.run else { return }
            journal.run = nil
            journal.write(
                .model,
                "Run \(run.number) ended reason=\(reason.rawValue) duration=\(Self.seconds(since: run.started, to: now)) tools=\(run.calls)",
                level: reason == .failed ? .warning : .info,
                at: now,
            )
        }
    }

    func runFailed(_ message: String) {
        perform { journal in
            let number = journal.run.map { " \($0.number)" } ?? ""
            journal.write(.model, "Run\(number) failed: \(journal.errorText(message))", level: .error)
        }
    }

    /// A reply ended on the provider's error: the run's own failure.
    func replyFailed(_ message: AssistantMessage) {
        perform { journal in
            let failure = message.providerFailure
            let error = message.errorMessage ?? failure?.message ?? "the provider returned an error"
            let fields = "\(Self.failureFields(failure)) model=\(Self.token(message.model)) api=\(Self.token(message.api))"
            journal.write(.model, "Reply failed \(fields) error=\(journal.errorText(error))", level: .error)
        }
    }

    func retrying(attempt: Int, delayMs: UInt64, reason: String) {
        perform { journal in
            journal.write(
                .model,
                "Retrying the request (attempt \(attempt + 2)) in \(JournalRedaction.grouped(Int(delayMs))) ms: \(journal.errorText(reason))",
                level: .warning,
            )
        }
    }

    func waitingForNetwork() {
        perform { $0.write(.model, "Waiting for the network before the request goes again", level: .warning) }
    }

    func replyDiscarded() {
        perform { $0.write(.model, "Discarded a partial reply; the request goes again") }
    }

    func titleFailed(_ error: any Error) {
        let message = error.localizedDescription
        perform { $0.write(.model, "Title request failed: \($0.errorText(message))", level: .warning) }
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
        perform { journal in
            let failure = message.providerFailure
            if let status = failure?.httpStatus {
                journal.compaction?.status = status
            }
            let error = failure?.message ?? message.errorMessage ?? "unknown error"
            journal.write(
                .model,
                "Request failed \(Self.failureFields(failure)) \(Self.describe(model)) error=\(journal.errorText(error))",
                level: .warning,
            )
        }
    }

    // MARK: - Tool calls

    func toolStarted(id: String, name: String, arguments: JSONValue) {
        let now = Date()
        perform { journal in
            journal.calls[id, default: []].append((name, now))
            journal.run?.calls += 1
            journal.write(.tool, """
            Started call=\(Self.token(id)) tool=\(Self.token(name)) session=\(journal.sessionID) at=\(journal.time(now)) \
            arguments=\(journal.redaction.arguments(arguments, tool: name))
            """, at: now)
        }
    }

    /// What the runner decided about call `id`; the first noted stands.
    func note(_ outcome: ToolCallOutcome, for id: String) {
        perform { journal in
            if journal.outcomes[id] == nil {
                journal.outcomes[id] = outcome
            }
        }
    }

    /// kwwk ended call `id`: as the runner noted, else as `isError` says;
    /// an error while the run was being stopped is the stop's.
    func toolEnded(id: String, name: String, result: AgentToolResult, isError: Bool, runStopped: Bool) {
        let now = Date()
        perform { journal in
            let call = journal.calls[id]?.first
            if journal.calls[id]?.count ?? 0 > 1 {
                journal.calls[id]?.removeFirst()
            } else {
                journal.calls[id] = nil
            }
            let noted = journal.outcomes.removeValue(forKey: id)
            let outcome = noted ?? (isError
                ? (runStopped ? ToolCallOutcome(.cancelled, "the run was stopped") : ToolCallOutcome(.failed))
                : ToolCallOutcome(.succeeded))
            var fields = "Ended call=\(Self.token(id)) tool=\(Self.token(name)) session=\(journal.sessionID)"
            fields += " status=\(outcome.status.rawValue)"
            if let call {
                fields += " started=\(journal.time(call.started)) ended=\(journal.time(now))"
                fields += " duration=\(Self.seconds(since: call.started, to: now))"
            } else {
                fields += " ended=\(journal.time(now))"
            }
            if let detail = outcome.detail {
                fields += " detail=\"\(detail)\""
            }
            let kept = journal.redaction.result(result, tool: name, isError: isError)
            journal.write(.tool, fields + " result=" + kept, level: outcome.status.level, at: now)
        }
    }

    /// Every call still running ends `interrupted`, for `reason`.
    func interruptOpenCalls(reason: String) {
        let now = Date()
        perform { $0.interruptCalls(reason: reason, at: now) }
    }

    private func interruptCalls(reason: String, at now: Date) {
        let open = calls.flatMap { id, calls in calls.map { (id: id, tool: $0.tool, started: $0.started) } }
            .sorted { $0.started < $1.started }
        calls.removeAll()
        outcomes.removeAll()
        for call in open {
            write(.tool, """
            Ended call=\(Self.token(call.id)) tool=\(Self.token(call.tool)) session=\(sessionID) status=interrupted \
            started=\(time(call.started)) ended=\(time(now)) duration=\(Self.seconds(since: call.started, to: now)) \
            detail="\(reason)"
            """, level: .error, at: now)
        }
    }

    /// The calls the journal shows started and never ended, by an earlier
    /// process of this conversation that went while they ran, are ended
    /// `interrupted`, so a crash leaves no call that looks as if it were
    /// still going. Only the journal's end is read (`unfinishedTailBytes`),
    /// on the queue.
    func closeUnfinishedCalls() {
        guard let file else { return }
        perform { journal in
            for call in Self.unfinishedCalls(in: file.tail(bytes: Self.unfinishedTailBytes), session: journal.sessionID) {
                journal.write(.tool, """
                Ended call=\(call.id) tool=\(call.tool) session=\(journal.sessionID) status=interrupted \
                detail="the process that ran it ended before the call did; found when the conversation opened again"
                """, level: .error)
            }
        }
    }

    /// The `Started` lines of `text` that no `Ended` line answers, in the
    /// order they started: each end answers the oldest start of its call
    /// ID still open, so an ID used again is another call.
    static func unfinishedCalls(in text: String, session: String) -> [(id: String, tool: String)] {
        var open: [(id: String, tool: String)] = []
        for line in text.split(separator: "\n") {
            guard let message = message(of: line) else { continue }
            let isStart = message.hasPrefix("Started call=")
            guard isStart || message.hasPrefix("Ended call=") else { continue }
            // `Started call=<id> tool=<name> session=<id> …`
            let fields = message.split(separator: " ", maxSplits: 4)
            guard fields.count >= 4, fields[2].hasPrefix("tool="), fields[3] == "session=\(session)" else { continue }
            let id = String(fields[1].dropFirst("call=".count))
            if isStart {
                open.append((id, String(fields[2].dropFirst("tool=".count))))
            } else if let index = open.firstIndex(where: { $0.id == id }) {
                open.remove(at: index)
            }
        }
        return open
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
        let now = Date()
        perform { journal in
            journal.approvals[request.id] = (request.toolCallID, request.tool, now)
            journal.write(.approval, """
            Asked approval=\(Self.token(request.id)) call=\(Self.token(request.toolCallID)) tool=\(Self.token(request.tool)) \
            reason="\(journal.redaction.text(request.reason, limit: JournalRedaction.argumentBytes))"
            """, at: now)
        }
    }

    func approvalResolved(id: String, decision: ApprovalDecision) {
        let now = Date()
        perform { journal in
            let asked = journal.approvals.removeValue(forKey: id)
            let answer = switch decision {
            case .approve(.once): "approved once"
            case .approve(.session): "approved for the session"
            case let .deny(reason):
                "denied" + (reason.map { ": " + journal.redaction.text($0, limit: JournalRedaction.argumentBytes) } ?? "")
            }
            var fields = "Resolved approval=\(Self.token(id))"
            if let asked {
                fields += " call=\(Self.token(asked.call)) tool=\(Self.token(asked.tool))"
                fields += " after=\(Self.seconds(since: asked.asked, to: now))"
            }
            journal.write(.approval, fields + " decision=\"\(answer)\"", at: now)
        }
    }

    // MARK: - Compaction

    func compactionStarted(_ trigger: CompactionTrigger, model: Model, messages: Int, usage: AgentContextUsage) {
        let now = Date()
        perform { journal in
            journal.compaction = Compaction(trigger: trigger, started: now)
            journal.write(.compaction, """
            Started trigger=\(trigger.rawValue) messages=\(messages) tokens≈\(JournalRedaction.grouped(usage.tokens)) \
            window=\(JournalRedaction.grouped(usage.window)) \(Self.describe(model))
            """, at: now)
        }
    }

    /// How the compaction ended: `usage` is the context's after it,
    /// `nativeSummary` whether the conversation now goes on from the
    /// provider's own summary, and `stopped` says the run or compaction was
    /// stopped meanwhile.
    func compactionEnded(_ outcome: AgentContextCompactionOutcome, usage: AgentContextUsage, nativeSummary: Bool, stopped: Bool) {
        let now = Date()
        perform { journal in
            guard let compaction = journal.compaction else { return }
            journal.compaction = nil
            let fields = "trigger=\(compaction.trigger.rawValue) duration=\(Self.seconds(since: compaction.started, to: now))"
            switch outcome {
            case let .compacted(messagesCompacted, _):
                // a native summary kwwk set aside as too large is no native compaction
                let summary = nativeSummary ? "native" : compaction.nativeAnswered ? "local native=too-large" : "local"
                journal.write(.compaction, """
                Ended outcome=compacted \(fields) summary=\(summary) messages=\(messagesCompacted) \
                tokens≈\(JournalRedaction.grouped(usage.tokens))
                """, at: now)
            case let .refusedTooFewMessages(count):
                journal.write(.compaction, "Ended outcome=tooShort \(fields) messages=\(count)", at: now)
            case .failed where stopped:
                journal.write(.compaction, "Ended outcome=cancelled \(fields)", at: now)
            case .refusedAgentBusy:
                journal.write(.compaction, "Failed \(fields) error=\"the chat was busy\"", level: .error, at: now)
            case let .failed(reason):
                let summary = compaction.nativeFailed ? "native" : "local"
                let status = compaction.status.map { " status=\($0)" } ?? ""
                journal.write(
                    .compaction,
                    "Failed \(fields) summary=\(summary)\(status) error=\(journal.errorText(reason))",
                    level: .error,
                    at: now,
                )
            }
        }
    }

    /// The compaction `configuration` with its native compaction journaled:
    /// whether the provider summarised, had nothing to give or failed and
    /// how. A route with no native compaction is asked nothing and says
    /// nothing.
    func observingCompaction(_ configuration: AgentContextCompactionConfig) -> AgentContextCompactionConfig {
        guard let native = configuration.nativeCompaction else { return configuration }
        var configuration = configuration
        configuration.nativeCompaction = { [weak self] model, context, instructions, options in
            let started = Date()
            let routed = await APIRegistry.shared.provider(scope: model.provider, api: model.api) is any NativeCompactionProvider
            do {
                let result = try await native(model, context, instructions, options)
                if result != nil || routed {
                    self?.nativeCompactionAnswered(result != nil, model: model, started: started)
                }
                return result
            } catch {
                self?.nativeCompactionFailed(error, model: model, started: started)
                throw error
            }
        }
        return configuration
    }

    private func nativeCompactionAnswered(_ summarised: Bool, model: Model, started: Date) {
        let now = Date()
        perform { journal in
            journal.compaction?.nativeAnswered = summarised
            let fields = "\(Self.describe(model)) duration=\(Self.seconds(since: started, to: now))"
            journal.write(.compaction, summarised
                ? "Native compaction answered \(fields)"
                : "Native compaction brought no summary back; kwwk summarises instead \(fields)", at: now)
        }
    }

    private func nativeCompactionFailed(_ error: any Error, model: Model, started: Date) {
        let now = Date()
        let failure = error as? ProviderFailure
        let message = failure?.message ?? error.localizedDescription
        perform { journal in
            journal.compaction?.nativeFailed = true
            if let status = failure?.httpStatus {
                journal.compaction?.status = status
            }
            journal.write(.compaction, """
            Native compaction failed \(Self.failureFields(failure)) \(Self.describe(model)) \
            duration=\(Self.seconds(since: started, to: now)) error=\(journal.errorText(message))
            """, level: .warning, at: now)
        }
    }

    // MARK: - Writing

    /// Runs `work` on the queue with the journal.
    private func perform(_ work: @escaping @Sendable (SessionJournal) -> Void) {
        queue.async { work(self) }
    }

    private func write(_ category: Category, _ message: String, level: DiagnosticLevel = .info, at date: Date = Date()) {
        file?.write(category.rawValue, redaction.redacted(message), level: level, date: date)
    }

    private func errorText(_ text: String) -> String {
        "\"" + redaction.text(text, limit: JournalRedaction.errorBytes) + "\""
    }

    private func time(_ date: Date) -> String {
        clock.string(from: date)
    }

    /// An ID as one word of a line: a provider's call IDs have no spaces,
    /// but nothing promises it.
    static func token(_ id: String) -> String {
        id.isEmpty ? "-" : String(id.map { $0.isWhitespace || $0.isNewline || $0 == "|" ? "_" : $0 })
    }

    /// `model=<id> api=<wire> host=<endpoint>`: the model, how it is asked,
    /// and where — no private address or local name —; never a key.
    static func describe(_ model: Model) -> String {
        let host = JournalRedaction.endpoint(URL(string: model.baseURL)?.host)
        return "model=\(token(model.id)) api=\(token(model.api)) host=\(token(host))"
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
    /// `interrupted`, and returns once that is written: the session host
    /// closed the worker's channel, and the worker exits next.
    public static func interruptAll(reason: String) {
        for journal in live.all {
            journal.interruptOpenCalls(reason: reason)
            journal.drain()
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
