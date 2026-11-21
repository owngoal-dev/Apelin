@testable import ApelinConsole
import ApelinCore
import ApelinProtocol
import Foundation
import XCTest

/// The console against a fake transport, in a data folder of its own: what
/// a device run does, without apelind.
final class ConsoleRunnerTests: XCTestCase {
    private var folder: DataFolder!
    private var fake: FakeTransport!
    private var runner: ConsoleRunner!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-console-\(UUID().uuidString)", isDirectory: true)
        folder = DataFolder(root: base.appendingPathComponent(DataFolder.bundleIdentifier, isDirectory: true))
        try FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        fake = FakeTransport()
        runner = makeRunner(fake)
    }

    /// A runner over this test's folder. No wait after a respring unless a
    /// test asks for one.
    private func makeRunner(_ transport: FakeTransport, respringPause: TimeInterval = 0) -> ConsoleRunner {
        ConsoleRunner(
            service: ApelinService(transport: transport),
            folder: folder,
            log: RecordingLog(),
            respringPause: respringPause,
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder.root.deletingLastPathComponent())
    }

    // MARK: Steps

    func testReferencesAreReplacedBeforeAStepRuns() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        fake.reply(.projectCreate, with: ProjectCreateResponse(projectID: "p1", name: "Hello", path: "/p"))
        fake.reply(.gitCommit, with: GitCommitResponse(commitID: "c1"))
        let runID = try await runInbox("""
        {"name": "refs", "steps": [
          {"op": "hello", "label": "hello"},
          {"op": "projectCreate", "label": "project", "request": {"templateID": "t", "name": "Hello", "values": {}}},
          {"op": "gitCommit", "request": {"projectID": "${project.response.projectID}",
                                          "message": "at ${hello.response.installRoot}, v${hello.response.protocolVersion}"}},
          {"op": "ptyResize", "request": {"sessionID": "s", "columns": "${hello.response.protocolVersion}", "rows": 24}},
          {"op": "expect", "request": {"step": "project", "path": "response.name", "equals": "Hello"}}
        ]}
        """)
        let lines = output(runID)
        XCTAssertEqual(types(lines), ["run.start", "run.name", "step.start", "step.result", "step.start", "step.result",
                                      "step.start", "step.result", "step.start", "step.result", "step.start", "step.result", "run.end"])
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        let commit = try XCTUnwrap(fake.calls.first { $0.operation == .gitCommit })
        XCTAssertEqual(commit.payload["projectID"], .string("p1"))
        XCTAssertEqual(commit.payload["message"], .string("at /var/jb, v2"))
        // A string that is only a reference becomes the value: a number.
        XCTAssertEqual(fake.calls.first { $0.operation == .ptyResize }?.payload["columns"], .number(2))
    }

    func testSubstitutionRefusesWhatItCannotFind() {
        let results = ["a": ConsoleStepResult(ok: true, response: .object(["x": .number(1)]))]
        XCTAssertEqual(try ConsoleSubstitution.apply(.string("${a.response.x}"), results: results), .number(1))
        XCTAssertEqual(try ConsoleSubstitution.apply(.array([.string("n=${a.response.x}")]), results: results), .array([.string("n=1")]))
        XCTAssertEqual(try ConsoleSubstitution.apply(.string("${a.ok}"), results: results), .bool(true))
        XCTAssertThrowsError(try ConsoleSubstitution.apply(.string("${b.response}"), results: results))
        XCTAssertThrowsError(try ConsoleSubstitution.apply(.string("${a.response.y}"), results: results))
        XCTAssertThrowsError(try ConsoleSubstitution.apply(.string("x ${a.ok"), results: results))
        XCTAssertTrue(ConsoleSubstitution.hasReference(.object(["k": .array([.string("${a}")])])))
        XCTAssertFalse(ConsoleSubstitution.hasReference(.object(["k": .string("$a")])))
    }

    func testExpectFailsTheRunWithExpectationFailed() async throws {
        fake.fail(.sdkRemove, ApelinError(.notFound, "no such SDK"))
        let runID = try await runInbox("""
        [
          {"op": "sdkRemove", "label": "remove", "request": {"id": "x"}, "allowError": true},
          {"op": "expect", "request": {"errorCode": "notFound"}},
          {"op": "expect", "request": {"step": "remove", "ok": false}},
          {"op": "expect", "request": {"step": "remove", "errorCode": "denied"}},
          {"op": "hello"}
        ]
        """)
        let lines = output(runID)
        let results = lines.filter { $0["type"] == .string("step.result") }
        XCTAssertEqual(results.map { $0["ok"] }, [.bool(false), .bool(true), .bool(true), .bool(false)])
        XCTAssertEqual(results[3]["error"]?["code"], .string("expectationFailed"))
        XCTAssertEqual(lines.last?["ok"], .bool(false))
        XCTAssertEqual(lines.last?["failedStep"], .number(3))
        XCTAssertEqual(fake.operations, [.sdkRemove], "nothing runs after the failed step")
    }

    func testAnErrorEndsTheRunUnlessAllowed() async throws {
        fake.fail(.toolchainStatus, ApelinError(.unavailable, "no worker"))
        let runID = try await runInbox("""
        [{"op": "toolchainStatus"}, {"op": "hello"}]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.first { $0["type"] == .string("step.result") }?["error"]?["code"], .string("unavailable"))
        XCTAssertEqual(lines.last?["failedStep"], .number(0))
        XCTAssertEqual(fake.operations, [.toolchainStatus])
    }

    func testUnknownOperationAndBadRequestFailTheStep() async throws {
        let runID = try await runInbox("""
        [
          {"op": "format", "allowError": true},
          {"op": "expect", "request": {"errorCode": "unknownOperation"}},
          {"op": "sdkRemove", "request": {}, "allowError": true},
          {"op": "expect", "request": {"errorCode": "badRequest"}}
        ]
        """)
        XCTAssertEqual(output(runID).last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [], "a request that does not decode never goes out")
    }

    func testAPIConfigurationCannotBeReadIntoConsoleOutputOrLogs() async throws {
        let secret = "test-key-that-must-not-be-read"
        fake.reply(.agentAPIConfiguration, with: AgentAPIConfigurationResponse(values: ["apiKey": secret]))
        let log = RecordingLog()
        runner = ConsoleRunner(service: ApelinService(transport: fake), folder: folder, log: log)
        let runID = try await runInbox("""
        [{"op": "agentAPIConfiguration", "request": {"provider": "anthropic"}}]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.first { $0["type"] == .string("step.result") }?["error"]?["code"], .string("denied"))
        XCTAssertEqual(fake.operations, [], "the key is never requested")
        XCTAssertFalse(String(describing: lines).contains(secret))
        XCTAssertFalse(log.lines.joined().contains(secret))
    }

    /// The device passcode is typed by a person in Settings, and its test
    /// locks the device: a script never sends one, and the passcode never
    /// reaches the output or the log. Reading the state goes out.
    func testConsoleNeverSavesTheDevicePasscode() async throws {
        let passcode = "147258-not-sent"
        fake.reply(.devicePasscodeState, with: DevicePasscodeState(saved: false, device: .passcode))
        let log = RecordingLog()
        runner = ConsoleRunner(service: ApelinService(transport: fake), folder: folder, log: log)
        let runID = try await runInbox("""
        [{"op": "devicePasscodeSave", "allowError": true, "label": "save", "request": {"passcode": "\(passcode)"}},
         {"op": "expect", "request": {"step": "save", "errorCode": "denied"}},
         {"op": "devicePasscodeState", "label": "state"},
         {"op": "expect", "request": {"step": "state", "path": "response.saved", "equals": false}}]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.devicePasscodeState], "the passcode never goes out")
        XCTAssertFalse(String(describing: lines).contains(passcode))
        XCTAssertFalse(log.lines.joined().contains(passcode))
    }

    /// A star is given on the reader's GitHub account by their own tap in
    /// the app, so a script cannot give one; reading whether there is one
    /// goes out.
    func testConsoleNeverStarsApelin() async throws {
        fake.reply(.feedbackStarState, with: FeedbackStarResponse(repository: FeedbackRules.repository, starred: false))
        let runID = try await runInbox("""
        [{"op": "feedbackStar", "allowError": true, "label": "star"},
         {"op": "expect", "request": {"step": "star", "errorCode": "denied"}},
         {"op": "feedbackStarState", "label": "state"},
         {"op": "expect", "request": {"step": "state", "path": "response.starred", "equals": false}}]
        """)
        XCTAssertEqual(output(runID).last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.feedbackStarState], "the star never goes out")
    }

    /// Full mode runs a command as root without asking; a human turns it on
    /// in the app after the device-owner check. A script file cannot stand
    /// in for that, so the console refuses to set it on an open or a prompt,
    /// before the request goes out.
    func testConsoleCannotPutASessionIntoFullMode() async throws {
        var runID = try await runInbox("""
        [{"op": "agentOpen", "allowError": true,
          "request": {"projectName": "Demo", "approvalMode": "full", "prompt": "install the dependency"}}]
        """)
        XCTAssertEqual(
            output(runID).first { $0["type"] == .string("step.result") }?["error"]?["code"],
            .string("denied"),
        )
        XCTAssertEqual(fake.operations, [], "a Full open never goes out")

        runID = try await runInbox("""
        [{"op": "agentPrompt", "allowError": true,
          "request": {"sessionID": "s", "text": "run as root", "approvalMode": "full"}}]
        """)
        XCTAssertEqual(
            output(runID).first { $0["type"] == .string("step.result") }?["error"]?["code"],
            .string("denied"),
        )
        XCTAssertEqual(fake.operations, [], "a Full prompt never goes out")
    }

    /// The owner mark says the app checked the device owner for a decision,
    /// which the host requires to approve a command as root. A script never
    /// sends it, true or false; an approval without it still goes out.
    func testConsoleNeverSendsTheOwnerMark() async throws {
        for mark in ["true", "false"] {
            let runID = try await runInbox("""
            [{"op": "agentApprove", "allowError": true,
              "request": {"sessionID": "s", "approvalID": "a", "decision": "approve", "ownerVerified": \(mark)}}]
            """)
            XCTAssertEqual(
                output(runID).first { $0["type"] == .string("step.result") }?["error"]?["code"],
                .string("denied"),
                "ownerVerified \(mark) is refused",
            )
        }
        XCTAssertEqual(fake.operations, [], "an approval with the owner mark never goes out")

        let runID = try await runInbox("""
        [{"op": "agentApprove", "request": {"sessionID": "s", "approvalID": "a", "decision": "approve"}}]
        """)
        XCTAssertEqual(output(runID).last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.agentApprove])
        XCTAssertNil(fake.calls.first?.payload["ownerVerified"], "and carries no owner mark")
    }

    /// Strict and Relaxed opens still go through: only Full is refused.
    func testConsoleStillOpensInStrictAndRelaxed() async throws {
        fake.reply(.agentOpen, with: AgentOpenResponse(
            sessionID: "11111111-2222-4333-8444-555555555555",
            task: TaskHandle(taskID: TaskID("t1"), kind: .agent),
        ))
        for mode in ["confirm", "relaxed"] {
            let runID = try await runInbox("""
            [{"op": "agentOpen", "follow": false,
              "request": {"projectName": "Demo", "approvalMode": "\(mode)", "prompt": "x"}}]
            """)
            XCTAssertEqual(output(runID).last?["ok"], .bool(true), "\(mode) opens")
        }
        XCTAssertEqual(fake.operations, [.agentOpen, .agentOpen])
    }

    // MARK: Following tasks

    func testATaskIsFollowedToItsEnd() async throws {
        fake.reply(.buildStart, with: TaskHandle(taskID: TaskID("b1"), kind: .build))
        fake.task("b1", events: [.log(1, "compile"), .log(2, "sign"), .state(3, .succeeded)], state: .succeeded)
        let runID = try await runInbox("""
        [
          {"op": "buildStart", "label": "build", "request": {"projectID": "p", "configuration": "debug"}},
          {"op": "expect", "request": {"step": "build", "state": "succeeded"}},
          {"op": "expect", "request": {"step": "build", "path": "events.1.payload.line", "equals": "sign"}},
          {"op": "expect", "request": {"step": "build", "path": "lastEvent.payload.state", "equals": "succeeded"}},
          {"op": "expect", "request": {"step": "build", "path": "response.taskID", "equals": "b1"}}
        ]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        let task = try XCTUnwrap(lines.first { $0["type"] == .string("step.task") })
        XCTAssertEqual(task["index"], .number(0))
        XCTAssertEqual(task["taskID"], .string("b1"))
        XCTAssertEqual(task["kind"], .string("build"))
        XCTAssertEqual(task["response"]?["taskID"], .string("b1"))
        XCTAssertEqual(lines.filter { $0["type"] == .string("step.event") }.compactMap { $0["event"]?["seq"] }, [.number(1), .number(2), .number(3)])
        XCTAssertEqual(fake.operations, [.buildStart, .buildAttach])
        // step.task comes before the first event.
        XCTAssertLessThan(try XCTUnwrap(types(lines).firstIndex(of: "step.task")), try XCTUnwrap(types(lines).firstIndex(of: "step.event")))
    }

    func testATaskThatFailsFailsItsStep() async throws {
        fake.reply(.sdkImport, with: TaskHandle(taskID: TaskID("e1"), kind: .environment))
        fake.task("e1", events: [.state(1, .failed)], state: .failed)
        let runID = try await runInbox("""
        [{"op": "sdkImport", "request": {"source": {"inbox": {"path": "x"}}}}, {"op": "hello"}]
        """)
        let lines = output(runID)
        let result = try XCTUnwrap(lines.first { $0["type"] == .string("step.result") })
        XCTAssertEqual(result["state"], .string("failed"))
        XCTAssertEqual(result["error"]?["code"], .string("taskEnded"))
        XCTAssertEqual(lines.last?["failedStep"], .number(0))
        XCTAssertEqual(fake.operations, [.sdkImport, .environmentAttach])
    }

    func testFollowFalseAndNestedHandles() async throws {
        fake.reply(.buildStart, with: TaskHandle(taskID: TaskID("b1"), kind: .build))
        fake.reply(.ptyOpen, with: PtyOpenResponse(sessionID: "s1", task: TaskHandle(taskID: TaskID("t1"), kind: .terminal)))
        fake.reply(.agentOpen, with: AgentOpenResponse(sessionID: "a1", task: TaskHandle(taskID: TaskID("a1"), kind: .agent)))
        fake.task("t1", events: [.log(1, "$ "), .state(2, .succeeded)], state: .succeeded)
        let runID = try await runInbox("""
        [
          {"op": "buildStart", "request": {"projectID": "p", "configuration": "debug"}, "follow": false},
          {"op": "agentOpen", "request": {"approvalMode": "relaxed"}},
          {"op": "ptyOpen", "label": "pty", "request": {}, "follow": true},
          {"op": "expect", "request": {"step": "pty", "path": "events.0.seq", "equals": 1}}
        ]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        // Only the terminal was followed: the build was told not to be, and
        // a nested handle is followed only on request.
        XCTAssertEqual(fake.operations, [.buildStart, .agentOpen, .ptyOpen, .ptyAttach])
        XCTAssertEqual(lines.filter { $0["type"] == .string("step.task") }.map { $0["index"] }, [.number(2)])
    }

    /// An attach by task ID is read on from its batch until the task ends.
    func testAnAttachIsFollowedFromItsBatch() async throws {
        let events: [TaskEvent] = [.log(1, "compile"), .log(2, "sign"), .log(3, "package"), .state(4, .succeeded)]
        fake.task("b1", events: events, state: .succeeded, firstBatch: 2)
        let runID = try await runInbox("""
        [
          {"op": "buildAttach", "label": "read", "request": {"taskID": "b1", "afterSeq": 0, "waitMilliseconds": 1000}},
          {"op": "expect", "request": {"step": "read", "state": "succeeded"}},
          {"op": "expect", "request": {"step": "read", "path": "events.3.kind", "equals": "state"}},
          {"op": "expect", "request": {"step": "read", "path": "response.lastSeq", "equals": 2}}
        ]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.buildAttach, .buildAttach])
        XCTAssertEqual(fake.calls.last?.payload["afterSeq"], .number(2), "read on from the batch's lastSeq")
        XCTAssertEqual(lines.first { $0["type"] == .string("step.task") }?["kind"], .string("build"))
        XCTAssertEqual(lines.filter { $0["type"] == .string("step.event") }.compactMap { $0["event"]?["seq"] },
                       [.number(1), .number(2), .number(3), .number(4)])
    }

    /// A load check picked up by ID — after the respring it triggered took
    /// the app down — is read on to its answer like any other attach.
    func testAnUnfinishedLoadCheckAttachIsFollowed() async throws {
        let events: [TaskEvent] = [.log(1, "listening"), .log(2, "trigger"), .state(3, .succeeded)]
        fake.task("c1", events: events, state: .succeeded, firstBatch: 1)
        let runID = try await runInbox("""
        [
          {"op": "confirmLoadedAttach", "label": "read", "request": {"taskID": "c1", "afterSeq": 0, "waitMilliseconds": 1000}},
          {"op": "expect", "request": {"step": "read", "state": "succeeded"}},
          {"op": "expect", "request": {"step": "read", "path": "events.2.kind", "equals": "state"}}
        ]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.confirmLoadedAttach, .confirmLoadedAttach])
        XCTAssertEqual(fake.calls.last?.payload["afterSeq"], .number(1), "read on from the batch's lastSeq")
        XCTAssertEqual(lines.first { $0["type"] == .string("step.task") }?["kind"], .string("confirmLoaded"))
    }

    func testAFinishedBatchIsTheStepsEventsAndState() async throws {
        fake.task("e1", events: [.log(1, "fetch"), .state(2, .failed)], state: .failed)
        let runID = try await runInbox("""
        [
          {"op": "environmentAttach", "label": "read", "allowError": true, "request": {"taskID": "e1", "afterSeq": 0, "waitMilliseconds": 0}},
          {"op": "expect", "request": {"step": "read", "state": "failed"}},
          {"op": "expect", "request": {"step": "read", "errorCode": "taskEnded"}},
          {"op": "environmentAttach", "label": "plain", "follow": false, "request": {"taskID": "e1", "afterSeq": 0, "waitMilliseconds": 0}},
          {"op": "expect", "request": {"step": "plain", "path": "events", "equals": []}},
          {"op": "expect", "request": {"step": "plain", "path": "response.state", "equals": "failed"}}
        ]
        """)
        let lines = output(runID)
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(fake.operations, [.environmentAttach, .environmentAttach], "a finished batch is not attached again")
        XCTAssertNil(lines.first { $0["type"] == .string("step.task") }, "nothing to re-attach to")
        XCTAssertEqual(lines.filter { $0["type"] == .string("step.event") }.count, 2)
    }

    func testAnAttachFollowedWhenTheAppDiedResumesToo() async throws {
        let events: [TaskEvent] = [.log(1, "a"), .log(2, "b"), .log(3, "c"), .state(4, .succeeded)]
        fake.task("a1", events: events, state: .succeeded, firstBatch: 1)
        var seen = 0
        let runID = try await runThenCut("""
        [{"op": "agentAttach", "label": "read", "request": {"taskID": "a1", "afterSeq": 0, "waitMilliseconds": 1000}}]
        """) { line in
            guard line["type"] == .string("step.event") else { return false }
            seen += 1
            return seen == 3
        }
        let next = relaunch()
        next.task("a1", events: events, state: .succeeded)
        await runner.resumeInterrupted()
        XCTAssertEqual(next.operations, [.agentAttach])
        XCTAssertEqual(next.calls.first?.payload["afterSeq"], .number(3))
        XCTAssertEqual(output(runID).last?["ok"], .bool(true))
    }

    func testAFollowThatOutlastsItsTimeoutFails() async throws {
        fake.reply(.buildStart, with: TaskHandle(taskID: TaskID("b1"), kind: .build))
        fake.task("b1", events: [.log(1, "compile")], state: .running)
        let runID = try await runInbox("""
        [{"op": "buildStart", "request": {"projectID": "p", "configuration": "debug"}, "timeoutSeconds": 0.2}]
        """)
        let result = try XCTUnwrap(output(runID).first { $0["type"] == .string("step.result") })
        XCTAssertEqual(result["error"]?["code"], .string("timeout"))
    }

    /// A task that ends is never a timeout. The race this guards (a
    /// cancelled watchdog cancelling the finished reader before the runner
    /// looked) showed on the iOS 27 iPad vphone and never in this loop on a
    /// Mac; the runner now asks the watchdog whether it fired, so it cannot.
    func testAFollowThatEndsIsNeverATimeout() async throws {
        fake.reply(.buildStart, with: TaskHandle(taskID: TaskID("b1"), kind: .build))
        fake.task("b1", events: [.log(1, "compile"), .state(2, .succeeded)], state: .succeeded)
        let step = #"{"op": "buildStart", "request": {"projectID": "p", "configuration": "debug"}, "timeoutSeconds": 60}"#
        let runID = try await runInbox("[" + Array(repeating: step, count: 200).joined(separator: ",") + "]")
        let results = output(runID).filter { $0["type"] == .string("step.result") }
        XCTAssertEqual(results.count, 200)
        XCTAssertEqual(results.filter { $0["ok"] != .bool(true) }.map { $0["error"] }, [])
    }

    // MARK: Inbox and launch

    func testTheInboxIsClaimedRunInNameOrderAndMovedToDone() async throws {
        try drop("[{\"op\": \"hello\"}]", as: "b.json")
        try drop("[{\"op\": \"toolchainStatus\"}]", as: "a.json")
        try drop("[{\"op\": \"sdkList\"}]", as: ".c.json")
        try drop("not json", as: "d.json")
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        fake.reply(.toolchainStatus, with: ToolchainStatusResponse())
        await runner.drainInbox()

        // Name order: a before b.
        XCTAssertEqual(fake.operations, [.toolchainStatus, .hello])
        XCTAssertEqual(try names(folder.consoleInbox), [".c.json"])
        XCTAssertEqual(try names(folder.consoleRunning), [])
        // `<runID>-<name>`.
        let done = try names(folder.consoleDone)
        XCTAssertEqual(Set(done.map { String($0.dropFirst(23)) }), ["a.json", "b.json", "d.json"])

        let invalid = try output(String(XCTUnwrap(done.first { $0.hasSuffix("d.json") }).prefix(22)))
        XCTAssertEqual(types(invalid), ["run.start", "run.invalid", "run.end"])
        XCTAssertEqual(invalid.last?["ok"], .bool(false))
        XCTAssertNil(invalid.last?["failedStep"])
    }

    func testTheLaunchArgumentRunsAScriptInPlace() async throws {
        try FileManager.default.createDirectory(at: folder.console, withIntermediateDirectories: true)
        let script = folder.console.appendingPathComponent("launch.json")
        try Data("[{\"op\": \"hello\"}]".utf8).write(to: script)
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        await runner.runLaunchScript(arguments: ["Apelin", ConsoleRunner.launchArgument, "launch.json"])
        XCTAssertEqual(fake.operations, [.hello])
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "the file is left where it is")
        let out = try names(folder.consoleOut)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(output(String(out[0].prefix(22))).last?["ok"], .bool(true))
    }

    // MARK: Resuming

    /// Run a script through the inbox, then put things back the way a launch
    /// that died at `cut` would have left them: the script in `running/`,
    /// its output ending at the first line `cut` matches.
    private func runThenCut(_ script: String, cut: (JSONValue) -> Bool) async throws -> String {
        let runID = try await runInbox(script)
        let name = try XCTUnwrap(try names(folder.consoleDone).first { $0.hasPrefix(runID) })
        try FileManager.default.moveItem(at: folder.consoleDone.appendingPathComponent(name), to: folder.consoleRunning.appendingPathComponent(name))
        let url = folder.consoleOut.appendingPathComponent("\(runID).jsonl")
        let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        let end = try XCTUnwrap(raw.firstIndex { cut((try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8))) ?? .null) })
        try (raw[...end].joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return runID
    }

    /// The next launch: a new runner and a new transport over the same folder.
    private func relaunch() -> FakeTransport {
        let next = FakeTransport()
        runner = makeRunner(next)
        return next
    }

    /// Polls the run outputs until a line matches, and answers the runID of
    /// the output it is in.
    private func waitForLine(
        timeout: TimeInterval = 5,
        _ matches: (JSONValue) -> Bool,
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let files = (try? names(folder.consoleOut)) ?? []
            for file in files where file.hasSuffix(".jsonl") {
                let runID = String(file.dropLast(".jsonl".count))
                if output(runID).contains(where: matches) {
                    return runID
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ConsoleFailure("no matching line in \(timeout) s")
    }

    private static func isRespringResult(_ line: JSONValue) -> Bool {
        line["type"] == .string("step.result") && line["op"] == .string("respring")
    }

    /// What the device does: `respring` answers ok in tens of milliseconds and
    /// SpringBoard takes the app down a moment later. The runner waits after
    /// the respring, so the kill (the run's task cancelled) leaves the output
    /// ending at the respring's `step.result`, and the next launch goes on at
    /// the step after it.
    func testARespringThatTakesTheAppDownResumesAtTheNextStep() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        runner = makeRunner(fake, respringPause: 60)
        try drop("""
        [
          {"op": "hello", "label": "hello"},
          {"op": "respring", "label": "respring"},
          {"op": "gitStatus", "request": {"projectID": "${hello.response.installRoot}"}},
          {"op": "expect", "request": {"step": "respring", "ok": true}}
        ]
        """, as: "script.json")
        let killedRunner = try XCTUnwrap(runner)
        let run = Task { await killedRunner.drainInbox() }
        let runID = try await waitForLine(Self.isRespringResult)
        run.cancel()
        await run.value

        let killed = output(runID)
        XCTAssertTrue(try Self.isRespringResult(XCTUnwrap(killed.last)), "nothing after the respring's result")
        XCTAssertEqual(try names(folder.consoleRunning).count, 1, "the script stays claimed, as after a kill")

        let next = relaunch()
        next.reply(.gitStatus, with: GitStatusResponse())
        await runner.resumeInterrupted()

        let lines = output(runID)
        XCTAssertEqual(lines.first { $0["type"] == .string("run.resumed") }?["fromStep"], .number(2))
        XCTAssertFalse(types(lines).contains("run.interrupted"))
        XCTAssertEqual(next.operations, [.gitStatus])
        XCTAssertEqual(next.calls.first?.payload["projectID"], .string("/var/jb"))
        XCTAssertEqual(lines.last?["type"], .string("run.end"))
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(try names(folder.consoleRunning), [])
    }

    /// After a respring that succeeded the next step does not start at once:
    /// the run waits the pause, then notes that the app survived and goes on.
    func testTheNextStepWaitsForTheRespringPause() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        let pause: TimeInterval = 1
        runner = makeRunner(fake, respringPause: pause)
        try drop("[{\"op\": \"respring\"}, {\"op\": \"hello\"}]", as: "script.json")
        let pausedRunner = try XCTUnwrap(runner)
        let run = Task { await pausedRunner.drainInbox() }
        let runID = try await waitForLine(Self.isRespringResult)
        let answered = Date()
        try await Task.sleep(nanoseconds: UInt64(pause / 2 * 1_000_000_000))
        let early = output(runID)
        XCTAssertTrue(
            try Self.isRespringResult(XCTUnwrap(early.last)),
            "no line may follow the respring within the pause: \(types(early).suffix(3))",
        )
        await run.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(answered), pause * 0.8)

        let lines = output(runID)
        let tail = types(lines).drop { $0 != "step.result" }
        XCTAssertEqual(Array(tail), ["step.result", "step.note", "step.start", "step.result", "run.end"])
        let note = try XCTUnwrap(lines.first { $0["type"] == .string("step.note") })
        XCTAssertEqual(note["index"], .number(0))
        XCTAssertEqual(note["note"], .string("respringSurvived"))
        XCTAssertEqual(fake.operations, [.respring, .hello])
        XCTAssertEqual(lines.last?["ok"], .bool(true))
    }

    /// Only a respring that answered ok waits: a failed one, allowed or not,
    /// goes straight on.
    func testAFailedRespringDoesNotWait() async throws {
        fake.fail(.respring, ApelinError(.unavailable, "no irisind"))
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        runner = makeRunner(fake, respringPause: 30)
        let started = Date()
        let runID = try await runInbox("""
        [{"op": "respring", "allowError": true}, {"op": "hello"}, {"op": "respring"}, {"op": "hello"}]
        """)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let lines = output(runID)
        XCTAssertFalse(types(lines).contains("step.note"))
        XCTAssertEqual(fake.operations, [.respring, .hello, .respring])
        XCTAssertEqual(lines.last?["failedStep"], .number(2))
    }

    func testARunGoesOnAfterARespringThatSucceeded() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        let runID = try await runThenCut("""
        [
          {"op": "hello", "label": "hello"},
          {"op": "respring", "label": "respring"},
          {"op": "gitStatus", "request": {"projectID": "${hello.response.installRoot}"}, "allowError": true},
          {"op": "expect", "request": {"step": "respring", "ok": true}}
        ]
        """) { $0["type"] == .string("step.result") && $0["op"] == .string("respring") }

        let next = relaunch()
        next.reply(.gitStatus, with: GitStatusResponse())
        await runner.resumeInterrupted()

        let lines = output(runID)
        let resumed = try XCTUnwrap(lines.first { $0["type"] == .string("run.resumed") })
        XCTAssertEqual(resumed["fromStep"], .number(2))
        XCTAssertEqual(next.operations, [.gitStatus])
        XCTAssertEqual(next.calls.first?.payload["projectID"], .string("/var/jb"), "earlier results are read back")
        XCTAssertEqual(lines.last?["type"], .string("run.end"))
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(try names(folder.consoleRunning), [])
        XCTAssertEqual(try names(folder.consoleDone).count, 1)
    }

    /// A step after the respring started and the app died during it: the run
    /// did not stop right after the respring, so it is not run again from
    /// there — a step that keeps taking the app down would loop.
    func testAStepStartedAfterARespringIsInterruptedNotRerun() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        let runID = try await runThenCut("""
        [
          {"op": "respring"},
          {"op": "hello"},
          {"op": "hello"}
        ]
        """) { $0["type"] == .string("step.start") && $0["index"] == .number(1) }

        let next = relaunch()
        await runner.resumeInterrupted()
        XCTAssertEqual(next.operations, [])
        let lines = output(runID)
        XCTAssertEqual(Array(types(lines).suffix(2)), ["run.interrupted", "run.end"])
        XCTAssertEqual(lines.first { $0["type"] == .string("run.interrupted") }?["lastStep"], .number(1))
        XCTAssertEqual(lines.last?["failedStep"], .number(1))
    }

    /// A resume after a respring that died before its first step started
    /// (a panic, a reboot) is not tried a second time.
    func testARespringResumeIsTriedOnce() async throws {
        let runID = try await runThenCut("""
        [{"op": "respring"}, {"op": "hello"}]
        """) { $0["type"] == .string("step.result") && $0["op"] == .string("respring") }
        let url = folder.consoleOut.appendingPathComponent("\(runID).jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"run.resumed\",\"runID\":\"\(runID)\",\"fromStep\":1}\n".utf8))
        try handle.close()

        let next = relaunch()
        await runner.resumeInterrupted()
        XCTAssertEqual(next.operations, [])
        XCTAssertEqual(Array(types(output(runID)).suffix(2)), ["run.interrupted", "run.end"])
    }

    func testARunMidFollowReattachesAfterTheLastEventWritten() async throws {
        fake.reply(.buildStart, with: TaskHandle(taskID: TaskID("b1"), kind: .build))
        let events: [TaskEvent] = [.log(1, "compile"), .log(2, "sign"), .log(3, "package"), .state(4, .succeeded)]
        fake.task("b1", events: events, state: .succeeded)
        var seen = 0
        let runID = try await runThenCut("""
        [
          {"op": "buildStart", "label": "build", "request": {"projectID": "p", "configuration": "debug"}},
          {"op": "expect", "request": {"step": "build", "path": "events.3.kind", "equals": "state"}},
          {"op": "projectCheck", "request": {"projectID": "${build.events.0.payload.line}"}},
          {"op": "expect", "request": {"path": "response.passed", "equals": true}}
        ]
        """) { line in
            guard line["type"] == .string("step.event") else { return false }
            seen += 1
            return seen == 2
        }

        let next = relaunch()
        next.task("b1", events: events, state: .succeeded)
        next.reply(.projectCheck, with: ProjectCheckResponse(passed: true))
        await runner.resumeInterrupted()

        // No second build: the same task, after seq 2.
        XCTAssertEqual(next.operations, [.buildAttach, .projectCheck])
        XCTAssertEqual(next.calls.first?.payload["taskID"], .string("b1"))
        XCTAssertEqual(next.calls.first?.payload["afterSeq"], .number(2))
        XCTAssertEqual(next.calls.last?.payload["projectID"], .string("compile"), "events from before the relaunch count")

        let lines = output(runID)
        let resumed = try XCTUnwrap(lines.first { $0["type"] == .string("run.resumed") })
        XCTAssertEqual(resumed["fromStep"], .number(0))
        XCTAssertEqual(resumed["taskID"], .string("b1"))
        XCTAssertEqual(resumed["afterSeq"], .number(2))
        XCTAssertEqual(lines.filter { $0["type"] == .string("step.event") }.compactMap { $0["event"]?["seq"] },
                       [.number(1), .number(2), .number(3), .number(4)])
        let result = try XCTUnwrap(lines.first { $0["type"] == .string("step.result") && $0["index"] == .number(0) })
        XCTAssertEqual(result["state"], .string("succeeded"))
        XCTAssertEqual(result["response"]?["taskID"], .string("b1"))
        XCTAssertEqual(lines.last?["ok"], .bool(true))
        XCTAssertEqual(try names(folder.consoleRunning), [])
    }

    /// The respring rule and the mid-follow rule together: a step after a
    /// respring that was following its task when the app died.
    func testAFollowAfterARespringResumesMidFollow() async throws {
        fake.reply(.agentOpen, with: AgentOpenResponse(sessionID: "a1", task: TaskHandle(taskID: TaskID("a1"), kind: .agent)))
        let events: [TaskEvent] = [.log(1, "thinking"), .state(2, .succeeded)]
        fake.task("a1", events: events, state: .succeeded)
        let runID = try await runThenCut("""
        [
          {"op": "respring"},
          {"op": "agentOpen", "label": "agent", "request": {"approvalMode": "relaxed"}, "follow": true}
        ]
        """) { $0["type"] == .string("step.task") }

        let next = relaunch()
        next.task("a1", events: events, state: .succeeded)
        await runner.resumeInterrupted()
        XCTAssertEqual(next.operations, [.agentAttach])
        XCTAssertEqual(next.calls.first?.payload["afterSeq"], .number(0))
        XCTAssertEqual(output(runID).last?["ok"], .bool(true))
    }

    func testARunThatDiedOutsideATaskIsInterrupted() async throws {
        fake.reply(.hello, with: HelloResponse(installRoot: "/var/jb"))
        fake.reply(.sdkList, with: SDKListResponse())
        let runID = try await runThenCut("""
        [{"op": "hello"}, {"op": "sdkList"}, {"op": "hello"}]
        """) { $0["type"] == .string("step.start") && $0["index"] == .number(1) }

        let next = relaunch()
        await runner.resumeInterrupted()
        XCTAssertEqual(next.operations, [])
        let lines = output(runID)
        XCTAssertEqual(Array(types(lines).suffix(2)), ["run.interrupted", "run.end"])
        XCTAssertEqual(lines.first { $0["type"] == .string("run.interrupted") }?["lastStep"], .number(1))
        XCTAssertEqual(lines.last?["ok"], .bool(false))
        XCTAssertEqual(lines.last?["failedStep"], .number(1))
        XCTAssertEqual(try names(folder.consoleRunning), [])
        XCTAssertEqual(try names(folder.consoleDone).count, 1)
    }

    func testAFinishedRunLeftInRunningIsOnlyMoved() async throws {
        let runID = try await runInbox("[{\"op\": \"hello\"}]")
        let name = try XCTUnwrap(try names(folder.consoleDone).first)
        try FileManager.default.moveItem(at: folder.consoleDone.appendingPathComponent(name), to: folder.consoleRunning.appendingPathComponent(name))
        let before = output(runID).count
        let next = relaunch()
        await runner.resumeInterrupted()
        XCTAssertEqual(output(runID).count, before)
        XCTAssertEqual(next.operations, [])
        XCTAssertEqual(try names(folder.consoleDone), [name])
    }

    // MARK: Helpers

    private func drop(_ script: String, as name: String) throws {
        try FileManager.default.createDirectory(at: folder.consoleInbox, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: folder.consoleInbox.appendingPathComponent(name))
    }

    /// Drops one script, drains the inbox and answers the run's ID.
    private func runInbox(_ script: String) async throws -> String {
        try drop(script, as: "script.json")
        await runner.drainInbox()
        let done = try XCTUnwrap(try names(folder.consoleDone).last { $0.hasSuffix("-script.json") })
        return String(done.prefix(22))
    }

    private func output(_ runID: String) -> [JSONValue] {
        guard let data = FileManager.default.contents(atPath: folder.consoleOut.appendingPathComponent("\(runID).jsonl").path) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONCoding.decode(JSONValue.self, from: Data($0)) }
    }

    private func types(_ lines: [JSONValue]) -> [String] {
        lines.compactMap { $0["type"]?.stringValue }
    }

    private func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}
