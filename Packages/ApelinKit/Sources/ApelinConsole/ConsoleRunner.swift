import ApelinCore
import ApelinProtocol
import Foundation

/// The console: Apelin run headless from a script, against the same
/// `ApelinService` the UI and the agent's tools call. It is the app itself,
/// not a second peer of apelind, so "No CLI" holds; the app binds it to
/// `ApelinService.app` and `DataFolder.app` and starts it from
/// `didFinishLaunching` (Apelin/Console/ConsoleLaunch.swift).
///
/// Scripts come from the launch argument `-apelin-console <path>` and from
/// `~/Documents/wiki.qaq.apelin/console/inbox/*.json`, checked at launch and
/// whenever the app comes to the foreground. An inbox script is claimed into
/// `running/`, run, and moved to `done/`. Every run writes JSON lines to
/// `console/out/<runID>.jsonl` and to the log sink (on a device the unified
/// log, subsystem `wiki.qaq.apelin`, category `console`).
/// Documents/Console.md has the format.
public actor ConsoleRunner {
    public static let launchArgument = "-apelin-console"

    private let service: ApelinService
    private let folder: DataFolder
    private let log: any ConsoleLogSink
    /// Seconds the run waits after a `respring` that succeeded before it
    /// starts the next step. The answer comes back before SpringBoard takes
    /// the app down; starting the next step at once would leave that step,
    /// not the respring, the last one started, and the resume after a
    /// respring would never apply.
    private let respringPause: TimeInterval
    private var draining = false
    /// Runs in progress in this process, so a resume never picks one up.
    private var activeRuns: Set<String> = []

    /// Seconds the run waits for a respring to take the app down.
    public static let defaultRespringPause: TimeInterval = 15

    public init(
        service: ApelinService,
        folder: DataFolder,
        log: any ConsoleLogSink = UnifiedLogSink(),
        respringPause: TimeInterval = ConsoleRunner.defaultRespringPause,
    ) {
        self.service = service
        self.folder = folder
        self.log = log
        self.respringPause = respringPause
    }

    /// The script named on the command line, then what an earlier launch
    /// left in `running/`, then the inbox.
    public func runLaunchScript(arguments: [String]) async {
        if let index = arguments.firstIndex(of: Self.launchArgument), arguments.indices.contains(index + 1) {
            let path = arguments[index + 1]
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.console.appendingPathComponent(path)
            await run(scriptAt: url)
        }
        await resumeInterrupted()
        await drainInbox()
    }

    /// Runs every script in the inbox, oldest name first, one at a time.
    public func drainInbox() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        prepareFolders()
        while let next = nextInboxScript() {
            await run(scriptAt: next, claimed: true)
        }
    }

    /// Runs the script at `source` in place and answers its runID. A script
    /// run this way is not in `running/`, so it is never resumed.
    @discardableResult
    public func run(scriptAt source: URL) async -> String? {
        await run(scriptAt: source, claimed: false)
    }

    // MARK: Running

    @discardableResult
    private func run(scriptAt source: URL, claimed: Bool) async -> String? {
        prepareFolders()
        let runID = Self.makeRunID()
        activeRuns.insert(runID)
        defer { activeRuns.remove(runID) }
        let scriptURL: URL
        if claimed {
            scriptURL = folder.consoleRunning.appendingPathComponent("\(runID)-\(source.lastPathComponent)")
            do {
                try FileManager.default.moveItem(at: source, to: scriptURL)
            } catch {
                // Another drain claimed it first.
                return nil
            }
        } else {
            scriptURL = source
        }

        let output = ConsoleOutput(
            url: folder.consoleOut.appendingPathComponent("\(runID).jsonl"),
            runID: runID,
            log: log,
        )
        output.write("run.start", ["script": .string(source.lastPathComponent)])

        var failedStep: Int?
        do {
            let data = try Data(contentsOf: scriptURL)
            let script = try JSONCoding.decode(ConsoleScript.self, from: data)
            if let name = script.name {
                output.write("run.name", ["name": .string(name)])
            }
            failedStep = try await runSteps(script.steps, output: output)
        } catch is CancellationError {
            // Stopped while waiting for a respring: as if the app went away,
            // the output ends where it is and a claimed script stays in
            // `running/` for the next launch.
            output.close()
            return runID
        } catch {
            output.write("run.invalid", ["error": .string(String(describing: error))])
            failedStep = -1
        }
        end(output, failedStep: failedStep)

        if claimed {
            let done = folder.consoleDone.appendingPathComponent(scriptURL.lastPathComponent)
            try? FileManager.default.moveItem(at: scriptURL, to: done)
        }
        return runID
    }

    /// Answers the index of the step that stopped the run, or nil. Throws
    /// `CancellationError` only when cancelled during the wait after a
    /// respring, which stands for the app going away.
    private func runSteps(
        _ steps: [ConsoleStep],
        from start: Int = 0,
        results carried: [String: ConsoleStepResult] = [:],
        previous carriedPrevious: ConsoleStepResult? = nil,
        output: ConsoleOutput,
    ) async throws -> Int? {
        var results = carried
        var previous = carriedPrevious
        for (index, step) in steps.enumerated() where index >= start {
            let header = Self.header(step, index: index)
            output.write("step.start", header)
            let started = Date()

            let result: ConsoleStepResult
            do {
                let request = try ConsoleSubstitution.apply(step.request ?? .object([:]), results: results)
                result = try await perform(
                    step,
                    request: request,
                    index: index,
                    previous: previous,
                    results: results,
                    output: output,
                )
            } catch {
                result = ConsoleStepResult(ok: false, error: Self.errorJSON(error))
            }
            Self.writeResult(result, header: header, started: started, output: output)

            if let label = step.label {
                results[label] = result
            }
            previous = result
            if !result.ok, step.allowError != true {
                return index
            }
            if step.op == AppOperation.respring.rawValue, result.ok {
                try await waitForRespring(index: index, output: output)
            }
        }
        return nil
    }

    /// After a `respring` that succeeded: give SpringBoard time to take the
    /// app down before the next step starts, so the respring stays the last
    /// step started and the next launch goes on after it. An app still
    /// running after the pause writes a `step.note` and goes on.
    private func waitForRespring(index: Int, output: ConsoleOutput) async throws {
        if respringPause > 0 {
            try await Task.sleep(nanoseconds: UInt64(respringPause * 1_000_000_000))
        }
        try Task.checkCancellation()
        output.write("step.note", [
            "index": .number(Double(index)),
            "note": .string("respringSurvived"),
            "message": .string("the app was still running \(Int(respringPause)) s after the respring; going on"),
        ])
    }

    private func perform(
        _ step: ConsoleStep,
        request: JSONValue,
        index: Int,
        previous: ConsoleStepResult?,
        results: [String: ConsoleStepResult],
        output: ConsoleOutput,
    ) async throws -> ConsoleStepResult {
        if let builtin = ConsoleBuiltin(rawValue: step.op) {
            switch builtin {
            case .wait:
                let seconds = request["seconds"]?.doubleValue ?? 1
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                return ConsoleStepResult(ok: true)
            case .expect:
                let expectation = try request.decode(ConsoleExpectation.self)
                let subject = expectation.step.flatMap { results[$0] } ?? previous
                guard let subject else { throw ConsoleFailure("expect has no step to look at") }
                if let problem = Self.check(expectation, against: subject) {
                    return ConsoleStepResult(
                        ok: false,
                        error: .object(["code": .string("expectationFailed"), "message": .string(problem)]),
                    )
                }
                return ConsoleStepResult(ok: true)
            }
        }

        guard let operation = AppOperation(rawValue: step.op) else {
            throw ApelinError(.unknownOperation, step.op)
        }
        // API configuration is exposed only to the explicit editing form.
        // Console responses are persisted and logged, so never fetch its key.
        guard operation != .agentAPIConfiguration else {
            throw ApelinError(.denied, "API configuration is available only in the provider editing form.")
        }
        // A script and its output are plain files; a git token goes in
        // only through Settings ▸ Git.
        guard operation != .gitCredentialSet else {
            throw ApelinError(.denied, "A git credential is saved only in Settings ▸ Git.")
        }
        // The same for the device passcode, which also locks the device to
        // test it: a person types it in Settings, and nothing else sends it.
        guard operation != .devicePasscodeSave else {
            throw ApelinError(.denied, "The device passcode is saved and tested only in Apelin's Settings.")
        }
        // A star is the reader's, given on their GitHub account by a tap in
        // the app; a script never gives one for them.
        guard operation != .feedbackStar else {
            throw ApelinError(.denied, "Apelin is starred only from the app, when the reader taps Star Now.")
        }
        // A command as root runs only after the device owner's check in the
        // app: approving one carries the owner mark, and Full runs one
        // without asking. A script file cannot stand in for that check, so
        // the console sends neither.
        let carriesOwnerMark = operation == .agentApprove && (request["ownerVerified"] ?? .null) != .null
        guard !carriesOwnerMark else {
            throw ApelinError(.denied, "A command that runs as root is approved only in the conversation, after the device owner's check.")
        }
        let setsFull = [AppOperation.agentOpen, .agentPrompt].contains(operation)
            && request["approvalMode"]?.stringValue == ApprovalMode.full.rawValue
        guard !setsFull else {
            throw ApelinError(.denied, "Full mode is turned on in the app, after the device owner's check; the console does not set it.")
        }
        let (response, _) = try await service.sendUntyped(operation, request: request)

        guard step.follow != false else { return ConsoleStepResult(ok: true, response: response) }
        if let kind = Self.attachedKind(operation), let batch = try? response.decode(TaskEventBatch.self) {
            return await follow(
                batch,
                kind: kind,
                response: response,
                index: index,
                timeout: step.timeoutSeconds ?? Self.defaultTimeout,
                output: output,
            )
        }
        guard let handle = Self.taskHandle(in: response, nested: step.follow == true) else {
            return ConsoleStepResult(ok: true, response: response)
        }
        // Written before the first event, so a launch after the app died
        // mid-follow knows which task to attach to again.
        Self.writeTask(handle, response: response, index: index, output: output)
        return await follow(
            handle,
            response: response,
            index: index,
            timeout: step.timeoutSeconds ?? Self.defaultTimeout,
            output: output,
        )
    }

    /// Seconds a step follows its task when the script names no timeout.
    private static let defaultTimeout: Double = 1800

    /// The `step.task` line naming the task a step follows.
    private static func writeTask(_ handle: TaskHandle, response: JSONValue, index: Int, output: ConsoleOutput) {
        output.write("step.task", [
            "index": .number(Double(index)),
            "taskID": .string(handle.taskID.rawValue),
            "kind": .string(handle.kind.rawValue),
            "response": response,
        ])
    }

    /// An attach's answer (`buildAttach`, `environmentAttach`, `agentAttach`,
    /// `ptyAttach`, `logStream`, `confirmLoadedAttach`): its events are the
    /// step's first, and a task that has not finished is read on from the
    /// batch's `lastSeq` with the same attach, so a script can pick up a task
    /// by ID — one an earlier run or an earlier host started — and read it to
    /// the end.
    private func follow(
        _ batch: TaskEventBatch,
        kind: TaskKind,
        response: JSONValue,
        index: Int,
        timeout: Double,
        output: ConsoleOutput,
    ) async -> ConsoleStepResult {
        let handle = TaskHandle(taskID: batch.taskID, kind: kind)
        if !batch.finished {
            Self.writeTask(handle, response: response, index: index, output: output)
        }
        let earlier = batch.events.map { (try? JSONValue(encoding: $0)) ?? .null }
        for event in earlier {
            output.write("step.event", [
                "index": .number(Double(index)),
                "taskID": .string(handle.taskID.rawValue),
                "event": event,
            ])
        }
        guard batch.finished else {
            return await follow(
                handle,
                response: response,
                index: index,
                timeout: timeout,
                afterSeq: batch.lastSeq,
                earlier: earlier,
                output: output,
            )
        }
        var result = ConsoleStepResult(ok: true, response: response, events: earlier, state: batch.state.rawValue)
        if batch.state != .succeeded {
            result.ok = false
            result.error = .object([
                "code": .string("taskEnded"),
                "message": .string("the task ended \(batch.state.rawValue)"),
            ])
        }
        return result
    }

    /// Reads a task's events after `afterSeq` until it finishes, writing
    /// each as a line. `earlier` are the events a previous launch already
    /// wrote for this step.
    private func follow(
        _ handle: TaskHandle,
        response: JSONValue?,
        index: Int,
        timeout: Double,
        afterSeq: EventSeq = .start,
        earlier: [JSONValue] = [],
        output: ConsoleOutput,
    ) async -> ConsoleStepResult {
        var result = ConsoleStepResult(ok: true, response: response)
        let service = service
        let reader = Task { () -> ([JSONValue], String?, Error?) in
            var events = earlier
            var state = earlier.last {
                $0["kind"]?.stringValue == TaskEvent.stateKind
            }?["payload"]?["state"]?.stringValue
            do {
                for try await event in service.events(of: handle, afterSeq: afterSeq) {
                    let json = (try? JSONValue(encoding: event)) ?? .null
                    events.append(json)
                    output.write("step.event", [
                        "index": .number(Double(index)),
                        "taskID": .string(handle.taskID.rawValue),
                        "event": json,
                    ])
                    if event.kind == TaskEvent.stateKind, let name = event.payload?["state"]?.stringValue {
                        state = name
                    }
                }
                return (events, state, nil)
            } catch {
                return (events, state, error)
            }
        }
        // Answers whether it fired. Cancelled once the reader is done, it
        // returns without touching the reader: a woken sleep that went on to
        // cancel it anyway turned a task that had ended `succeeded` into a
        // timeout whenever it ran before `isCancelled` was read (i1-smoke on
        // the iOS 27 iPad vphone, 2026-10-18).
        let watchdog = Task { () -> Bool in
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch {
                return false
            }
            reader.cancel()
            return true
        }
        let (events, state, error) = await reader.value
        watchdog.cancel()
        let timedOut = await watchdog.value

        result.events = events
        result.state = state
        if timedOut {
            result.ok = false
            result.error = .object([
                "code": .string("timeout"),
                "message": .string("the task did not finish in \(Int(timeout)) s"),
            ])
        } else if let error {
            result.ok = false
            result.error = Self.errorJSON(error)
        } else if let state, state != TaskState.succeeded.rawValue {
            result.ok = false
            result.error = .object(["code": .string("taskEnded"), "message": .string("the task ended \(state)")])
        }
        return result
    }

    // MARK: Resuming after the app went away

    /// A script left in `running/` by an earlier launch is picked up again
    /// in two cases, into the same output with a `run.resumed` line, the
    /// earlier steps' results read back from that output so `${…}` and
    /// `expect` still see them:
    ///
    /// - its output stops in the middle of following a task (a `step.task`
    ///   line and no `step.result` for that step): the console attaches to
    ///   that task again after the last event it wrote, writes the rest of
    ///   its events, finishes the step and goes on. A task outlives the app,
    ///   so a step whose task resprings (or the user killing the app) loses
    ///   nothing;
    /// - its output stops right after a `respring` that succeeded: SpringBoard
    ///   takes every app down with it, so the run goes on at the step after.
    ///   The run waits `respringPause` after the respring before it starts
    ///   the next step, so the app goes down with the respring last.
    ///   Only once: no later step may have started, and no earlier launch may
    ///   have resumed from it already, or a step (or a panic, or a reboot)
    ///   that keeps taking the app down would be run again at every launch.
    ///
    /// Any other script left in `running/` was interrupted (the app was
    /// killed or crashed outside a task); its run is ended as failed and the
    /// script moved to `done/`.
    public func resumeInterrupted() async {
        prepareFolders()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.consoleRunning.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        for name in names {
            let scriptURL = folder.consoleRunning.appendingPathComponent(name)
            // `<runID>-<script name>`; a runID is yyyyMMdd-HHmmss-xxxxxx.
            let runID = String(name.prefix(Self.runIDLength))
            guard runID.count == Self.runIDLength, !activeRuns.contains(runID) else { continue }
            let outURL = folder.consoleOut.appendingPathComponent("\(runID).jsonl")
            let lines = Self.readLines(outURL)
            let done = folder.consoleDone.appendingPathComponent(name)
            guard !lines.contains(where: { $0["type"]?.stringValue == "run.end" }) else {
                try? FileManager.default.moveItem(at: scriptURL, to: done)
                continue
            }

            activeRuns.insert(runID)
            let output = ConsoleOutput(url: outURL, runID: runID, log: log, append: true)
            let replay = Self.replay(lines)
            let script = FileManager.default.contents(atPath: scriptURL.path)
                .flatMap { try? JSONCoding.decode(ConsoleScript.self, from: $0) }
            let failedStep: Int?
            do {
                if let script, let following = replay.following, script.steps.indices.contains(following.index) {
                    failedStep = try await resumeFollowing(following, script: script, replay: replay, output: output)
                } else if let script, let last = replay.lastResult, last.op == "respring", last.result.ok,
                          replay.lastStarted == last.index, !replay.resumedAfterLastResult
                {
                    output.write("run.resumed", ["fromStep": .number(Double(last.index + 1))])
                    failedStep = try await runSteps(
                        script.steps,
                        from: last.index + 1,
                        results: replay.results,
                        previous: last.result,
                        output: output,
                    )
                } else {
                    let lastStep = replay.lastStarted.map { JSONValue.number(Double($0)) } ?? .null
                    output.write("run.interrupted", ["lastStep": lastStep])
                    failedStep = replay.lastStarted ?? -1
                }
            } catch {
                // Cancelled while waiting for a respring: left in `running/`.
                output.close()
                activeRuns.remove(runID)
                return
            }
            end(output, failedStep: failedStep)
            activeRuns.remove(runID)
            try? FileManager.default.moveItem(at: scriptURL, to: done)
        }
    }

    /// Finishes the step whose task an earlier launch was following, then
    /// runs the rest of the script.
    private func resumeFollowing(
        _ following: Replay.Following,
        script: ConsoleScript,
        replay: Replay,
        output: ConsoleOutput,
    ) async throws -> Int? {
        let step = script.steps[following.index]
        let afterSeq = following.events.compactMap { $0["seq"]?.doubleValue }.max()
            .map { EventSeq(UInt64($0)) } ?? .start
        output.write("run.resumed", [
            "fromStep": .number(Double(following.index)),
            "taskID": .string(following.handle.taskID.rawValue),
            "afterSeq": .number(Double(afterSeq.rawValue)),
        ])
        let started = Date()
        let result = await follow(
            following.handle,
            response: following.response,
            index: following.index,
            timeout: step.timeoutSeconds ?? Self.defaultTimeout,
            afterSeq: afterSeq,
            earlier: following.events,
            output: output,
        )
        Self.writeResult(result, header: Self.header(step, index: following.index), started: started, output: output)
        if !result.ok, step.allowError != true {
            return following.index
        }
        var results = replay.results
        if let label = step.label {
            results[label] = result
        }
        return try await runSteps(
            script.steps,
            from: following.index + 1,
            results: results,
            previous: result,
            output: output,
        )
    }

    private static func readLines(_ url: URL) -> [JSONValue] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONCoding.decode(JSONValue.self, from: Data($0)) }
    }

    // MARK: Helpers

    private static func header(_ step: ConsoleStep, index: Int) -> [String: JSONValue] {
        var header: [String: JSONValue] = ["index": .number(Double(index)), "op": .string(step.op)]
        if let label = step.label {
            header["label"] = .string(label)
        }
        return header
    }

    private static func writeResult(
        _ result: ConsoleStepResult,
        header: [String: JSONValue],
        started: Date,
        output: ConsoleOutput,
    ) {
        var line = header
        line["ok"] = .bool(result.ok)
        line["durationMs"] = .number((Date().timeIntervalSince(started) * 1000).rounded())
        if let response = result.response {
            line["response"] = response
        }
        if let error = result.error {
            line["error"] = error
        }
        if let state = result.state {
            line["state"] = .string(state)
        }
        output.write("step.result", line)
    }

    private func end(_ output: ConsoleOutput, failedStep: Int?) {
        var end: [String: JSONValue] = ["ok": .bool(failedStep == nil)]
        if let failedStep, failedStep >= 0 {
            end["failedStep"] = .number(Double(failedStep))
        }
        output.write("run.end", end)
        output.close()
    }

    /// A response that is a task handle — followed unless the step says
    /// `follow: false` — or one that carries a handle as `task` (an agent
    /// session, a terminal), followed only when the step says `follow: true`:
    /// those run until closed.
    private static func taskHandle(in response: JSONValue, nested: Bool) -> TaskHandle? {
        if let handle = try? response.decode(TaskHandle.self) {
            return handle
        }
        if nested, let inner = response["task"], let handle = try? inner.decode(TaskHandle.self) {
            return handle
        }
        return nil
    }

    /// The kind of task an attach operation reads, for following its batch.
    private static func attachedKind(_ operation: AppOperation) -> TaskKind? {
        switch operation {
        case .environmentAttach: .environment
        case .buildAttach: .build
        case .agentAttach: .agent
        case .ptyAttach: .terminal
        case .logStream: .logStream
        case .confirmLoadedAttach: .confirmLoaded
        default: nil
        }
    }

    private static func check(_ expectation: ConsoleExpectation, against subject: ConsoleStepResult) -> String? {
        if let ok = expectation.ok, ok != subject.ok {
            return "ok is \(subject.ok), expected \(ok)"
        }
        if let code = expectation.errorCode {
            let actual = subject.error?["code"]?.stringValue
            if actual != code {
                return "error code is \(actual ?? "none"), expected \(code)"
            }
        }
        if let state = expectation.state, subject.state != state {
            return "state is \(subject.state ?? "none"), expected \(state)"
        }
        if let path = expectation.path {
            let value = subject.json.value(at: path)
            if let exists = expectation.exists, exists != (value != nil) {
                return "\(path) \(exists ? "is missing" : "exists")"
            }
            if let expected = expectation.equals, value != expected {
                let actual = value.flatMap { try? JSONCoding.encode($0) }
                    .map { String(decoding: $0, as: UTF8.self) } ?? "missing"
                return "\(path) is \(actual)"
            }
        }
        return nil
    }

    private static func errorJSON(_ error: Error) -> JSONValue {
        if let error = error as? ApelinError {
            return .object(["code": .string(error.code.rawValue), "message": .string(error.message)])
        }
        return .object(["code": .string("console"), "message": .string(String(describing: error))])
    }

    /// `makeRunID`'s `yyyyMMdd-HHmmss-xxxxxx`: 15 + 1 + 6 characters.
    private static let runIDLength = 22

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(6).lowercased()
    }

    private func prepareFolders() {
        // The package makes the data folder for mobile; this covers a run
        // without it (the app alone, the Mac harness). The app is mobile,
        // never root.
        try? FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        for url in [folder.consoleInbox, folder.consoleRunning, folder.consoleDone, folder.consoleOut] {
            do {
                try folder.makeLevels(to: url)
            } catch {
                log.problem("cannot prepare \(url.path): \(String(describing: error))")
            }
        }
    }

    private func nextInboxScript() -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.consoleInbox.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().first
            .map { folder.consoleInbox.appendingPathComponent($0) }
    }
}
