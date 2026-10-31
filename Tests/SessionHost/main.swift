import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// The session host's macOS-runnable half, compiled with the Apelind sources
// it exercises (Scripts/test-session-host.sh): task records surviving a
// restart, builds and environment tasks started again after one, the
// caller policy, the protected-edit rules on a temporary
// install root, the managed-package rules, the install bridge against a
// fake irisind, the folders a removed toolchain leaves, the approval
// ledger, the deb control reader, the copies a tool call's attachments
// travel as, one agentOpen of a session at a time, the note that the host
// restarted, and a real PTY.

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

var failures = 0
var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ what: String, line: UInt = #line) {
    checks += 1
    if !condition() {
        failures += 1
        print("FAIL \(what) (line \(line))")
    }
}

func expectError(_ what: String, code: ApelinError.Code? = nil, line: UInt = #line, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("FAIL \(what): no error (line \(line))")
    } catch let error as ApelinError {
        if let code, error.code != code {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    } catch {
        if code != nil {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    }
}

@MainActor
func expectErrorAsync(
    _ what: String,
    code: ApelinError.Code? = nil,
    line: UInt = #line,
    _ body: () async throws -> Void,
) async {
    checks += 1
    do {
        try await body()
        failures += 1
        print("FAIL \(what): no error (line \(line))")
    } catch let error as ApelinError {
        if let code, error.code != code {
            failures += 1
            print("FAIL \(what): \(error) (line \(line))")
        }
    } catch {
        failures += 1
        print("FAIL \(what): \(error) (line \(line))")
    }
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-session-host-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }
let scratchPath = CanonicalPath.resolve(scratch.path)!

func write(_ path: String, _ text: String, mode: mode_t = 0o644) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true,
    )
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    chmod(path, mode)
}

func run(_ executable: String, _ arguments: [String], in directory: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    try! process.run()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "\(executable) \(arguments) failed")
}

func sha256(_ path: String) -> String {
    let descriptor = open(path, O_RDONLY)
    defer { close(descriptor) }
    return String(try! ProtectedEditPolicy.sha256(descriptor: descriptor).dropFirst(7))
}

/// A `.deb` with a gzip control member, written by hand as ar; `fields`
/// are more control lines.
func makeDeb(at path: String, package: String, version: String, fields: String = "") {
    let work = scratchPath + "/deb-\(UUID().uuidString)"
    write(
        work + "/control/control",
        "Package: \(package)\nVersion: \(version)\nArchitecture: iphoneos-arm64e\n\(fields)Description: test\n",
    )
    write(work + "/data/usr/share/\(package)/hello", "hello\n")
    run(
        "/usr/bin/tar",
        ["--format", "ustar", "-czf", work + "/control.tar.gz", "-C", work + "/control", "./control"],
        in: work,
    )
    run("/usr/bin/tar", ["--format", "ustar", "-czf", work + "/data.tar.gz", "-C", work + "/data", "."], in: work)
    let archive = arArchive([
        ("debian-binary", Data("2.0\n".utf8)),
        ("control.tar.gz", FileManager.default.contents(atPath: work + "/control.tar.gz")!),
        ("data.tar.gz", FileManager.default.contents(atPath: work + "/data.tar.gz")!),
    ])
    FileManager.default.createFile(atPath: path, contents: archive)
}

/// An ar archive of these members, as a deb is one.
func arArchive(_ members: [(name: String, contents: Data)]) -> Data {
    var archive = Data("!<arch>\n".utf8)
    for (name, contents) in members {
        func field(_ value: String, _ width: Int) -> String {
            value.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        archive.append(Data((field(name + "/", 16) + field("0", 12) + field("0", 6) + field("0", 6)
                + field("100644", 8) + field(String(contents.count), 10) + "`\n").utf8))
        archive.append(contents)
        if contents.count % 2 == 1 {
            archive.append(0x0A)
        }
    }
    return archive
}

// MARK: - Task records persist and resume

do {
    let directory = scratch.appendingPathComponent("tasks")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let resumable = await first.create(kind: .install, owner: nil)
    let plain = await first.create(kind: .build, owner: .build, ownerKey: "b1")
    let done = await first.create(kind: .environment, owner: .environment)
    await first.append(resumable.taskID, kind: "stage", payload: .object(["stage": .string("staged")]))
    await first.setResume(resumable.taskID, .object(["installationID": .string("x")]))
    await first.append(plain.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.finish(done.taskID, .succeeded)
    let counts = await first.activeByKind
    check(counts == ["install": 1, "build": 1], "active tasks counted by kind")

    // A new host on the same directory: what was running comes back.
    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(Set(unfinished.map(\.id)) == [resumable.taskID, plain.taskID], "unfinished tasks are handed back on relaunch")
    check(unfinished.first { $0.id == resumable.taskID }?.resume?["installationID"]?.stringValue == "x", "resume data survives")
    await second.interrupt(plain.taskID)
    let interrupted = await second.record(plain.taskID)
    check(interrupted?.state == .interrupted, "a task nobody resumes is interrupted")
    let replay = try await second.attach(plain.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(replay.events.map(\.kind) == ["log", "state"] && replay.events.map(\.seq.rawValue) == [1, 2], "events replay numbered from 1 with no gaps")
    check(replay.finished, "an interrupted task reads as finished")
    let resumed = try await second.attach(
        resumable.taskID,
        as: .buildAttach,
        afterSeq: EventSeq(1),
        waitMilliseconds: 0,
    )
    check(resumed.events.isEmpty && resumed.state == .running, "a resumed task keeps running")
    let finished = await second.record(done.taskID)
    check(finished?.state == .succeeded, "finished tasks stay finished")
}

// MARK: - A reopened session keeps only its newest agent task

do {
    let directory = scratch.appendingPathComponent("superseded-tasks")
    func onDisk(_ handle: TaskHandle, in folder: URL = directory) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl").path)
            || FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(handle.taskID.rawValue).json").path)
    }
    let session = UUID().uuidString.lowercased()
    let other = UUID().uuidString.lowercased()
    // What an earlier host left of the same session, read further down.
    let earlier = scratch.appendingPathComponent("superseded-earlier")
    let stale = TaskRegistry(directory: earlier)
    await stale.load()
    let staleTask = await stale.create(kind: .agent, owner: .agent, ownerKey: session)
    await stale.finish(staleTask.taskID, .failed)
    usleep(2000)
    let first = TaskRegistry(directory: directory)
    await first.load()
    let older = await first.create(kind: .agent, owner: .agent, ownerKey: session)
    await first.append(older.taskID, kind: "prompt", payload: .object(["text": .string("history")]))
    await first.finish(older.taskID, .failed)
    let otherTask = await first.create(kind: .agent, owner: .agent, ownerKey: other)
    await first.finish(otherTask.taskID, .succeeded)
    usleep(2000)
    let reopened = await first.create(kind: .agent, owner: .agent, ownerKey: session)
    let olderGone = await first.record(older.taskID) == nil
    check(olderGone && !onDisk(older), "a reopen drops the session's finished task, record and log")
    let kept = await (first.record(reopened.taskID), first.record(otherTask.taskID))
    check(kept.0 != nil && kept.1 != nil && onDisk(otherTask), "and keeps its new task and other sessions' tasks")

    // Two finished tasks of one session, as an earlier host left them. A
    // record keeps its time to the second; the reopened task, which
    // replayed the history first, is the longer.
    await first.append(reopened.taskID, kind: "prompt", payload: .object(["text": .string("history")]))
    for name in ["\(staleTask.taskID.rawValue).json", "\(staleTask.taskID.rawValue).events.jsonl"] {
        try FileManager.default.copyItem(at: earlier.appendingPathComponent(name), to: directory.appendingPathComponent(name))
    }
    await first.finish(reopened.taskID, .succeeded)
    let next = TaskRegistry(directory: directory)
    await next.load()
    let afterLoad = await (next.record(staleTask.taskID), next.record(reopened.taskID))
    check(afterLoad.0 == nil && !onDisk(staleTask) && afterLoad.1 != nil, "load drops a session's finished tasks but the newest")
}

// MARK: - Builds and environment tasks start again after a restart

/// apelin-build in miniature, over a real channel: it answers a task's
/// request at once, then emits a log line and the final `state`, unless told
/// to hang (a host that dies before the task ends).
final class FakeTaskWorker: @unchecked Sendable {
    let host: WorkerChannel
    let worker: WorkerChannel
    let lock = NSLock()
    var seen: [(taskID: TaskID?, resumed: Bool, operation: AppOperation)] = []
    var hang = false
    /// While set, each task's final `state` waits for `releaseEnds()`, so a
    /// check can see the task running however slowly the machine goes.
    var holdsEnds = false
    private var heldEnds: [CheckedContinuation<Void, Never>] = []
    /// Where events go: the registry of the host that is running now.
    var registry: TaskRegistry?

    init() throws {
        let (local, remote) = try WorkerChannel.makePair()
        host = WorkerChannel(adopting: local)
        worker = WorkerChannel(adopting: remote)
        worker.onRequest { [self] request in
            let hang = lock.withLock { () -> Bool in
                seen.append((request.taskID, request.resumed, request.request.operation))
                return self.hang
            }
            if let taskID = request.taskID, !hang {
                Task {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    try? self.worker.sendEvent(
                        taskID: taskID,
                        kind: "log",
                        payload: .object(["line": .string(request.resumed ? "again" : "first")]),
                    )
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    await self.waitIfHeld()
                    try? self.worker.sendEvent(
                        taskID: taskID,
                        kind: TaskEvent.stateKind,
                        payload: .object(["state": .string(TaskState.succeeded.rawValue)]),
                    )
                }
            }
            return (.success(request.request.requestID, Acknowledged()), [])
        }
        host.onEvent { [self] frame in
            guard let taskID = frame.header.taskID, let kind = frame.header.name, let registry = lock.withLock({ self.registry }) else { return }
            let payload = frame.body.isEmpty ? nil : try? JSONCoding.decode(JSONValue.self, from: frame.body)
            Task { await registry.append(taskID, kind: kind, payload: payload) }
        }
        worker.start()
        host.start()
    }

    private func waitIfHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held = lock.withLock { () -> Bool in
                guard holdsEnds else { return false }
                heldEnds.append(continuation)
                return true
            }
            if !held {
                continuation.resume()
            }
        }
    }

    func releaseEnds() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holdsEnds = false
            defer { heldEnds = [] }
            return heldEnds
        }
        waiting.forEach { $0.resume() }
    }

    func resumer(_ registry: TaskRegistry, refuse: Bool = false) -> TaskResume {
        lock.withLock { self.registry = registry }
        return TaskResume(
            registry: registry,
            dispatch: { [host] record, request in
                try await host.call(request, taskID: record.id, resumed: true).0
            },
            recheck: { caller, _ in
                refuse && caller.isAgent ? ApelinError(.denied, "approval required") : nil
            },
        )
    }
}

do {
    let directory = scratch.appendingPathComponent("resume-tasks")
    let fake = try FakeTaskWorker()
    let build = try WireRequest(BuildStartRequest(projectID: "p1", configuration: .debug))

    // A build the first host started: a stage, then the host is killed.
    var host = TaskRegistry(directory: directory)
    await host.load()
    let started = await host.create(kind: .build, owner: .build)
    await host.setResume(started.taskID, TaskResume.plan(build, descriptorCount: 0, caller: .app))
    await host.append(started.taskID, kind: "stage", payload: .object(["stage": .string("compile")]))

    // Others it left: an import from a descriptor, a cancelled build, a
    // clone whose URL carries a token, a toolchain removal, an agent's build.
    let fromDescriptor = await host.create(kind: .environment, owner: .environment)
    let importRequest = try WireRequest(SDKImportRequest(source: .file(DescriptorSlot(index: 0))))
    await host.setResume(fromDescriptor.taskID, TaskResume.plan(importRequest, descriptorCount: 1, caller: .app))
    let cancelled = await host.create(kind: .build, owner: .build)
    await host.setResume(cancelled.taskID, TaskResume.plan(build, descriptorCount: 0, caller: .app))
    _ = try await host.requestCancel(cancelled.taskID)
    let secretClone = await host.create(kind: .environment, owner: .environment)
    let cloneRequest = try WireRequest(
        GitCloneRequest(url: "https://me:s3cret-token@example.com/r.git", branch: "main", projectName: "R"),
    )
    await host.setResume(secretClone.taskID, TaskResume.plan(cloneRequest, descriptorCount: 0, caller: .app))
    let removal = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        removal.taskID,
        TaskResume.plan(WireRequest(ToolchainRemoveRequest(id: "t1")), descriptorCount: 0, caller: .app),
    )
    let agentBuild = await host.create(kind: .build, owner: .build)
    await host.setResume(
        agentBuild.taskID,
        TaskResume.plan(build, descriptorCount: 0, caller: .worker(.agent, instance: "s1")),
    )
    // A transfer import, even of a file in the inbox: a project it placed
    // would be placed again.
    let transferImport = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        transferImport.taskID,
        TaskResume.plan(
            WireRequest(TransferImportRequest(source: .inbox(path: "Hello.apeproj"))),
            descriptorCount: 0,
            caller: .app,
        ),
    )
    let stored = (try? String(
        contentsOf: directory.appendingPathComponent("\(secretClone.taskID.rawValue).json"),
        encoding: .utf8,
    )) ?? ""
    check(!stored.contains("s3cret") && stored.contains("credentials"), "a URL with credentials is never written into the record")
    // A token can ride in a query or a fragment as well as in the userinfo.
    let queryImport = await host.create(kind: .environment, owner: .environment)
    let queryRequest = try WireRequest(SDKImportRequest(source: .url("https://example.com/sdk.tar.xz?token=q-s3cret")))
    await host.setResume(queryImport.taskID, TaskResume.plan(queryRequest, descriptorCount: 0, caller: .app))
    let fragmentClone = await host.create(kind: .environment, owner: .environment)
    let fragmentRequest = try WireRequest(
        GitCloneRequest(url: "https://example.com/r.git#f-s3cret", branch: "main", projectName: "F"),
    )
    await host.setResume(fragmentClone.taskID, TaskResume.plan(fragmentRequest, descriptorCount: 0, caller: .app))
    for task in [queryImport, fragmentClone] {
        let text = (try? String(
            contentsOf: directory.appendingPathComponent("\(task.taskID.rawValue).json"),
            encoding: .utf8,
        )) ?? ""
        check(!text.contains("s3cret") && text.contains("credentials"), "a URL with a query or fragment is never written into the record")
    }

    // The next host: everything comes back and is picked up.
    host = TaskRegistry(directory: directory)
    let unfinished = await host.load()
    check(unfinished.count == 9, "the restarted host gets every unfinished task back")
    let resume = fake.resumer(host, refuse: true)
    // The fake build ends 20 ms after it is resumed, and resuming the nine
    // can take longer than that on a busy machine: it ends when checked.
    fake.lock.withLock { fake.holdsEnds = true }
    for record in unfinished {
        let handled = await resume.resume(record)
        check(handled, "every planned task is handled by the resumer")
    }
    let working = await host.activeByKind
    check(working["build"] == 1, "the resumed build counts as work while it runs")
    fake.releaseEnds()
    let finished = try await waitForEnd(host, started)
    check(finished.state == .succeeded, "the resumed build finishes")
    check(finished.events.map(\.kind) == ["stage", "resumed", "log", "state"], "events go on after the restart, resumed first: \(finished.events.map(\.kind))")
    check(finished.events.map(\.seq.rawValue) == [1, 2, 3, 4], "the numbering has no gap across the restart")
    check(finished.events[2].payload?["line"]?.stringValue == "again", "the worker was told it is a resume")
    let sent = fake.lock.withLock { fake.seen }
    check(sent.count == 1 && sent.first?.taskID == started.taskID && sent.first?.resumed == true && sent.first?.operation == .buildStart,
          "only the build is sent again, under its own task ID, marked resumed")
    let plan = try await host.record(started.taskID)?.resume?.decode(TaskResume.Plan.self)
    check(plan?.resumes == 1, "the resume is counted in the record")

    let descriptorEnd = try await waitForEnd(host, fromDescriptor)
    check(descriptorEnd.state == .interrupted && descriptorEnd.events.last?.payload?["message"]?.stringValue?.isEmpty == false,
          "a task started with a descriptor ends interrupted, saying why")
    let cancelledEnd = try await waitForEnd(host, cancelled)
    check(cancelledEnd.state == .cancelled, "a cancel asked for before the restart stays cancelled")
    let secretEnd = try await waitForEnd(host, secretClone)
    check(secretEnd.state == .interrupted && secretEnd.events.last?.payload?["message"]?.stringValue?.contains("credentials") == true,
          "a clone with credentials in its URL ends interrupted")
    let removalEnd = try await waitForEnd(host, removal)
    check(removalEnd.state == .interrupted, "a toolchain removal is not resumed")
    for task in [queryImport, fragmentClone] {
        let end = try await waitForEnd(host, task)
        check(end.state == .interrupted && end.events.last?.payload?["message"]?.stringValue?.contains("credentials") == true,
              "a task whose URL has a query or fragment ends interrupted, saying why")
    }
    let agentEnd = try await waitForEnd(host, agentBuild)
    check(agentEnd.state == .interrupted && agentEnd.events.last?.payload?["message"]?.stringValue?.contains("agent session") == true,
          "an agent's build is not resumed: its session ended with the old host, so nothing would read it")
    let transferEnd = try await waitForEnd(host, transferImport)
    check(transferEnd.state == .interrupted && transferEnd.events.last?.payload?["message"]?.stringValue?.isEmpty == false,
          "a transfer import is never resumed, so a project is never placed twice")

    // A crash loop: each host dies before the task ends; the third gives up.
    fake.lock.withLock { fake.hang = true; fake.seen = [] }
    host = TaskRegistry(directory: directory)
    await host.load()
    let looping = await host.create(kind: .environment, owner: .environment)
    try await host.setResume(
        looping.taskID,
        TaskResume.plan(
            WireRequest(SDKImportRequest(source: .inbox(path: "x.sdk"))),
            descriptorCount: 0,
            caller: .app,
        ),
    )
    for restart in 1 ... TaskResume.maximumResumes + 1 {
        host = TaskRegistry(directory: directory)
        let records = await host.load()
        check(records.map(\.id) == [looping.taskID], "restart \(restart) hands the import back")
        _ = await fake.resumer(host).resume(records[0])
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    let loopEnd = try await host.attach(looping.taskID, as: .environmentAttach, afterSeq: .start, waitMilliseconds: 0)
    check(loopEnd.state == .interrupted && fake.lock.withLock { fake.seen.count } == TaskResume.maximumResumes,
          "a task resumed \(TaskResume.maximumResumes) times without ending is interrupted, not resumed again")
    check(loopEnd.events.map(\.kind) == ["resumed", "resumed", "state"] && loopEnd.events.map(\.seq.rawValue) == [1, 2, 3], "each resume is an event")
    let left = await host.activeCount
    check(left == 0, "nothing is left to keep the host up")

    // The host forgets a resumed build's earlier package.
    let artifacts = ArtifactRegistry(file: scratch.appendingPathComponent("resume-artifacts.json"))
    let buildID = TaskID.make()
    await artifacts.record(
        event: .object([
            "artifactID": .string(buildID.rawValue),
            "path": .string("/x.deb"),
            "digest": .string(String(repeating: "a", count: 64)),
        ]),
        buildID: buildID,
    )
    await artifacts.forget(buildID: buildID)
    let forgotten = await artifacts.artifact(buildID.rawValue)
    check(forgotten == nil, "a resumed build's earlier artifact is forgotten")
}

// MARK: - A load check keeps its answer with nobody attached

do {
    // The respring a load check triggers takes the app down; the task, its
    // events and the answer in its final state stay on the host's disk.
    let directory = scratch.appendingPathComponent("confirm-tasks")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let check1 = await first.create(kind: .confirmLoaded, owner: .diagnostics)
    check(check1.attachOperation == .confirmLoadedAttach, "a load check is read with confirmLoadedAttach")
    let answer = ConfirmLoadedResponse(
        loaded: true,
        evidence: [LoadEvidence(kind: "log", passed: true, detail: "confirmed: Marker logged by pid 55.")],
    )
    await first.append(check1.taskID, kind: "stage", payload: .object(["stage": .string("listening")]))
    await first.append(check1.taskID, kind: "stage", payload: .object(["stage": .string("trigger")]))
    try await first.append(check1.taskID, kind: TaskEvent.stateKind, payload: .object([
        "state": .string("succeeded"),
        ConfirmLoadedResponse.stateMember: JSONValue(encoding: answer),
    ]))
    let counts = await first.activeByKind
    check(counts["confirmLoaded"] == nil, "a finished load check is no longer work")

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a finished load check is not resumed")
    let batch = try await second.attach(check1.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(batch.finished && batch.state == .succeeded, "the load check reads as finished after a restart")
    let read = try batch.events.last.map { try ConfirmLoadedResponse.from(finalState: $0) }
    check(read == answer, "its answer is in the final state")
    await expectErrorAsync("a load check read as a build", code: .badRequest) {
        _ = try await second.attach(check1.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    }

    // One the host stopped under is interrupted, like any task nobody resumes.
    let running = await second.create(kind: .confirmLoaded, owner: .diagnostics)
    let third = TaskRegistry(directory: directory)
    for record in await third.load() {
        await third.interrupt(record.id)
    }
    let after = try await third.attach(running.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(after.state == .interrupted, "a load check the host stopped under ends interrupted")
}

// MARK: - Caller policy

do {
    check(CallerPolicy.allows(.app, .protectedEditCommit), "the app may edit")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .buildStart), "the agent may build")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .approvalDigestState), "the agent may read the ledger")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .installationList), "the agent may list installations")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .installationList) && !CallerPolicy.allows(.worker(.diagnostics, instance: nil), .installationList), "no other worker lists installations")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .toolHostCall), "the agent may call tools")
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .confirmLoaded) && CallerPolicy.allows(.worker(.agent, instance: "s"), .confirmLoadedAttach), "the agent starts and reads a load check")
    // Accounts are the app's alone: a session's agent never starts, answers
    // or reads a sign-in, and never lists or forgets an account.
    for operation: AppOperation in [.protectedEditOpen, .protectedEditCommit, .ptyOpen, .ptyAttach, .agentApprove, .agentSteer, .agentCompact,
                                    .toolchainRemove, .sdkRemove, .environmentCancel,
                                    .agentAccountList, .agentAPIConfiguration, .agentModelList, .agentModelActivate, .agentSignIn, .agentSignInRespond, .agentSignInCancel, .agentSignOut,
                                    .agentCredentialImport, .transferExport, .transferInspect, .transferImport]
    {
        check(!CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent may not call \(operation.rawValue)")
    }
    // The device's toolchains and SDKs: listed, set up, imported, tested
    // again, and the tasks it started read back (AgentEnvironmentRules and
    // EnvironmentHandler narrow each one). Removal stays the app's.
    for operation: AppOperation in [.toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainSelfTest, .sdkList, .sdkImport, .environmentAttach] {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent reaches the device's toolchains and SDKs (\(operation.rawValue))")
    }
    let agentEnvironmentOperations = CallerPolicy.agentOperations.filter {
        $0.domain == .toolchain || $0.domain == .sdk || $0.domain == .environment
    }
    check(
        agentEnvironmentOperations == [.toolchainStatus, .toolchainCatalog, .toolchainSetup, .toolchainSelfTest, .sdkList, .sdkImport, .environmentAttach],
        "and exactly those of the environment domains: \(agentEnvironmentOperations.map(\.rawValue).sorted())",
    )
    // The project's other conversations: AgentHandler narrows each one.
    for operation: AppOperation in [.agentOpen, .agentPrompt, .agentList, .agentAttach, .agentAbort, .agentClose] {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent reaches its project's conversations (\(operation.rawValue))")
        check(!CallerPolicy.allows(.worker(.environment, instance: nil), operation), "the environment worker does not (\(operation.rawValue))")
    }
    let environment = Caller.worker(.environment, instance: nil)
    check(CallerPolicy.allows(environment, .installPackage) && CallerPolicy.allows(environment, .removePackage), "the environment worker installs its toolchain package")
    check(!CallerPolicy.allows(environment, .protectedEditCommit) && !CallerPolicy.allows(environment, .ptyOpen), "and nothing of the app's")
    // The diagnostics worker asks for a protected crash report by id and for
    // the respring confirmLoaded triggers, and nothing else.
    let diagnostics = Caller.worker(.diagnostics, instance: nil)
    for operation in AppOperation.allCases {
        let expected = operation == .crashOpen || operation == .respring
        check(CallerPolicy.allows(diagnostics, operation) == expected, "diagnostics calls only crashOpen and respring (\(operation.rawValue))")
    }
    for role: WorkerRole in [.build, .logReader] {
        for operation in AppOperation.allCases {
            check(!CallerPolicy.allows(.worker(role, instance: nil), operation), "\(role.rawValue) calls nothing (\(operation.rawValue))")
        }
    }
    // Only an agent worker reaches agentRunCode.
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .agentRunCode), "the agent runs code through the host")
    check(!CallerPolicy.allows(environment, .agentRunCode), "the environment worker does not")
}

// MARK: - An agent and Apelin's own screen

do {
    func forwarded(_ action: UIActionRequest, from caller: Caller) throws -> WireRequest {
        try AgentUIActionRules.scoped(WireRequest(action), caller: caller)
    }
    let tap = UIAction.tap(x: 200, y: 4)
    let agent = Caller.worker(.agent, instance: "s")
    for sent: [String]? in [nil, [], ["com.apple.springboard"]] {
        let action = try forwarded(UIActionRequest(targetID: "wiki.qaq.apelin", action: tap, refusedBundleIDs: sent), from: agent)
            .decode(UIActionRequest.self)
        check(action.refusedBundleIDs == ["wiki.qaq.apelin"], "an agent's UI action refuses Apelin whatever it sent (\(String(describing: sent)))")
        check(action.targetID == "wiki.qaq.apelin" && action.action == tap, "and is otherwise as it was sent")
    }
    let app = try forwarded(UIActionRequest(action: tap), from: .app)
    let appAction = try app.decode(UIActionRequest.self)
    check(appAction.refusedBundleIDs == nil, "the app's and the console's UI actions refuse nothing")
    check(!String(decoding: app.payload, as: UTF8.self).contains("refusedBundleIDs"), "and carry no list on the wire")
    expectError("an agent's UI action that does not read is refused", code: .badRequest) {
        _ = try AgentUIActionRules.scoped(WireRequest(operation: .uiAction, payload: Data("{}".utf8)), caller: agent)
    }
}

// MARK: - An agent's conversations stay in its project, under its mode

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("conversation-tasks"))
    await registry.load()
    let table = AgentSessionTable()
    let project = ResolvedProject(id: "p-conversations", name: "Conversations", path: scratchPath + "/Conversations")
    let other = ResolvedProject(id: "p-other", name: "Other", path: scratchPath + "/Other")
    func session(
        _ id: String,
        in project: ResolvedProject = project,
        mode: ApprovalMode = .confirm,
        parent: String? = nil,
        depth: Int = 0,
    ) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            createdAt: Date(),
            parentSessionID: parent,
            depth: depth,
        )
        await table.add(entry)
        return entry
    }
    let opener = await session("c-opener", mode: .confirm)

    // Open: always the opener's project and current mode, with a prompt;
    // nothing of its own beyond prompt, title, provider, model, effort and tier.
    let asked = AgentOpenRequest(
        projectID: "p-other",
        projectName: "Other",
        temporaryID: UUID().uuidString,
        sessionID: UUID().uuidString,
        provider: .anthropic,
        model: "claude-sonnet-5-5",
        approvalMode: .relaxed,
        reasoningEffort: .high,
        serviceTier: .priority,
        prompt: "Write the README",
        closeWhenFinished: true,
        title: "  Docs\nsecond line",
    )
    let child = try AgentConversationRules.childOpen(asked, opener: opener, target: project)
    check(child.projectID == project.id && child.projectName == project.name, "an opened conversation is in the project the host resolved, not the one the request spelled")
    check(child.temporaryID == nil && child.sessionID == nil && child.closeWhenFinished == nil, "and is new, in no temporary workspace, and not headless")
    check(child.approvalMode == .confirm, "and runs under the opener's mode, never a laxer one it asked for")
    check(
        child.provider == .anthropic && child.model == "claude-sonnet-5-5" && child.reasoningEffort == .high
            && child.serviceTier == .priority,
        "provider, model, effort and tier go as sent",
    )
    check(child.prompt == "Write the README" && child.title == "Docs", "the prompt goes as sent, the title on one trimmed line")
    let relaxed = await session("c-relaxed", mode: .relaxed)
    let relaxedChild = try AgentConversationRules.childOpen(
        AgentOpenRequest(approvalMode: .confirm, prompt: "go"),
        opener: relaxed,
        target: project,
    )
    check(relaxedChild.approvalMode == .relaxed, "a Relaxed opener's conversation is Relaxed")
    expectError("an opened conversation needs a prompt", code: .badRequest) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "  \n "), opener: opener, target: project)
    }
    // Another project: General Chat included, never a temporary one.
    let crossChild = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "Import the repository"), opener: opener, target: other)
    check(crossChild.projectID == other.id && crossChild.projectName == other.name && crossChild.approvalMode == .confirm, "a conversation opens in another project under the opener's mode")
    let temporaryProject = ResolvedProject(id: "temporary:\(UUID().uuidString)", name: "t", path: scratchPath)
    let general = await session("c-general", in: temporaryProject)
    let fromGeneral = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "Import the repository"), opener: general, target: project)
    check(fromGeneral.projectID == project.id, "General Chat opens a conversation in a project")
    expectError("but never in a temporary chat", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: general, target: temporaryProject)
    }
    expectError("nor in another temporary chat from a project", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: opener, target: temporaryProject)
    }
    let deep = await session("c-deep", parent: "c-opener", depth: AgentConversations.maximumDepth)
    expectError("a chain of openings stops at the maximum depth", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: deep, target: project)
    }
    expectError("in another project too", code: .denied) {
        _ = try AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: deep, target: other)
    }
    let middle = await session("c-middle", parent: "c-opener", depth: AgentConversations.maximumDepth - 1)
    check((try? AgentConversationRules.childOpen(AgentOpenRequest(prompt: "go"), opener: middle, target: project)) != nil, "one short of the depth still opens")

    // The approval an open or a message in another project spends: the
    // user's of exactly that call.
    func otherProjectAsk(_ tool: String, action: String, projectID: String, sessionID: String? = nil, text: String) -> JSONValue {
        var detail: [String: JSONValue] = [
            "action": .string(action), "projectID": .string(projectID), "projectName": .string("Other"), "text": .string(text),
        ]
        if let sessionID {
            detail["sessionID"] = .string(sessionID)
        }
        return .object(["tool": .string(tool), "detail": .object([AgentConversationRules.otherProjectDetail: .object(detail)])])
    }
    let openAsk = otherProjectAsk("apelin_conversation_create", action: "create", projectID: other.id, text: "Import the repository")
    check(AgentConversationRules.coversOpen(crossChild, target: other, asked: openAsk), "an approval of this open in this project covers it")
    let third = ResolvedProject(id: "p-third", name: "Third", path: scratchPath + "/Third")
    check(!AgentConversationRules.coversOpen(crossChild, target: third, asked: openAsk), "not one in another project")
    check(
        !AgentConversationRules.coversOpen(AgentOpenRequest(prompt: "Delete everything"), target: other, asked: openAsk),
        "nor another prompt",
    )
    check(
        !AgentConversationRules.coversOpen(crossChild, target: other, asked: otherProjectAsk("apelin_conversation_send", action: "send", projectID: other.id, text: "Import the repository")),
        "nor an approval of another tool",
    )

    // The cap counts running agent-opened sessions and held places.
    let capped = ResolvedProject(id: "p-capped", name: "Capped", path: scratchPath + "/Capped")
    var children: [AgentSessionTable.Entry] = []
    for index in 0 ..< AgentConversations.maximumOpenChildren - 1 {
        await children.append(session("c-child-\(index)", in: capped, parent: "c-opener", depth: 1))
    }
    _ = await session("c-app-session", in: capped)
    let belowCap = await table.reserveChild(project: capped.id, registry: registry)
    check(belowCap, "a place is free below the cap")
    let pastCap = await table.reserveChild(project: capped.id, registry: registry)
    check(!pastCap, "a held place counts toward the cap")
    let otherProject = await table.reserveChild(project: project.id, registry: registry)
    check(otherProject, "another project has its own places")
    await table.releaseChild(project: project.id)
    await table.add(
        AgentSessionTable.Entry(
            sessionID: "c-child-last",
            task: registry.create(kind: .agent, owner: .agent, ownerKey: "c-child-last"),
            project: capped,
            mode: .confirm,
            createdAt: Date(),
            parentSessionID: "c-opener",
            depth: 1,
        ),
        releasingReservation: true,
    )
    let afterOpen = await table.reserveChild(project: capped.id, registry: registry)
    check(!afterOpen, "an open session takes the place it held")
    await registry.finish(children[0].task.taskID, .succeeded)
    let afterEnd = await table.reserveChild(project: capped.id, registry: registry)
    check(afterEnd, "one that ended frees its place")
    await table.releaseChild(project: capped.id)

    // Prompt: another session of the same project, as a message from the
    // sender, with nothing else of the sender's.
    let target = await session("c-target")
    let sent = AgentPromptRequest(
        sessionID: "c-target",
        text: "Review Tweak.x",
        messageID: UUID(),
        provider: .openAI,
        model: "gpt",
        reasoningEffort: .max,
        serviceTier: .ultrafast,
        approvalMode: .relaxed,
        fromSessionID: "c-forged",
    )
    let rewritten = try AgentConversationRules.childPrompt(sent, sender: opener, target: target, descriptorCount: 0)
    check(rewritten.sessionID == "c-target" && rewritten.text == "Review Tweak.x", "the message goes to the target as typed")
    check(rewritten.fromSessionID == "c-opener", "and is marked with the sender the host knows, not the one it claimed")
    check(
        rewritten.approvalMode == nil && rewritten.provider == nil && rewritten.model == nil
            && rewritten.reasoningEffort == nil && rewritten.serviceTier == nil && rewritten.attachments == nil
            && rewritten.messageID == nil,
        "and carries no mode, provider, model, effort, tier, files or message id of the sender's",
    )
    expectError("a message carries no descriptors", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(sent, sender: opener, target: target, descriptorCount: 1)
    }
    let attached = AgentPromptRequest(
        sessionID: "c-target",
        text: "x",
        attachments: [AgentInputAttachment(descriptor: DescriptorSlot(index: 0), name: "a", mimeType: "text/plain")],
    )
    expectError("nor attachments", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(attached, sender: opener, target: target, descriptorCount: 0)
    }
    expectError("a conversation does not message itself", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-opener", text: "x"),
            sender: opener,
            target: opener,
            descriptorCount: 0,
        )
    }
    let elsewhere = await session("c-elsewhere", in: other)
    let toElsewhere = try AgentConversationRules.childPrompt(
        AgentPromptRequest(sessionID: "c-elsewhere", text: "Build it"),
        sender: opener,
        target: elsewhere,
        descriptorCount: 0,
    )
    check(toElsewhere.fromSessionID == "c-opener", "a message goes to another project's conversation the same way")
    let sendAsk = otherProjectAsk("apelin_conversation_send", action: "send", projectID: other.id, sessionID: "c-elsewhere", text: "Build it")
    check(AgentConversationRules.coversSend(toElsewhere, target: elsewhere, asked: sendAsk), "an approval of this message to this conversation covers it")
    check(
        !AgentConversationRules.coversSend(AgentPromptRequest(sessionID: "c-elsewhere", text: "Push it"), target: elsewhere, asked: sendAsk),
        "not another text",
    )
    let elsewhereToo = await session("c-elsewhere-too", in: other)
    check(!AgentConversationRules.coversSend(toElsewhere, target: elsewhereToo, asked: sendAsk), "nor another conversation")
    let temporaryTarget = await session("c-temporary-target", in: temporaryProject)
    expectError("nor a temporary chat, which is the user's alone", code: .denied) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-temporary-target", text: "x"),
            sender: opener,
            target: temporaryTarget,
            descriptorCount: 0,
        )
    }
    expectError("nor one the host does not know", code: .notFound) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-gone", text: "x"),
            sender: opener,
            target: nil,
            descriptorCount: 0,
        )
    }
    expectError("nor an empty message", code: .badRequest) {
        _ = try AgentConversationRules.childPrompt(
            AgentPromptRequest(sessionID: "c-target", text: " "),
            sender: opener,
            target: target,
            descriptorCount: 0,
        )
    }
    let fromApp = AgentConversationRules.appPrompt(sent)
    check(fromApp.fromSessionID == nil && fromApp.approvalMode == .relaxed && fromApp.model == "gpt", "the app's prompt keeps everything but a forged sender")

    // Abort and close: only the conversations the caller opened.
    let mine = await session("c-mine", parent: "c-opener", depth: 1)
    check((try? AgentConversationRules.mayStop(mine, caller: opener, sessionID: "c-mine")) != nil, "an agent stops a conversation it opened")
    expectError("not one the app opened", code: .denied) {
        try AgentConversationRules.mayStop(target, caller: opener, sessionID: "c-target")
    }
    expectError("nor one a sibling opened", code: .denied) {
        try AgentConversationRules.mayStop(mine, caller: target, sessionID: "c-mine")
    }
    expectError("nor its opener", code: .denied) {
        try AgentConversationRules.mayStop(opener, caller: mine, sessionID: "c-opener")
    }

    // Attach and list: the project's sessions only.
    let named = await table.entry(task: target.task.taskID)
    check(named?.sessionID == "c-target", "a task names its session")
    check((try? AgentConversationRules.mayRead(target.task.taskID, target: target, caller: opener)) != nil, "an agent reads a conversation of its project")
    expectError("not one of another project the user has not let it reach", code: .denied) {
        try AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: opener)
    }
    check(
        (try? AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: opener, reachable: true)) != nil,
        "one it may reach, it reads",
    )
    check(
        (try? AgentConversationRules.mayRead(elsewhere.task.taskID, target: elsewhere, caller: relaxed)) != nil,
        "and in Relaxed mode every project's",
    )
    expectError("never a temporary chat's", code: .denied) {
        try AgentConversationRules.mayRead(temporaryTarget.task.taskID, target: temporaryTarget, caller: relaxed, reachable: true)
    }
    let build = await registry.create(kind: .build, owner: .build, ownerKey: nil)
    let noConversation = await table.entry(task: build.taskID)
    expectError("nor a task that is no conversation", code: .denied) {
        try AgentConversationRules.mayRead(build.taskID, target: noConversation, caller: opener)
    }
    let listed = await table.summaries(registry: registry, projectID: project.id)
    check(!listed.isEmpty && listed.allSatisfy { $0.projectID == project.id }, "an agent's list names only its project's sessions")
    check(listed.first { $0.sessionID == "c-mine" }?.parentSessionID == "c-opener", "and says who opened each")
    check(listed.first { $0.sessionID == "c-target" }?.parentSessionID == nil, "the app's have no opener")
    check(listed.allSatisfy { $0.projectName == project.name }, "and names each one's project folder")
    let generalListed = await table.summaries(registry: registry, projectID: temporaryProject.id)
    check(generalListed.allSatisfy { $0.projectName == nil }, "a temporary chat names none")
    let everything = await table.summaries(registry: registry)
    check(everything.contains { $0.projectID == other.id }, "the app's list names every project's")
    await table.setTitle("Docs pass", session: "c-mine")
    let retitled = await table.summaries(registry: registry, projectID: project.id)
    check(retitled.first { $0.sessionID == "c-mine" }?.title == "Docs pass", "a session is listed by the title its agent gave it")

    // conversationOpened on the opener's task.
    let opened = AgentConversationRules.openedEvent(
        sessionID: "c-mine",
        task: mine.task,
        title: "Docs",
        prompt: "Write the README",
    )
    check(
        opened["sessionID"]?.stringValue == "c-mine" && opened["task"]?["taskID"]?.stringValue == mine.task.taskID.rawValue
            && opened["task"]?["kind"]?.stringValue == "agent" && opened["title"]?.stringValue == "Docs"
            && opened["prompt"]?.stringValue == "Write the README",
        "conversationOpened names the session, its task, its title and its prompt",
    )
    check(AgentConversationRules.openedEvent(sessionID: "s", task: mine.task, title: nil, prompt: "p")["title"] == nil, "and leaves out a title it was not given")
    let openedElsewhere = AgentConversationRules.openedEvent(sessionID: "s", task: mine.task, title: nil, prompt: "p", project: other)
    check(
        openedElsewhere["projectID"]?.stringValue == other.id && openedElsewhere["projectName"]?.stringValue == other.name,
        "and names the project it opened in, which the app adopts it into",
    )
    check(AgentConversationRules.title(String(repeating: "x", count: 200))?.count == AgentConversationRules.maximumTitleLength, "a title is bounded")
    check(AgentConversationRules.title(" \n ") == nil, "and an empty one is none")
}

// MARK: - An agent lists the conversations that have not run since the host started

do {
    let home = scratchPath + "/stored-home"
    let data = DataFolder(home: home)
    write(data.projects.path + "/Docs/apelin-project.json", #"{"projectID": "p-docs"}"#)
    write(data.projects.path + "/Far/apelin-project.json", #"{"projectID": "p-far"}"#)
    write(data.projects.path + "/Many/apelin-project.json", #"{"projectID": "p-many"}"#)
    let docs = try AgentProjects.resolve(home: home, projectID: "p-docs", projectName: nil)
    func stored(_ projectID: String) -> String {
        let session = UUID().uuidString.lowercased()
        write(data.sessions.path + "/\(session)/session.json", #"{"id": "\#(session)", "project": {"id": "\#(projectID)", "name": "x"}}"#)
        return session
    }
    let state = scratch.appendingPathComponent("stored-state")
    let tasks = state.appendingPathComponent("tasks")

    // What the last host left: sessions of Docs, one opened by another and
    // opened twice, one of Far, a temporary chat, one whose folder is a
    // link, one with no session.json, and the caller's own earlier task.
    let earlier = TaskRegistry(directory: tasks)
    await earlier.load()
    let titled = stored("p-docs")
    let titledTask = await earlier.create(kind: .agent, owner: .agent, ownerKey: titled)
    await earlier.append(titledTask.taskID, kind: "title", payload: .object(["text": .string("Docs pass")]))
    let child = stored("p-docs")
    let childFirst = await earlier.create(kind: .agent, owner: .agent, ownerKey: child)
    await earlier.finish(childFirst.taskID, .succeeded)
    usleep(2000)
    let childTask = await earlier.create(kind: .agent, owner: .agent, ownerKey: child)
    // Reopened, its task replays the history before anything new.
    await earlier.append(childTask.taskID, kind: "prompt", payload: .object(["text": .string("Write the README")]))
    await earlier.append(childTask.taskID, kind: "prompt", payload: .object(["text": .string("Shorter")]))
    AgentSessionLineage.save(AgentSessionLineage.Record(parentSessionID: titled, depth: 1), session: child, state: state)
    let distant = stored("p-far")
    let distantTask = await earlier.create(kind: .agent, owner: .agent, ownerKey: distant)
    let temporary = stored("temporary:" + UUID().uuidString)
    let temporaryTask = await earlier.create(kind: .agent, owner: .agent, ownerKey: temporary)
    let linked = UUID().uuidString.lowercased()
    write(scratchPath + "/stored-elsewhere/session.json", #"{"project": {"id": "p-docs"}}"#)
    symlink(scratchPath + "/stored-elsewhere", data.sessions.path + "/" + linked)
    let linkedTask = await earlier.create(kind: .agent, owner: .agent, ownerKey: linked)
    let unwritten = UUID().uuidString.lowercased()
    _ = await earlier.create(kind: .agent, owner: .agent, ownerKey: unwritten)
    let caller = stored("p-docs")
    let callerEarlier = await earlier.create(kind: .agent, owner: .agent, ownerKey: caller)

    // The next host: every task that was running interrupted, an empty table.
    let registry = TaskRegistry(directory: tasks)
    for record in await registry.load() {
        await registry.interrupt(record.id)
    }
    let table = AgentSessionTable()
    func session(_ id: String, in project: ResolvedProject, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project,
            mode: mode,
            createdAt: Date(),
        )
        await table.add(entry)
        return entry
    }
    func list(_ entry: AgentSessionTable.Entry, project: String? = nil) async throws -> AgentListResponse {
        try await AgentConversationList.list(
            AgentListRequest(projectName: project),
            caller: entry,
            table: table,
            registry: registry,
            home: home,
            state: state,
        )
    }
    let own = await session(caller, in: docs, mode: .confirm)

    // A record read back from disk keeps its times to the second, so the
    // stored ones come in no order the test can name.
    let listed = try await list(own)
    check(
        Set(listed.sessions.dropLast().map(\.sessionID)) == [titled, child] && listed.sessions.last?.sessionID == caller,
        "a project's list names its sessions the host has not run since it started, then the running ones: \(listed.sessions.map(\.sessionID))",
    )
    let titledListed = listed.sessions.first { $0.sessionID == titled }
    check(
        titledListed?.task == titledTask && titledListed?.state == .interrupted && titledListed?.title == "Docs pass"
            && titledListed?.projectID == "p-docs" && titledListed?.projectName == "Docs",
        "each by its task, ended, with the title its agent gave it and its project",
    )
    let childListed = listed.sessions.first { $0.sessionID == child }
    check(childListed?.task == childTask && childListed?.parentSessionID == titled, "a session opened twice by its newest task, with its opener")
    check(listed.sessions.first { $0.sessionID == caller }?.task == own.task, "a running session by the task it runs, never an earlier one")
    check(listed.unreachedProjects == nil, "and a project's list leaves no project out")

    // Reading: the task a list names, of a project the caller reaches.
    let attach = { (taskID: TaskID, entry: AgentSessionTable.Entry) in
        try await AgentConversationList.mayAttach(taskID, caller: entry, table: table, registry: registry, home: home)
    }
    let readsStored = await (try? attach(titledTask.taskID, own)) != nil
    check(readsStored, "a stored session's task is read as any ended one's")
    await expectErrorAsync("not a session's earlier task", code: .denied) { try await attach(childFirst.taskID, own) }
    await expectErrorAsync("nor a running session's earlier task", code: .denied) { try await attach(callerEarlier.taskID, own) }
    await expectErrorAsync("nor a temporary chat's", code: .denied) { try await attach(temporaryTask.taskID, own) }
    await expectErrorAsync("nor one whose folder is a link", code: .denied) { try await attach(linkedTask.taskID, own) }
    await expectErrorAsync("nor another project's the user has not let it reach", code: .denied) { try await attach(distantTask.taskID, own) }
    let build = await registry.create(kind: .build, owner: .build, ownerKey: titled)
    await expectErrorAsync("nor a task that is no conversation", code: .denied) { try await attach(build.taskID, own) }

    // Another project: under Strict only once the user let it reach it.
    await expectErrorAsync("another project's list asks first", code: .denied) { _ = try await list(own, project: "Far") }
    _ = await table.allowProject("p-far", session: caller)
    let farListed = try await list(own, project: "Far")
    check(farListed.sessions.map(\.sessionID) == [distant], "then lists that project's")
    let readsFar = await (try? attach(distantTask.taskID, own)) != nil
    check(readsFar, "and reads it")

    // General Chat: every project's it may reach, never a temporary chat's.
    let generalID = UUID().uuidString.lowercased()
    let general = await session(
        generalID,
        in: ResolvedProject(id: "temporary:" + generalID, name: generalID, path: data.root.path + "/Temporary/" + generalID),
        mode: .confirm,
    )
    let strict = try await list(general)
    check(strict.sessions.isEmpty && strict.unreachedProjects == 3, "General Chat under Strict lists no project it may not reach, and says how many")
    _ = await table.allowProject("p-docs", session: generalID)
    let reached = try await list(general)
    check(
        Set(reached.sessions.dropLast().map(\.sessionID)) == [titled, child] && reached.sessions.last?.sessionID == caller,
        "then the ones it may: \(reached.sessions.map(\.sessionID))",
    )
    check(reached.unreachedProjects == 2, "and counts the rest")
    let relaxedID = UUID().uuidString.lowercased()
    let relaxed = await session(
        relaxedID,
        in: ResolvedProject(id: "temporary:" + relaxedID, name: relaxedID, path: data.root.path + "/Temporary/" + relaxedID),
        mode: .relaxed,
    )
    let everything = try await list(relaxed)
    check(
        Set(everything.sessions.map(\.sessionID)) == [titled, child, distant, caller],
        "in Relaxed mode General Chat lists every project's, and no temporary chat: \(everything.sessions.map(\.sessionID))",
    )
    check(everything.unreachedProjects == nil, "leaving none out")
    check(everything.sessions.allSatisfy { $0.projectName != nil }, "each with its project")

    // At most maximumStoredSessions, the most recently active.
    var many: [String] = []
    let later = TaskRegistry(directory: tasks)
    await later.load()
    for _ in 0 ... AgentConversationList.maximumStoredSessions {
        let session = stored("p-many")
        await later.finish(later.create(kind: .agent, owner: .agent, ownerKey: session).taskID, .succeeded)
        many.append(session)
        if many.count == 1 {
            usleep(2000)
        }
    }
    let manyListed = try await AgentConversationList.list(
        AgentListRequest(projectName: "Many"),
        caller: relaxed,
        table: table,
        registry: later,
        home: home,
        state: state,
    )
    check(manyListed.sessions.count == AgentConversationList.maximumStoredSessions, "a list names at most \(AgentConversationList.maximumStoredSessions) sessions that have not run")
    check(!manyListed.sessions.contains { $0.sessionID == many[0] }, "the most recently active")
    check(zip(manyListed.sessions, manyListed.sessions.dropFirst()).allSatisfy { $0.updatedAt <= $1.updatedAt }, "oldest first")
}

// MARK: - Protected edit

do {
    let root = scratchPath + "/root"
    let home = root + "/var/mobile"
    try FileManager.default.createDirectory(
        atPath: home + "/Documents/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    write(root + "/etc/hosts", "127.0.0.1 localhost\n")
    write(root + "/etc/run.sh", "#!/bin/sh\n", mode: 0o755)
    FileManager.default.createFile(atPath: root + "/etc/macho", contents: Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3, 4]))
    write(root + "/etc/linked", "a\n")
    link(root + "/etc/linked", root + "/etc/linked2")
    symlink(root + "/etc/hosts", root + "/etc/hosts-link")
    write(root + "/var/lib/dpkg/status", "Package: x\n")
    write(root + "/Library/LaunchDaemons/com.example.plist", "<plist/>\n")
    write(scratchPath + "/outside", "x\n")

    let hosts = try ProtectedEditPolicy.evaluate(root + "/etc/hosts", installRoot: root)
    check(!hosts.needsConfirmation && hosts.version.sha256 != nil, "a regular file is editable")
    expectError("a symlink", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/hosts-link", installRoot: root) }
    expectError("an executable", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/run.sh", installRoot: root) }
    expectError("a Mach-O", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/macho", installRoot: root) }
    expectError("a hard-linked file", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/linked", installRoot: root) }
    expectError("the dpkg database", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/var/lib/dpkg/status", installRoot: root) }
    expectError("outside the install root", code: .denied) { _ = try ProtectedEditPolicy.evaluate(scratchPath + "/outside", installRoot: root) }
    expectError("a .. escape", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc/../../outside", installRoot: root) }
    expectError("a folder", code: .denied) { _ = try ProtectedEditPolicy.evaluate(root + "/etc", installRoot: root) }
    let daemon = try ProtectedEditPolicy.evaluate(root + "/Library/LaunchDaemons/com.example.plist", installRoot: root)
    check(daemon.needsConfirmation, "a LaunchDaemons plist needs confirmation")

    let editor = ProtectedEditor(installRoot: root, backups: BackupStore(home: home))
    chmod(root + "/etc/hosts", 0o640)
    let (opened, descriptor) = try await editor.open(ProtectedEditOpenRequest(path: root + "/etc/hosts"))
    var firstBytes = [UInt8](repeating: 0, count: 9)
    check(pread(descriptor.rawValue, &firstBytes, 9, 0) == 9 && String(decoding: firstBytes, as: UTF8.self) == "127.0.0.1", "the open hands back the contents")
    let commit = ProtectedEditCommitRequest(
        grantID: opened.grantID,
        contents: nil,
        contentsBase64: Data("10.0.0.1 router\n".utf8).base64EncodedString(),
        expectedVersion: opened.version,
    )
    let saved = try await editor.commit(commit, descriptors: [])
    check(String(data: FileManager.default.contents(atPath: root + "/etc/hosts")!, encoding: .utf8) == "10.0.0.1 router\n", "the commit replaces the contents")
    var after = stat()
    stat(root + "/etc/hosts", &after)
    check(after.st_mode & 0o7777 == 0o640, "the mode is kept")
    check(saved.version.inode != opened.version.inode, "the replace is a new inode (atomic rename)")
    let backup = home + "/Documents/wiki.qaq.apelin/backups/" + saved.backupID
    check(String(data: FileManager.default.contents(atPath: backup) ?? Data(), encoding: .utf8) == "127.0.0.1 localhost\n", "the old contents are backed up first")
    await expectErrorAsync("a grant is spent once", code: .notFound) { _ = try await editor.commit(commit, descriptors: []) }

    let (stale, _) = try await editor.open(ProtectedEditOpenRequest(path: root + "/etc/hosts"))
    usleep(10000)
    write(root + "/etc/hosts", "changed elsewhere\n", mode: 0o640)
    await expectErrorAsync("a file changed after the open is not overwritten", code: .conflict) {
        _ = try await editor.commit(
            ProtectedEditCommitRequest(
                grantID: stale.grantID,
                contents: nil,
                contentsBase64: "eA==",
                expectedVersion: stale.version,
            ),
            descriptors: [],
        )
    }
    check(String(data: FileManager.default.contents(atPath: root + "/etc/hosts")!, encoding: .utf8) == "changed elsewhere\n", "the outside change survives")

    let (plist, _) = try await editor.open(
        ProtectedEditOpenRequest(path: root + "/Library/LaunchDaemons/com.example.plist"),
    )
    check(plist.needsConfirmation, "the open says the plist needs confirmation")
    await expectErrorAsync("an unconfirmed LaunchDaemons save", code: .denied) {
        _ = try await editor.commit(
            ProtectedEditCommitRequest(
                grantID: plist.grantID,
                contents: nil,
                contentsBase64: "eA==",
                expectedVersion: plist.version,
            ),
            descriptors: [],
        )
    }
    let (plistAgain, _) = try await editor.open(
        ProtectedEditOpenRequest(path: root + "/Library/LaunchDaemons/com.example.plist"),
    )
    _ = try await editor.commit(
        ProtectedEditCommitRequest(
            grantID: plistAgain.grantID,
            contents: nil,
            contentsBase64: "eA==",
            expectedVersion: plistAgain.version,
            confirmed: true,
        ),
        descriptors: [],
    )
    check(FileManager.default.contents(atPath: root + "/Library/LaunchDaemons/com.example.plist") == Data("x".utf8), "a confirmed LaunchDaemons save goes through")

    // Backups refuse a Documents swapped for a link.
    let trap = scratchPath + "/trap-home"
    try FileManager.default.createDirectory(atPath: trap, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        atPath: scratchPath + "/elsewhere/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    symlink(scratchPath + "/elsewhere", trap + "/Documents")
    expectError("a backup through a linked Documents", code: .unavailable) { _ = try BackupStore(home: trap).save(path: root + "/etc/hosts") }

    // fileRead scopes.
    let folder = DataFolder(home: home)
    let scopes = FileScopes(installRoot: root, dataFolder: folder)
    write(home + "/Documents/wiki.qaq.apelin/Projects/Hello/apelin-project.json", "{\"projectID\": \"p-1\"}")
    write(home + "/Documents/wiki.qaq.apelin/Projects/Hello/Tweak.x", "%hook\n")
    symlink(scratchPath + "/outside", home + "/Documents/wiki.qaq.apelin/Projects/Hello/escape")
    if case let .directory(path) = try scopes.resolve("p-1", caller: .worker(.agent, instance: "s")) {
        let (file, resolved) = try FileScopes.open("Tweak.x", inside: path)
        check(resolved.hasSuffix("/Projects/Hello/Tweak.x") && file.rawValue >= 0, "a project ID scope reads its file")
        expectError("a link out of the scope", code: .denied) { _ = try FileScopes.open("escape", inside: path) }
        expectError("a .. path", code: .badRequest) { _ = try FileScopes.open("../Hello/Tweak.x", inside: path) }
    } else {
        check(false, "the project ID resolves")
    }
    expectError("a grant scope for a worker", code: .denied) { _ = try scopes.resolve("grant:x", caller: .worker(.agent, instance: "s")) }
}

// MARK: - Managed packages

func record(
    _ id: String = UUID().uuidString.lowercased(),
    package: String,
    version: String,
    status: InstallationRecord.Status = .installed,
    created: Date = Date(),
) -> InstallationRecord {
    InstallationRecord(
        installationID: id,
        origin: .build,
        artifactID: "a",
        artifactDigest: String(repeating: "0", count: 64),
        projectID: "p",
        buildID: "b",
        packageID: package,
        version: version,
        packagingDigest: nil,
        transactionID: UUID().uuidString.lowercased(),
        taskID: nil,
        status: status,
        createdAt: created,
        updatedAt: created,
        followedSeq: 0,
        receipt: status == .installed ? .init(
            state: "succeeded",
            exitStatus: 0,
            packageID: package,
            version: version,
            failure: nil,
            failureText: nil,
            finishedAt: created,
        ) : nil,
        removalTransactionID: nil,
        removalTaskID: nil,
        removalReceipt: nil,
    )
}

do {
    let installed = DpkgStatusDatabase.parse("""
    Package: com.example.tweak
    Status: install ok installed
    Version: 1.0

    Package: bash
    Status: install ok installed
    Priority: required
    Version: 5.2

    Package: com.example.other
    Status: install ok installed
    Version: 2.0

    Package: com.example.gone
    Status: deinstall ok config-files
    Version: 1.0

    Package: com.example.essential
    Essential: yes
    Status: install ok installed
    Version: 1
    """)
    check(installed.count == 5 && installed["bash"]?.priority == "required" && installed["com.example.gone"]?.isInstalled == false, "the dpkg status file parses")

    for reserved in ["wiki.qaq.apelin", "wiki.qaq.apelin.dev.tweak", "wiki.qaq.irisin", "dpkg", "apt", "firmware", "gsc.ipad", "cy+cpu.arm64", "com.example.essential"] {
        expectError("installing \(reserved)", code: .denied) { try ManagedPackagePolicy.checkInstall(packageID: reserved, installed: installed, records: []) }
    }
    expectError("a bad package ID", code: .badRequest) { try ManagedPackagePolicy.checkInstall(packageID: "Bad ID", installed: installed, records: []) }
    expectError("overwriting a package Apelin did not install", code: .conflict) {
        try ManagedPackagePolicy.checkInstall(packageID: "com.example.other", installed: installed, records: [])
    }
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.new", installed: installed, records: [])
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.gone", installed: installed, records: [])
    let ours = record(package: "com.example.tweak", version: "1.0")
    try ManagedPackagePolicy.checkInstall(packageID: "com.example.tweak", installed: installed, records: [ours])
    expectError("upgrading our package after an outside replacement", code: .conflict) {
        try ManagedPackagePolicy.checkInstall(
            packageID: "com.example.tweak",
            installed: installed,
            records: [record(package: "com.example.tweak", version: "0.9")],
        )
    }

    try ManagedPackagePolicy.checkRemoval(ours, installed: installed, records: [ours])
    expectError("removing with no record", code: .notFound) { try ManagedPackagePolicy.checkRemoval(nil, installed: installed, records: []) }
    let replaced = record(package: "com.example.tweak", version: "0.9")
    expectError("removing a package replaced from outside", code: .conflict) { try ManagedPackagePolicy.checkRemoval(replaced, installed: installed, records: [replaced]) }
    let gone = record(package: "com.example.gone", version: "1.0")
    expectError("removing a package no longer installed", code: .conflict) { try ManagedPackagePolicy.checkRemoval(gone, installed: installed, records: [gone]) }
    let failed = record(package: "com.example.tweak", version: "1.0", status: .failed)
    expectError("removing a failed install", code: .denied) { try ManagedPackagePolicy.checkRemoval(failed, installed: installed, records: [failed]) }
    let core = record(package: "bash", version: "5.2")
    expectError("removing a core package even with a record", code: .denied) { try ManagedPackagePolicy.checkRemoval(core, installed: installed, records: [core]) }
    let older = record(package: "com.example.tweak", version: "1.0", created: Date(timeIntervalSinceNow: -60))
    expectError("removing through a superseded record", code: .conflict) { try ManagedPackagePolicy.checkRemoval(older, installed: installed, records: [older, ours]) }
}

// MARK: - Deb control

do {
    let deb = scratchPath + "/peek.deb"
    makeDeb(at: deb, package: "com.example.peek", version: "1.2-3")
    let descriptor = open(deb, O_RDONLY)
    let control = try DebControlPeek.read(descriptor: descriptor)
    close(descriptor)
    check(control == .init(packageID: "com.example.peek", version: "1.2-3", architecture: "iphoneos-arm64e"), "the control file is read from a gzip member")
    write(scratchPath + "/not.deb", "hello")
    let other = open(scratchPath + "/not.deb", O_RDONLY)
    defer { close(other) }
    var refused = false
    do { _ = try DebControlPeek.read(descriptor: other) } catch DebControlPeek.Failure.notADebian { refused = true }
    check(refused, "a file that is not ar is not a deb")
    // dpkg-deb's own output (GNU tar, gzip): the console smoke fixture.
    if let repository = ProcessInfo.processInfo.environment["APELIN_REPOSITORY"] {
        let fixture = open(repository + "/Documents/Console/fixtures/apelin-smoke_1.0_all.deb", O_RDONLY)
        defer { close(fixture) }
        let smoke = try? DebControlPeek.read(descriptor: fixture)
        check(smoke == .init(packageID: "com.example.apelin-smoke", version: "1.0", architecture: "all"), "dpkg-deb's archive reads too")
    }

    // The relations that explain a refused install, each alternative alone.
    let related = try DebControlPeek.parse("""
    Package: com.example.related
    Version: 2
    Conflicts: com.example.old, com.example.Versioned (<< 2.0)
    Breaks: com.example.a | com.example.b:any (>= 1)
    Replaces: com.example.old,
     com.example.folded
    Description: related
     Conflicts: com.example.not-a-field
    """)
    check(related.packageID == "com.example.related" && related.version == "2", "relations leave Package and Version as they were")
    check(related.conflicts == [.init(package: "com.example.old"), .init(package: "com.example.versioned", constraint: "<< 2.0")], "Conflicts is read with its versions, lowercased")
    check(related.breaks == [.init(package: "com.example.a"), .init(package: "com.example.b", constraint: ">= 1")], "Breaks counts each alternative and drops the architecture")
    check(related.replaces.map(\.package) == ["com.example.old", "com.example.folded"], "a folded relation field is read whole, and Description's lines are not fields")
}

// MARK: - Approval ledger

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("approvals"))
    let template = "sha256:" + String(repeating: "a", count: 64)
    let changed = "sha256:" + String(repeating: "b", count: 64)
    try await ledger.recordTemplate(template, kind: .build, project: "p-1")
    try await ledger.recordTemplate("sha256:" + String(repeating: "c", count: 64), kind: .build, project: "p-1")
    let base = try await ledger.state(of: template, kind: .build, project: "p-1")
    check(base.baseline == .matchesTemplate && base.templateDigest == template, "the template digest is the baseline, and the first record wins")
    let before = try await ledger.state(of: changed, kind: .build, project: "p-1")
    check(before.baseline == .changed, "a changed description asks")
    try await ledger.recordApproval(changed, kind: .build, project: "p-1")
    let reloaded = ApprovalLedger(directory: scratch.appendingPathComponent("approvals"))
    let afterApproval = try await reloaded.state(of: changed, kind: .build, project: "p-1")
    check(afterApproval.baseline == .approved && afterApproval.lastApprovedDigest == changed, "an approval is kept on disk")
    let packaging = try await reloaded.state(of: changed, kind: .packaging, project: "p-1")
    check(packaging.baseline == .changed, "approvals are per kind")
    let mode = await reloaded.mode(session: "unknown")
    check(mode == .confirm, "an unknown agent session is held to Confirm")
    await reloaded.allowRemoval(installationID: "i", session: "s")
    let firstTake = await reloaded.takeRemoval(installationID: "i", session: "s")
    let secondTake = await reloaded.takeRemoval(installationID: "i", session: "s")
    check(firstTake && !secondTake, "a removal approval is spent once")
    await expectErrorAsync("a project ID with a slash", code: .badRequest) { _ = try await reloaded.state(of: changed, kind: .build, project: "../x") }
}

// MARK: - Agent notices (AgentNoticeChecks.swift)

await agentNoticeChecks()

// MARK: - One open of a session at a time (AgentOpenChecks.swift)

await agentOpenChecks()

// MARK: - The note that the host restarted (AgentHostRunChecks.swift)

await agentHostRunChecks()

// MARK: - shell_run as root (RootRunChecks.swift)

await rootRunChecks(scratch: scratch, scratchPath: scratchPath)

// MARK: - Ask Before Using the Screen (ScreenConsentChecks.swift)

await screenConsentChecks(scratch: scratch, scratchPath: scratchPath)

// MARK: - Install bridge against a fake irisind

final class FakeIrisin: InstallService, @unchecked Sendable {
    struct Transaction {
        var kind: String
        var package: String?
        var version: String?
        var digest: String?
        var events: [InstallTransactionEvent] = []
        var polls = 0
        var failureText: String?
    }

    let root: String
    let lock = NSLock()
    var transactions: [UUID: Transaction] = [:]
    var submissions = 0
    var duplicates = 0
    var installedVersions: [String: String] = [:]
    var failNext = false
    /// What the next failure says, instead of a digest mismatch.
    var failNextText: String?
    /// The end-to-end toolchain test lays a package's files down when it is
    /// installed (from the submitted descriptor) and takes them away when it
    /// is removed, as irisind would.
    var onInstall: ((Int32) throws -> Void)?
    var onRemove: ((String) -> Void)?

    init(root: String) {
        self.root = root
    }

    func serviceInfo() async throws -> InstallServiceInfo {
        InstallServiceInfo(externalVersion: 1, capabilities: InstallServiceRequirement.capabilities, installRoot: root)
    }

    func submitInstall(transaction: UUID, descriptor: Int32, sha256: String) async throws -> InstallTransactionStatus {
        let control = try? DebControlPeek.read(descriptor: descriptor)
        let actual = try ProtectedEditPolicy.sha256(descriptor: descriptor)
        var unpacked = true
        if let onInstall, actual == "sha256:" + sha256, lock.withLock({ transactions[transaction] == nil && !failNext }) {
            do { try onInstall(descriptor) } catch { unpacked = false }
        }
        return lock.withLock {
            submissions += 1
            if transactions[transaction] != nil {
                duplicates += 1
                return status(transaction, duplicate: true)
            }
            var events = [InstallTransactionEvent(sequence: 1, kind: "started", text: "started")]
            var failureText: String?
            if actual != "sha256:" + sha256 || failNext || !unpacked {
                let text = failNextText ?? "the digest did not match"
                failureText = text
                events.append(
                    InstallTransactionEvent(
                        sequence: 2,
                        kind: "failure",
                        text: text,
                        problem: "installationStopped",
                    ),
                )
                events.append(InstallTransactionEvent(sequence: 3, kind: "exit", text: "exit 1", exitStatus: 1))
                failNext = false
                failNextText = nil
            } else {
                events.append(
                    InstallTransactionEvent(sequence: 2, kind: "phase", text: "verifying", phase: "verifying"),
                )
                events.append(
                    InstallTransactionEvent(
                        sequence: 3,
                        kind: "package",
                        text: "unpacking",
                        step: "unpacking",
                        packageID: control?.packageID,
                        version: control?.version,
                    ),
                )
                events.append(
                    InstallTransactionEvent(sequence: 4, kind: "phase", text: "completed", phase: "completed"),
                )
                events.append(InstallTransactionEvent(sequence: 5, kind: "exit", text: "exit 0", exitStatus: 0))
            }
            transactions[transaction] = Transaction(
                kind: "install",
                package: control?.packageID,
                version: control?.version,
                digest: sha256,
                events: events,
                failureText: failureText,
            )
            return status(transaction, duplicate: false)
        }
    }

    func removePackage(transaction: UUID, packageID: String) async throws -> InstallTransactionStatus {
        if lock.withLock({ transactions[transaction] == nil }) {
            onRemove?(packageID)
        }
        return lock.withLock {
            if transactions[transaction] != nil {
                return status(transaction, duplicate: true)
            }
            transactions[transaction] = Transaction(kind: "remove", package: packageID, events: [
                InstallTransactionEvent(sequence: 1, kind: "started", text: "started"),
                InstallTransactionEvent(
                    sequence: 2,
                    kind: "package",
                    text: "removing",
                    step: "removing",
                    packageID: packageID,
                ),
                InstallTransactionEvent(sequence: 3, kind: "exit", text: "exit 0", exitStatus: 0),
            ])
            return status(transaction, duplicate: false)
        }
    }

    func respring(transaction: UUID) async throws -> InstallTransactionStatus {
        lock.withLock {
            transactions[transaction] = Transaction(
                kind: "respring",
                events: [InstallTransactionEvent(sequence: 1, kind: "exit", text: "exit 0", exitStatus: 0)],
            )
            return status(transaction, duplicate: false)
        }
    }

    func status(of transaction: UUID) async throws -> InstallTransactionStatus {
        try lock.withLock {
            guard transactions[transaction] != nil else { throw InstallServiceError(.notFound) }
            return status(transaction, duplicate: false)
        }
    }

    /// Events come out two at a time, as a running helper's would.
    func events(
        of transaction: UUID,
        after: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent]) {
        try lock.withLock {
            guard var entry = transactions[transaction] else { throw InstallServiceError(.notFound) }
            entry.polls += 1
            transactions[transaction] = entry
            let visible = entry.events.prefix(min(entry.events.count, entry.polls * 2))
            return (
                status(transaction, duplicate: false, visible: visible.count),
                visible.filter { $0.sequence > after },
            )
        }
    }

    private func status(_ transaction: UUID, duplicate: Bool, visible: Int? = nil) -> InstallTransactionStatus {
        let entry = transactions[transaction]!
        let shown = visible ?? 0
        let finished = shown == entry.events.count
        let exit = entry.events.last?.exitStatus
        let state: InstallTransactionState = finished ? (exit == 0 ? .succeeded : .failed) : .running
        if finished, state == .succeeded, entry.kind == "install", let package = entry.package {
            installedVersions[package] = entry.version
        }
        if finished, state == .succeeded, entry.kind == "remove", let package = entry.package {
            installedVersions[package] = nil
        }
        return InstallTransactionStatus(
            transaction: transaction,
            kind: entry.kind,
            state: state,
            nextSequence: UInt64(shown + 1),
            exitStatus: finished ? exit : nil,
            packageID: entry.package,
            version: entry.version,
            failure: state == .failed ? "installationStopped" : nil,
            failureText: state == .failed ? entry.failureText ?? "the digest did not match" : nil,
            duplicate: duplicate,
        )
    }
}

/// The package database as the fake irisind leaves it.
struct FakeDatabase: InstalledPackageSource {
    let irisin: FakeIrisin
    var extra: [String: InstalledPackage] = [:]

    func installedPackages() throws -> [String: InstalledPackage] {
        var result = extra
        irisin.lock.withLock {
            for (package, version) in irisin.installedVersions {
                result[package] = InstalledPackage(
                    packageID: package,
                    version: version,
                    status: "install ok installed",
                    essential: false,
                    priority: "optional",
                )
            }
        }
        return result
    }
}

/// The package database's file lists, as a test lays them out.
struct FakeFileLists: PackageFileLists {
    var lists: [String: [String]] = [:]

    func files(of packageID: String) throws -> [String] {
        lists[packageID] ?? []
    }
}

func waitForEnd(_ registry: TaskRegistry, _ handle: TaskHandle) async throws -> TaskEventBatch {
    var batch = try await registry.attach(
        handle.taskID,
        as: handle.kind.attachOperation,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    for _ in 0 ..< 200 where !batch.finished {
        try await Task.sleep(nanoseconds: 20_000_000)
        batch = try await registry.attach(
            handle.taskID,
            as: handle.kind.attachOperation,
            afterSeq: .start,
            waitMilliseconds: 0,
        )
    }
    return batch
}

// MARK: - Worker events keep their order

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("event-order"))
    await registry.load()
    let build = await registry.create(kind: .build, owner: .build)
    // As the host applies a build worker's events: an artifact is recorded
    // (an await) before it is appended; the final state follows at once.
    // Then the worker exits, which ends whatever it still owns.
    let feed = TaskEventFeed<(kind: String, payload: JSONValue?)> { event in
        if event.kind == "exit" {
            return await registry.ownerExited(role: .build, key: nil)
        }
        if event.kind == "artifact" {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await registry.append(build.taskID, kind: event.kind, payload: event.payload)
    }
    feed.send((kind: "log", payload: .object(["line": .string("linked")])))
    feed.send((kind: "artifact", payload: .object(["artifactID": .string(build.taskID.rawValue)])))
    feed.send((kind: TaskEvent.stateKind, payload: .object(["state": .string(TaskState.succeeded.rawValue)])))
    feed.send((kind: "exit", payload: nil))
    let batch = try await waitForEnd(registry, build)
    check(batch.state == .succeeded, "a worker's exit after its final state does not fail the task")
    check(batch.events.map(\.kind) == ["log", "artifact", "state"], "worker events are appended in the order they came, none dropped after the state")
    check(batch.events.map(\.seq.rawValue) == [1, 2, 3], "worker events are numbered in arrival order")
}

do {
    let base = scratchPath + "/install"
    let data = base + "/home/Documents/wiki.qaq.apelin"
    let state = URL(fileURLWithPath: base + "/state")
    try FileManager.default.createDirectory(atPath: data + "/Projects/Hello/.build", withIntermediateDirectories: true)
    let deb = data + "/Projects/Hello/.build/hello.deb"
    makeDeb(at: deb, package: "com.example.hello", version: "1.0")
    let digest = sha256(deb)

    let irisin = FakeIrisin(root: base)
    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    let artifacts = ArtifactRegistry(file: state.appendingPathComponent("artifacts.json"))
    let installations = InstallationStore(directory: state.appendingPathComponent("installations"))
    let approvals = ApprovalLedger(directory: state.appendingPathComponent("approvals"))
    let extra = [
        "com.example.foreign": InstalledPackage(
            packageID: "com.example.foreign",
            version: "1",
            status: "install ok installed",
            essential: false,
            priority: nil,
        ),
    ]
    func bridge() -> InstallBridge {
        InstallBridge(
            paths: .init(installRoot: base, dataFolder: data, staging: state.appendingPathComponent("staging")),
            service: irisin,
            registry: registry,
            artifacts: artifacts,
            installations: installations,
            packages: FakeDatabase(irisin: irisin, extra: extra),
            fileLists: FakeFileLists(),
            approvals: approvals,
            pollInterval: 0.01,
        )
    }
    let install = bridge()

    let packaging = "sha256:" + String(repeating: "d", count: 64)
    let buildTask = await registry.create(kind: .build, owner: .build, ownerKey: "b")
    let recorded = await artifacts.record(event: .object([
        "artifactID": .string("art-1"),
        "digest": .string(digest),
        "packageID": .string("com.example.hello"),
        "version": .string("1.0"),
        "path": .string(deb),
        "projectID": .string("p-1"),
        "packagingDigest": .string(packaging),
    ]), buildID: buildTask.taskID)
    check(recorded?.buildID == buildTask.taskID.rawValue, "an artifact event is recorded with its build")
    let missing = await artifacts.record(event: .object(["artifactID": .string("x")]), buildID: buildTask.taskID)
    check(missing == nil, "an artifact event without path and digest is not recorded")

    await expectErrorAsync("a wrong digest", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: String(repeating: "e", count: 64)),
            caller: .app,
        )
    }
    await expectErrorAsync("an unknown artifact", code: .notFound) {
        _ = try await install.install(InstallPackageRequest(artifactID: "nope", digest: digest), caller: .app)
    }
    await expectErrorAsync("a file install from the agent", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:Projects/Hello/.build/hello.deb", digest: digest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    await expectErrorAsync("an agent install of a changed packaging description", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: "sha256:" + digest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    await expectErrorAsync("an install from the build worker", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: digest),
            caller: .worker(.build, instance: "b"),
        )
    }

    // Approved: the agent's install goes through, bound to the packaging digest.
    try await approvals.recordApproval(packaging, kind: .packaging, project: "p-1")
    let handle = try await install.install(
        InstallPackageRequest(artifactID: "art-1", digest: "sha256:" + digest),
        caller: .worker(.agent, instance: "s"),
    )
    let batch = try await waitForEnd(registry, handle)
    check(batch.state == .succeeded, "the install succeeds (\(batch.events.last?.payload?["message"]?.stringValue ?? ""))")
    let irisinEvents = batch.events.filter { $0.kind == "irisin" }.compactMap { $0.payload?["seq"]?.doubleValue }
    check(irisinEvents == [1, 2, 3, 4, 5], "every irisind event is relayed once, in order")
    let result = try batch.events.first { $0.kind == "result" }?.payload?.decode(InstallResult.self)
    check(result?.packageID == "com.example.hello" && result?.projectID == "p-1" && result?.artifactDigest == digest, "the result names the package, project and digest")
    let stored = await installations.record(result?.installationID ?? "")
    check(stored?.status == .installed && stored?.receipt?.state == "succeeded" && stored?.transactionID == result?.transactionID, "the installation record keeps the receipt")
    check(stored.map { UUID(uuidString: $0.transactionID) != nil && $0.transactionID == $0.transactionID.lowercased() } == true, "the transaction ID is a lowercase UUID")
    check((try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("staging").path))?.isEmpty ?? true, "the staged copy is removed after the run")

    // A package someone else installed is not overwritten, a core one never.
    let foreign = data + "/foreign.deb"
    makeDeb(at: foreign, package: "com.example.foreign", version: "2")
    await expectErrorAsync("overwriting a foreign package", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:foreign.deb", digest: sha256(foreign)),
            caller: .app,
        )
    }
    let core = data + "/core.deb"
    makeDeb(at: core, package: "wiki.qaq.irisin", version: "9")
    await expectErrorAsync("installing the install service", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:core.deb", digest: sha256(core)),
            caller: .app,
        )
    }
    symlink(scratchPath + "/peek.deb", data + "/linked.deb")
    await expectErrorAsync("a file through a link out of the data folder") {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "file:linked.deb", digest: sha256(scratchPath + "/peek.deb")),
            caller: .app,
        )
    }

    // Removal: the agent needs this removal approved; the app does not.
    let installationID = result!.installationID
    await expectErrorAsync("an unapproved agent removal", code: .denied) {
        _ = try await install.remove(
            RemovePackageRequest(installationID: installationID),
            caller: .worker(.agent, instance: "s"),
        )
    }
    // The session asks the way apelin-agent does (its EventRelay test holds
    // the same payload), the app approves, and the host grants it once.
    let removalSession = await AgentSessionTable.Entry(
        sessionID: "s",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "s"),
        project: ResolvedProject(id: "p-1", name: "Hello", path: data + "/Projects/Hello"),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(removalSession)
    await registry.append(removalSession.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("remove-hello"),
        "tool": .string("apelin_package_remove"),
        "arguments": .string(#"{"installation_id":"\#(installationID)"}"#),
        "detail": .object(["packageRemoval": .object(["installationID": .string(installationID)])]),
    ]))
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: "s", approvalID: "remove-hello", decision: .approve),
        registry: registry,
        ledger: approvals,
        forward: { true },
        accepted: { $0 },
    )
    let removal = try await install.remove(
        RemovePackageRequest(installationID: installationID),
        caller: .worker(.agent, instance: "s"),
    )
    let removed = try await waitForEnd(registry, removal)
    check(removed.state == .succeeded && removed.events.contains { $0.kind == "removed" }, "the removal succeeds")
    let removalLeft = await approvals.takeRemoval(installationID: installationID, session: "s")
    check(!removalLeft, "an approved removal is spent by the removal it allowed")
    // The environment worker's toolchain package: its own source, its own
    // package family, and its own records only.
    let artifactsFolder = data + "/Environment/Artifacts"
    try FileManager.default.createDirectory(atPath: artifactsFolder, withIntermediateDirectories: true)
    makeDeb(
        at: artifactsFolder + "/toolchain-abc123.deb",
        package: "wiki.qaq.apelin.toolchain.abc123",
        version: "16.0+abc123",
    )
    let toolchainDigest = sha256(artifactsFolder + "/toolchain-abc123.deb")
    let environmentCaller = Caller.worker(.environment, instance: nil)
    await expectErrorAsync("the environment worker installing a build artifact", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "art-1", digest: digest),
            caller: environmentCaller,
        )
    }
    await expectErrorAsync("the environment worker removing a project package", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: installationID), caller: environmentCaller)
    }
    await expectErrorAsync("the agent installing a toolchain", code: .denied) {
        _ = try await install.install(
            InstallPackageRequest(artifactID: "toolchain-abc123", digest: toolchainDigest),
            caller: .worker(.agent, instance: "s"),
        )
    }
    let toolchainHandle = try await install.install(
        InstallPackageRequest(artifactID: "toolchain-abc123", digest: toolchainDigest),
        caller: environmentCaller,
    )
    let toolchainBatch = try await waitForEnd(registry, toolchainHandle)
    let toolchainResult = try toolchainBatch.events.first { $0.kind == "result" }?.payload?.decode(InstallResult.self)
    check(toolchainBatch.state == .succeeded && toolchainResult?.packageID == "wiki.qaq.apelin.toolchain.abc123", "a toolchain package installs from Environment/Artifacts")
    makeDeb(at: artifactsFolder + "/toolchain-evil.deb", package: "bash", version: "9")
    await expectErrorAsync("a toolchain artifact that is another package", code: .conflict) {
        _ = try await install.install(
            InstallPackageRequest(
                artifactID: "toolchain-evil",
                digest: sha256(artifactsFolder + "/toolchain-evil.deb"),
            ),
            caller: environmentCaller,
        )
    }
    expectError("a toolchain-family package from a project", code: .denied) {
        try ManagedPackagePolicy.checkInstall(
            packageID: "wiki.qaq.apelin.toolchain.abc123",
            origin: .build,
            installed: [:],
            records: [],
        )
    }
    let toolchainRemoval = try await install.remove(
        RemovePackageRequest(installationID: toolchainResult!.installationID),
        caller: environmentCaller,
    )
    let toolchainRemoved = try await waitForEnd(registry, toolchainRemoval)
    check(toolchainRemoved.state == .succeeded, "the environment worker removes its toolchain package")

    let afterRemoval = await installations.record(installationID)
    check(afterRemoval?.status == .removed, "the record says removed")
    await expectErrorAsync("removing twice", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: installationID), caller: .app)
    }

    // Resume: a host that stopped after staging submits again under the same
    // transaction ID; irisind answers dup and installs nothing twice.
    let resumeDeb = data + "/resume.deb"
    makeDeb(at: resumeDeb, package: "com.example.resume", version: "1")
    let resumeHandle = try await install.install(
        InstallPackageRequest(artifactID: "file:resume.deb", digest: sha256(resumeDeb)),
        caller: .app,
    )
    _ = try await waitForEnd(registry, resumeHandle)
    let resumeBatch = try await registry.attach(
        resumeHandle.taskID,
        as: .buildAttach,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    let resumeID = try resumeBatch.events.first { $0.kind == "result" }!
        .payload!.decode(InstallResult.self).installationID
    // Rewind the record to "submitted" with nothing followed, and the task to running, as a crash would leave them.
    try await installations.update(resumeID) { $0.status = .submitted; $0.followedSeq = 0 }
    let crashed = await registry.create(kind: .install, owner: nil)
    await registry.setResume(crashed.taskID, .object(["installationID": .string(resumeID)]))
    let submissionsBefore = irisin.lock.withLock { irisin.submissions }
    let fresh = bridge()
    let picked = await fresh.resume(registry.record(crashed.taskID)!)
    check(picked, "an install task with resume data is picked up")
    let resumedBatch = try await waitForEnd(registry, crashed)
    check(resumedBatch.state == .succeeded, "the resumed install finishes")
    check(irisin.lock.withLock { irisin.submissions } == submissionsBefore, "a submitted install is followed, not submitted again")

    try await installations.update(resumeID) { $0.status = .staged; $0.followedSeq = 0 }
    try? FileManager.default.createDirectory(
        at: state.appendingPathComponent("staging"),
        withIntermediateDirectories: true,
    )
    try FileManager.default.copyItem(
        atPath: resumeDeb,
        toPath: state.appendingPathComponent("staging/\(resumeID).deb").path,
    )
    let crashedAgain = await registry.create(kind: .install, owner: nil)
    await registry.setResume(crashedAgain.taskID, .object(["installationID": .string(resumeID)]))
    let duplicatesBefore = irisin.lock.withLock { irisin.duplicates }
    _ = await bridge().resume(registry.record(crashedAgain.taskID)!)
    let again = try await waitForEnd(registry, crashedAgain)
    check(again.state == .succeeded && irisin.lock.withLock { irisin.duplicates } == duplicatesBefore + 1, "a staged install is submitted again under its own ID and answered dup")

    // The list: per package still installed, its newest record, and whether
    // this caller's removal would act on it. An agent in Relaxed mode, so
    // only the bridge's own rules decide.
    func installedResult(_ handle: TaskHandle) async throws -> InstallResult? {
        try await waitForEnd(registry, handle).events.first { $0.kind == "result" }?.payload?.decode(InstallResult.self)
    }
    let lister = Caller.worker(.agent, instance: "lister")
    await approvals.setMode(.relaxed, session: "lister")
    let older = try await installedResult(install.install(InstallPackageRequest(artifactID: "art-1", digest: digest), caller: .app))
    let newer = try await installedResult(install.install(InstallPackageRequest(artifactID: "art-1", digest: digest), caller: .app))
    let hello = try await install.list(InstallationListRequest(packageID: "com.example.hello"), caller: lister)
    check(hello.installations.map(\.installationID) == [newer?.installationID ?? "-"], "a package installed twice is listed once, by its newest installation")
    check(hello.installations.first.map { $0.removable && $0.reason == nil && $0.projectID == "p-1" && $0.buildID == buildTask.taskID.rawValue && $0.version == "1.0" } == true, "the row names the version, project and build, removable")
    do {
        _ = try await install.remove(RemovePackageRequest(installationID: older?.installationID ?? "-"), caller: .app)
        check(false, "a superseded installation is not removed")
    } catch let error as ApelinError {
        check(error.code == .conflict && error.message.contains(newer?.installationID ?? "-"), "the refusal of a superseded installation names the newer one")
    }
    let everything = try await install.list(InstallationListRequest(), caller: lister)
    check(everything.installations.map(\.packageID) == ["com.example.hello", "com.example.resume"], "every package still installed is listed, newest first (\(everything.installations.map(\.packageID)))")
    // The agent installs build artifacts only, and removes only those.
    let fileForAgent = everything.installations.first { $0.packageID == "com.example.resume" }
    check(fileForAgent.map { !$0.removable && ($0.reason ?? "").contains("from a file") } == true, "the agent sees a file the app installed as not its to remove")
    let fileForApp = try await install.list(InstallationListRequest(packageID: "com.example.resume"), caller: .app)
    check(fileForApp.installations.first?.removable == true, "the app sees that file's package as removable")
    await expectErrorAsync("the agent removing a file the app installed", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: resumeID), caller: lister)
    }
    let byProject = try await install.list(InstallationListRequest(projectID: "p-1"), caller: lister)
    let otherProject = try await install.list(InstallationListRequest(projectID: "p-2"), caller: lister)
    check(byProject.installations.map(\.packageID) == ["com.example.hello"] && otherProject.installations.isEmpty, "the list is filtered by project")

    irisin.lock.withLock { irisin.installedVersions["com.example.hello"] = "2.0" }
    let replaced = try await install.list(InstallationListRequest(packageID: "com.example.hello"), caller: lister)
    check(replaced.installations.first.map { !$0.removable && ($0.reason ?? "").contains("now version 2.0") } == true, "a package changed outside Apelin is listed as not removable, with the refusal")
    irisin.lock.withLock { irisin.installedVersions["com.example.hello"] = "1.0" }

    // A removal under way is the package's newest record: the install
    // before it is not offered while it runs.
    try await installations.update(newer?.installationID ?? "-") { $0.status = .removing }
    let removing = try await install.list(InstallationListRequest(packageID: "com.example.hello"), caller: lister)
    check(removing.installations.map(\.installationID) == [newer?.installationID ?? "-"] && removing.installations.first?.removable == false, "a package being removed is listed by that removal, not removable")
    try await installations.update(newer?.installationID ?? "-") { $0.status = .installed }

    let failing = data + "/failing.deb"
    makeDeb(at: failing, package: "com.example.failing", version: "1")
    irisin.lock.withLock { irisin.failNext = true }
    let failed = try await install.install(InstallPackageRequest(artifactID: "file:failing.deb", digest: sha256(failing)), caller: .app)
    let failedState = try await waitForEnd(registry, failed).state
    check(failedState == .failed, "the failing install fails")
    // Even with the package on the device (installed some other way since).
    irisin.lock.withLock { irisin.installedVersions["com.example.failing"] = "1" }
    let failedListed = try await install.list(InstallationListRequest(packageID: "com.example.failing"), caller: .app)
    check(failedListed.installations.isEmpty, "a failed install is not listed")
    irisin.lock.withLock { irisin.installedVersions["com.example.failing"] = nil }

    // A toolchain is the app's or the environment worker's to remove, never
    // the agent's, whatever its mode.
    let toolchain = try await installedResult(install.install(
        InstallPackageRequest(artifactID: "toolchain-abc123", digest: toolchainDigest),
        caller: environmentCaller,
    ))
    let toolchainForAgent = try await install.list(
        InstallationListRequest(packageID: "wiki.qaq.apelin.toolchain.abc123"),
        caller: lister,
    )
    let toolchainForApp = try await install.list(InstallationListRequest(packageID: "wiki.qaq.apelin.toolchain.abc123"), caller: .app)
    check(toolchainForAgent.installations.first.map { !$0.removable && ($0.reason ?? "").contains("Settings") } == true, "the agent sees a toolchain as not its to remove")
    check(toolchainForApp.installations.first?.removable == true, "the app sees the toolchain as removable")
    await expectErrorAsync("the agent removing a toolchain", code: .denied) {
        _ = try await install.remove(RemovePackageRequest(installationID: toolchain?.installationID ?? "-"), caller: lister)
    }

    let removedNewer = try await install.remove(RemovePackageRequest(installationID: newer?.installationID ?? "-"), caller: lister)
    let removedState = try await waitForEnd(registry, removedNewer).state
    check(removedState == .succeeded, "the agent removes the newest installation")
    let gone = try await install.list(InstallationListRequest(packageID: "com.example.hello"), caller: lister)
    check(gone.installations.isEmpty, "a removed package is not listed")
}

// MARK: - A refused install names the package in its way

do {
    let root = scratchPath + "/dpkg-root"
    let info = root + "/var/lib/dpkg/info"
    write(info + "/com.example.listed.list", "/.\n/Library\n/Library/Listed.dylib\n")
    symlink(info + "/com.example.listed.list", info + "/com.example.linked.list")
    let lists = DpkgFileLists(installRoot: root)
    let listed = try lists.files(of: "Com.Example.Listed")
    check(listed == ["/Library", "/Library/Listed.dylib"], "a dpkg list is read by the lowercased name, without its root")
    let unlisted = try lists.files(of: "com.example.unlisted")
    check(unlisted.isEmpty, "a package with no list lists nothing")
    write(info + "/com.example.empty.list", "")
    let empty = try lists.files(of: "com.example.empty")
    check(empty.isEmpty, "an empty list is read as one")
    expectError("a list that is a link", code: .unavailable) { _ = try lists.files(of: "com.example.linked") }
}

do {
    let base = scratchPath + "/conflicts"
    let data = base + "/home/Documents/wiki.qaq.apelin"
    let state = URL(fileURLWithPath: base + "/state")
    try FileManager.default.createDirectory(atPath: data + "/Builds", withIntermediateDirectories: true)
    let irisin = FakeIrisin(root: base)
    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    let artifacts = ArtifactRegistry(file: state.appendingPathComponent("artifacts.json"))
    let installations = InstallationStore(directory: state.appendingPathComponent("installations"))
    let dylib = "/Library/MobileSubstrate/DynamicLibraries/DockFlip.dylib"
    let foreignDylib = "/Library/MobileSubstrate/DynamicLibraries/Foreign.dylib"
    // DockFlip before its rename, which Apelin installed.
    let renamed = record(package: "local.apelin.dockflip", version: "0.1")
    try await installations.save(renamed)
    let installed = Dictionary(uniqueKeysWithValues: [
        ("local.apelin.dockflip", "0.1"), ("com.example.foreign", "2.0"), ("local.apelin.old", "1.0"),
        ("local.apelin.versioned", "1.0"), ("local.apelin.taken", "1.0"), ("mobilesubstrate", "0.9"),
    ].map { id, version in
        (id, InstalledPackage(packageID: id, version: version, status: "install ok installed", essential: false, priority: nil))
    })
    let bridge = InstallBridge(
        paths: .init(installRoot: base, dataFolder: data, staging: state.appendingPathComponent("staging")),
        service: irisin,
        registry: registry,
        artifacts: artifacts,
        installations: installations,
        packages: FakeDatabase(irisin: irisin, extra: installed),
        fileLists: FakeFileLists(lists: [
            "local.apelin.dockflip": ["/Library", dylib, "/Library/MobileSubstrate/DynamicLibraries/DockFlip.plist"],
            "com.example.foreign": [foreignDylib],
            "local.apelin.taken": ["/usr/lib/libtaken.dylib"],
            "mobilesubstrate": ["/usr/lib/libsubstrate.dylib"],
        ]),
        approvals: ApprovalLedger(directory: state.appendingPathComponent("approvals")),
        pollInterval: 0.01,
    )

    // `package` as a build reports it, installed by the app, and irisind
    // refusing it with `text`: the task's conflicts and its last words.
    func refused(
        _ package: String,
        files: [String]?,
        fields: String = "",
        text: String,
    ) async throws -> (conflicts: [InstallConflict], message: String) {
        let deb = data + "/Builds/\(package).deb"
        makeDeb(at: deb, package: package, version: "1.0", fields: fields)
        let digest = sha256(deb)
        let build = await registry.create(kind: .build, owner: .build, ownerKey: "b")
        var event: [String: JSONValue] = [
            "artifactID": .string(package), "digest": .string(digest), "packageID": .string(package),
            "version": .string("1.0"), "path": .string(deb), "projectID": .string("p-2"),
        ]
        if let files {
            event["packageFiles"] = .array(files.map(JSONValue.string))
        }
        await artifacts.record(event: .object(event), buildID: build.taskID)
        irisin.lock.withLock {
            irisin.failNext = true
            irisin.failNextText = text
        }
        let handle = try await bridge.install(InstallPackageRequest(artifactID: package, digest: digest), caller: .app)
        let batch = try await waitForEnd(registry, handle)
        check(batch.state == .failed, "\(package): the refused install fails")
        let conflicts = try batch.events.filter { $0.kind == "conflict" }.map { try $0.payload!.decode(InstallConflict.self) }
        return (conflicts, batch.events.last?.payload?["message"]?.stringValue ?? "")
    }

    // A package renamed from one Apelin installed: that installation, to remove.
    let owned = "\(dylib) is owned by local.apelin.dockflip; Replaces is required"
    let rename = try await refused("local.apelin.flipdock", files: [dylib], text: owned)
    check(rename.conflicts == [InstallConflict(relation: .file, file: dylib, packageID: "local.apelin.dockflip", version: "0.1", installationID: renamed.installationID, projectID: "p")], "the renamed package's installation is named (\(rename.conflicts))")
    check(rename.message == "\(dylib) already belongs to local.apelin.dockflip 0.1, which Apelin installed (installation \(renamed.installationID)). Remove that installation first, then install again. Irisin reported: \(owned)", "the message names the package and the removal, then irisind's words (\(rename.message))")

    // Conflicts and Breaks without a version name an installed package; a
    // versioned one, an absent one and a file the package Replaces do not.
    let conflicting = "Conflicting final packages: local.apelin.newer, local.apelin.old"
    let declared = try await refused(
        "local.apelin.newer",
        files: ["/usr/lib/libtaken.dylib"],
        fields: "Conflicts: local.apelin.old, local.apelin.versioned (<< 0.5)\nBreaks: local.apelin.absent | local.apelin.old\nReplaces: local.apelin.taken\n",
        text: conflicting,
    )
    check(declared.conflicts.map(\.relation) == [.conflicts, .breaks] && declared.conflicts.allSatisfy { $0.packageID == "local.apelin.old" && $0.installationID == nil }, "Conflicts and Breaks name the installed package (\(declared.conflicts))")
    check(declared.message == "This package's Conflicts names local.apelin.old 1.0, which is installed. The installer does not remove it: remove it with your preferred package manager first, then install again. Irisin reported: \(conflicting)", "one sentence for the package, the installer's limit and the fix (\(declared.message))")

    // A file another source installed: no installation, the package manager's to remove.
    let foreign = try await refused("local.apelin.copy", files: [foreignDylib], text: "\(foreignDylib) is owned by com.example.foreign; Replaces is required")
    check(foreign.conflicts == [InstallConflict(relation: .file, file: foreignDylib, packageID: "com.example.foreign", version: "2.0")], "a foreign owner has no installation")
    check(foreign.message.hasPrefix("\(foreignDylib) already belongs to com.example.foreign 2.0, which Apelin did not install. Remove it with your preferred package manager first, then install again. Add com.example.foreign to this package's Replaces only if"), "a foreign owner is the package manager's to remove (\(foreign.message))")

    // A protected package is never offered for removal.
    let core = try await refused("local.apelin.shim", files: ["/usr/lib/libsubstrate.dylib"], text: "owned")
    check(core.message.hasPrefix("/usr/lib/libsubstrate.dylib already belongs to mobilesubstrate 0.9, a protected system package. Leave that file out of this package"), "a protected owner's file is left out instead (\(core.message))")

    // An upgrade of the package itself is not in its own way.
    let upgrade = try await refused("local.apelin.dockflip", files: [dylib], text: "the preinst failed")
    check(upgrade.conflicts.isEmpty && upgrade.message == "the preinst failed", "a package does not conflict with itself")

    // A build recorded before its files were: irisind's words alone.
    let older = try await refused("local.apelin.plain", files: nil, text: "\(dylib) is owned by local.apelin.dockflip; Replaces is required")
    check(older.conflicts.isEmpty && older.message == "\(dylib) is owned by local.apelin.dockflip; Replaces is required", "without the package's files the message is irisind's (\(older.message))")
}

// MARK: - Removed toolchains leave no folders behind (ToolchainPruneChecks.swift)

try await toolchainPruneChecks()

// MARK: - Toolchain setup end to end

if let harness = ProcessInfo.processInfo.environment["APELIN_ENVIRONMENT_HARNESS"], !harness.isEmpty {
    try await toolchainEndToEnd(harness: harness)
} else {
    print("skip: toolchain setup end to end (APELIN_ENVIRONMENT_HARNESS is not set)")
}

// MARK: - Tool attachment copies

do {
    let copies = AttachmentCopies(directory: URL(fileURLWithPath: scratchPath + "/attachments"))
    let source = scratchPath + "/attachment-source"
    write(source, "attachment bytes\n")
    let writable = open(source, O_RDWR)
    defer { close(writable) }

    let copy = try copies.copy(writable, maximumBytes: 1024)
    var info = stat()
    check(fstat(copy.descriptor.rawValue, &info) == 0 && info.st_nlink == 0, "a copy has no name left")
    check(fcntl(copy.descriptor.rawValue, F_GETFL) & O_ACCMODE == O_RDONLY, "a copy is read-only to its receiver")
    var byte: UInt8 = 0x41
    check(pwrite(copy.descriptor.rawValue, &byte, 1, 0) < 0, "writing through a copy fails")
    check(copy.byteCount == 17, "a copy is the whole file")
    check(copy.sha256 == "sha256:" + sha256(source), "a copy's digest is its bytes'")
    _ = "changed".withCString { pwrite(writable, $0, strlen($0), 0) }
    var buffer = [UInt8](repeating: 0, count: 32)
    let count = pread(copy.descriptor.rawValue, &buffer, buffer.count, 0)
    check(String(decoding: buffer.prefix(max(0, count)), as: UTF8.self) == "attachment bytes\n", "the sender changing its file afterwards does not reach the copy")
    check((try? FileManager.default.contentsOfDirectory(atPath: scratchPath + "/attachments"))?.isEmpty == true, "nothing is left in the copies' directory")
    let mode = (
        try? FileManager.default.attributesOfItem(atPath: scratchPath + "/attachments")[.posixPermissions] as? NSNumber,
    )?.intValue
    check(mode == 0o700, "the copies' directory is private")

    expectError("a file over the bound is refused", code: .badRequest) { _ = try copies.copy(writable, maximumBytes: 4) }
    let directory = open(scratchPath, O_RDONLY)
    expectError("a directory is refused", code: .badRequest) { _ = try copies.copy(directory, maximumBytes: 1024) }
    close(directory)
    let writeOnly = open(source, O_WRONLY)
    expectError("a descriptor the host cannot read is refused", code: .badRequest) { _ = try copies.copy(writeOnly, maximumBytes: 1024) }
    close(writeOnly)

    write(scratchPath + "/attachments/attachment.left", "x")
    copies.sweep()
    check(!FileManager.default.fileExists(atPath: scratchPath + "/attachments/attachment.left"), "a copy a dead host left is swept")

    try? FileManager.default.createSymbolicLink(
        atPath: scratchPath + "/attachments-link",
        withDestinationPath: scratchPath + "/attachments",
    )
    let linked = AttachmentCopies(directory: URL(fileURLWithPath: scratchPath + "/attachments-link"))
    expectError("a symlinked copies' directory is refused", code: .unavailable) { _ = try linked.copy(writable, maximumBytes: 1024) }
}

// MARK: - Credentials and a real terminal

do {
    let mine = ProcessCredentials(pid: getpid())
    check(mine?.matches(SpawnIdentity(uid: getuid(), gid: getgid())) == true, "the kernel's credentials for this process read back")
    check(mine?.matches(.mobile) == (getuid() == 501 && getgid() == 501), "a process that is not mobile does not pass for mobile")

    let launch = TerminalSession.Launch(
        shell: "/bin/sh",
        arguments: ["-i"],
        environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "HOME": scratchPath, "PS1": "$ "],
        identity: nil,
        workingDirectory: scratchPath,
        fallbackDirectory: "/",
        columns: 80,
        rows: 24,
    )
    let queue = DispatchQueue(label: "terminal-test")
    let session = try TerminalSession.spawn(launch, queue: queue)
    let output = NSMutableData()
    let ended = DispatchSemaphore(value: 0)
    var exitStatus: Int32 = -1
    session.start(onOutput: { output.append($0) }, onExit: { exitStatus = $0; ended.signal() })
    let peer = try session.attachPeer()
    _ = "echo apelin-$((40+2)); pwd; exit 3\n".withCString { Darwin.write(peer, $0, strlen($0)) }
    check(ended.wait(timeout: .now() + 10) == .success, "the shell exits")
    let text = queue.sync { String(decoding: output as Data, as: UTF8.self) }
    check(text.contains("apelin-42"), "input through the attached socket reaches the shell, output comes back")
    check(text.contains(scratchPath) || text.contains(scratch.path), "the shell starts in the working directory")
    check((exitStatus >> 8) & 0xFF == 3, "the exit status is reported")
    close(peer)
}

// MARK: - The terminal's git takes no bare repository it was not told of

do {
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: scratchPath,
        directory: scratchPath,
        columns: 80,
        rows: 24,
    )
    let environment = launch.environment
    let protected = environment.filter { $0.key.hasPrefix("GIT_CONFIG_") }
    check(protected == [
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "safe.bareRepository",
        "GIT_CONFIG_VALUE_0": "explicit",
    ], "the terminal's login environment sets safe.bareRepository=explicit as protected config, and nothing else")

    // A bare layout the agent's files could have made, with a pager in its
    // config: the real git finds it from inside without the setting, and
    // refuses it with the terminal's environment.
    let bare = scratchPath + "/terminal-bare/sub"
    write(bare + "/HEAD", "ref: refs/heads/main\n")
    write(bare + "/objects/info/.keep", "")
    write(bare + "/refs/heads/.keep", "")
    write(bare + "/config", "[core]\n\tbare = true\n\tpager = touch pager-ran\n")
    func gitDirectory(_ extra: [String: String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--absolute-git-dir"]
        process.currentDirectoryURL = URL(fileURLWithPath: bare + "/objects")
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": scratchPath,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CEILING_DIRECTORIES": scratchPath + "/terminal-bare",
        ].merging(extra) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }
    let found = gitDirectory([:])
    check(found.status == 0 && found.output.contains("terminal-bare/sub"),
          "git takes the bare layout as a repository: \(found.output)")
    let refused = gitDirectory(protected)
    check(refused.status != 0 && refused.output.contains("bare repository"),
          "with the terminal's environment git refuses it: \(refused.output)")
}

// MARK: - The terminal and shell_run get the project's toolchain and SDK

/// A home whose data folder registers a toolchain (installed beside it, as
/// irisind puts one under the install root) and two SDKs, and a project
/// bound to the older SDK. The records carry an installation ID and an
/// origin with a credential in it, neither of which may reach a variable.
let developmentHome = scratchPath + "/development-home"
let developmentData = developmentHome + "/Documents/wiki.qaq.apelin"
let developmentToolchain = scratchPath + "/development-jb/usr/lib/apelin/toolchains/clt-27.0"
let developmentBin = developmentToolchain + "/usr/bin"
let developmentNewSDK = developmentData + "/SDKs/iphoneos27.0-1a2b3c4d"
let developmentOldSDK = developmentData + "/SDKs/iphoneos18.5-5e6f7a8b"
let developmentProject = developmentData + "/Projects/Env"
write(developmentBin + "/clang", "#!/bin/sh\n", mode: 0o755)
for (id, version, path) in [("iphoneos27.0-1a2b3c4d", "27.0", developmentNewSDK), ("iphoneos18.5-5e6f7a8b", "18.5", developmentOldSDK)] {
    write(path + "/SDKSettings.json", "{}")
    write(
        developmentData + "/SDKs/.registry/\(id).json",
        #"{"id":"\#(id)","canonicalName":"\#(id)","version":"\#(version)","path":"\#(path)","targets":[],"warnings":[],"digest":"1a"}"#,
    )
}

write(
    developmentData + "/Environment/Toolchains/registry.json",
    #"{"defaultID":"clt-27.0","toolchains":[{"id":"clt-27.0","version":"27.0","components":[{"kind":"c","selfCheckPassed":true}],"path":"\#(developmentToolchain)","contentDigest":"ab","installationID":"inst-secret","origin":"082-1 https://user:tok3n@example.invalid/p"}]}"#,
)
write(
    developmentProject + "/apelin-project.json",
    #"{"projectID":"p-env","deploymentTarget":"15.0","environment":{"toolchain":{"id":"clt-27.0"},"sdk":{"id":"iphoneos18.5-5e6f7a8b"}}}"#,
)

do {
    // Outside a project: the default toolchain and the newest SDK it reads.
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: developmentHome,
        directory: developmentHome,
        columns: 80,
        rows: 24,
    )
    let environment = launch.environment
    let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    check(path.first == developmentBin, "the terminal's PATH starts with the default toolchain's tools: \(path)")
    check(path.dropFirst().first == "/usr/local/bin" && path.contains("/usr/bin"), "then the bootstrap's and the system's directories: \(path)")
    check(environment["SDKROOT"] == developmentNewSDK, "SDKROOT is the newest SDK it reads: \(String(describing: environment["SDKROOT"]))")
    check(environment["IPHONEOS_DEPLOYMENT_TARGET"] == "16.0", "outside a project the deployment target is Apelin's default")
    check(environment["APELIN_TOOLCHAIN_BIN"] == developmentBin, "the toolchain is named for the login profile snippet")
    check(environment.values.allSatisfy { !$0.contains("tok3n") && !$0.contains("inst-secret") }, "no record field but paths reaches the terminal")
    check(environment["GIT_CONFIG_KEY_0"] == "safe.bareRepository", "the terminal keeps its protected git config")
}

do {
    // In a project: what it binds, the same for the terminal and shell_run.
    let launch = try TerminalHost.launch(
        installRoot: "/",
        home: developmentHome,
        directory: developmentProject,
        project: developmentProject,
        columns: 80,
        rows: 24,
    )
    check(launch.environment["SDKROOT"] == developmentOldSDK, "a project's terminal has the SDK the project binds")
    check(launch.environment["IPHONEOS_DEPLOYMENT_TARGET"] == "15.0", "and its deployment target")

    let project = ResolvedProject(id: "p-env", name: "Env", path: developmentProject)
    let entries = AgentRunCode.environment(preset: nil, project: project, installRoot: "/var/jb", home: developmentHome)
    let variables = Dictionary(entries.map { entry in
        let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }) { first, _ in first }
    check(entries.count == variables.count, "shell_run gets each variable once: \(entries)")
    check(variables["PATH"] == "\(developmentBin):/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/local/bin:/usr/bin:/bin",
          "shell_run's PATH is the toolchain's tools, then its search path: \(String(describing: variables["PATH"]))")
    check(variables["SDKROOT"] == developmentOldSDK && variables["IPHONEOS_DEPLOYMENT_TARGET"] == "15.0",
          "shell_run has the project's SDK and deployment target, as its terminal does")
    check(variables["HOME"] == developmentHome && variables["APELIN_PROJECT_ROOT"] == developmentProject && variables["TMPDIR"] == "/var/jb/var/tmp",
          "and what it had before")
    check(entries.allSatisfy { !$0.contains("tok3n") && !$0.contains("inst-secret") }, "no record field but paths reaches shell_run")

    // A temporary chat binds nothing: the defaults.
    let temporary = ResolvedProject(id: "temporary:\(UUID().uuidString)", name: "t", path: developmentProject)
    let general = AgentRunCode.environment(preset: nil, project: temporary, installRoot: "/", home: developmentHome)
    check(general.contains("SDKROOT=\(developmentNewSDK)") && general.contains("IPHONEOS_DEPLOYMENT_TARGET=16.0"),
          "a temporary chat's shell_run has the default toolchain's SDK: \(general)")

    // A preset is a read-only command the host chose the words of: its own
    // short list, no compiler on its path.
    let preset = AgentRunCode.Preset(argv: ["/bin/ls"], environment: ["GIT_PAGER=cat"])
    let presetEntries = AgentRunCode.environment(preset: preset, project: project, installRoot: "/var/jb", home: developmentHome)
    check(presetEntries.first == "GIT_PAGER=cat", "a preset's own environment comes first")
    check(presetEntries.contains("PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/local/bin:/usr/bin:/bin"), "a preset keeps the bare search path")
    check(!presetEntries.contains { $0.hasPrefix("SDKROOT=") || $0.hasPrefix("APELIN_TOOLCHAIN_BIN=") || $0.contains(developmentBin) },
          "and no toolchain or SDK: \(presetEntries)")
}

// MARK: - shell_run's argv finds a command where its shell would

/// A toolchain of its own: a compiler, a link to bash standing in for
/// clang++ (a tool that reads the name it was called by), and a git that
/// is not the bootstrap's; and a project with a script and a plain file.
let lookupHome = scratchPath + "/lookup-home"
let lookupToolchain = scratchPath + "/lookup-jb/toolchains/clt-27.0"
let lookupBin = lookupToolchain + "/usr/bin"
let lookupProject = lookupHome + "/Documents/wiki.qaq.apelin/Projects/Lookup"
write(lookupBin + "/apelin-cc", "#!/bin/sh\necho compiled\n", mode: 0o755)
write(lookupBin + "/git", "#!/bin/sh\necho the toolchain's git\n", mode: 0o755)
try FileManager.default.createSymbolicLink(atPath: lookupBin + "/apelin-c++", withDestinationPath: "/bin/bash")
write(lookupProject + "/build.sh", "#!/bin/sh\necho built\n", mode: 0o755)
write(lookupProject + "/notes.txt", "not a program\n")
write(
    lookupHome + "/Documents/wiki.qaq.apelin/Environment/Toolchains/registry.json",
    #"{"defaultID":"clt-27.0","toolchains":[{"id":"clt-27.0","version":"27.0","components":[{"kind":"c","selfCheckPassed":true}],"path":"\#(lookupToolchain)","contentDigest":"ab"}]}"#,
)

do {
    let project = ResolvedProject(id: "p-lookup", name: "Lookup", path: lookupProject)
    let ordinary = AgentRunCode.Identity.mobile(preset: nil)
    let environment = AgentRunCode.environment(preset: nil, project: project, installRoot: "/", home: lookupHome)
    func invocation(_ argv: [String], as identity: AgentRunCode.Identity = ordinary) throws -> (executable: String, argv: [String]) {
        try AgentRunCode.invocation(.argv(argv), as: identity, environment: environment, installRoot: "/", directory: lookupProject)
    }
    func refusal(_ argv: [String], as identity: AgentRunCode.Identity = ordinary) -> ApelinError? {
        do {
            _ = try invocation(argv, as: identity)
            return nil
        } catch {
            return error as? ApelinError
        }
    }

    // An ordinary run looks on the PATH it gets, the toolchain's tools
    // first, as `bash -c` does.
    let compiler = try? invocation(["apelin-cc", "-c", "main.c"])
    check(compiler?.executable == lookupBin + "/apelin-cc" && compiler?.argv == ["apelin-cc", "-c", "main.c"],
          "an argv finds the toolchain's tools by name: \(String(describing: compiler))")
    let toolchainGit = try? invocation(["git", "status"])
    check(toolchainGit?.executable == lookupBin + "/git", "in PATH's order, as a shell finds them: \(String(describing: toolchainGit))")

    // The canonical file runs, under the name the request called it by.
    let linked = try? invocation(["apelin-c++", "-c", "echo $0"])
    check(linked?.executable == "/bin/bash" && linked?.argv.first == "apelin-c++",
          "a link runs its canonical file with the request's own words as argv: \(String(describing: linked))")

    // A preset and a run as root look in the bootstrap's directories alone,
    // whatever PATH the run gets.
    let bootstrapGit = AgentRunCode.findExecutable("git", in: DevelopmentEnvironment.searchPath(installRoot: "/"))
    let preset = AgentRunCode.Preset(argv: ["git", "status"], environment: [])
    let presetGit = try? invocation(["git", "status"], as: .mobile(preset: preset))
    check(presetGit?.executable == bootstrapGit && presetGit?.executable != lookupBin + "/git",
          "a preset runs the bootstrap's git its checks vetted, never the toolchain's: \(String(describing: presetGit))")
    let rootGit = try? invocation(["git", "status"], as: .root)
    check(rootGit?.executable == bootstrapGit && rootGit?.executable != lookupBin + "/git",
          "so does a run as root: \(String(describing: rootGit))")
    let rootCompiler = refusal(["apelin-cc"], as: .root)
    check(rootCompiler?.code == .notFound && rootCompiler?.message.contains("as root") == true,
          "a run as root takes no command from the toolchain's place: \(String(describing: rootCompiler))")

    // A name on no directory of the PATH says where it looked and what to do.
    let missing = refusal(["apelin-no-such-tool"])
    check(missing?.code == .notFound && missing?.message.contains("PATH") == true && missing?.message.contains("bash -c") == true,
          "a name on no directory says where it looked and what to do instead: \(String(describing: missing))")

    // A path runs as a shell takes one: from the working directory unless
    // absolute, a regular file with an execute bit.
    let script = try? invocation(["./build.sh", "--fast"])
    check(script?.executable == lookupProject + "/build.sh" && script?.argv == ["./build.sh", "--fast"],
          "a relative path is read from the working directory: \(String(describing: script))")
    let absolute = try? invocation([lookupBin + "/apelin-cc"])
    check(absolute?.executable == lookupBin + "/apelin-cc", "an absolute path is taken as it is: \(String(describing: absolute))")
    check(refusal(["./notes.txt"])?.code == .notFound, "a file without an execute bit is no executable")
    check(refusal(["./missing.sh"])?.code == .notFound, "nor is a path that leads nowhere")
    check(refusal([""])?.code == .badRequest, "an empty executable is refused")

    // A script keeps its interpreter's canonical path as the name it runs by.
    let shell = try? AgentRunCode.invocation(
        .script(interpreter: "sh", source: "true"),
        as: ordinary,
        environment: environment,
        installRoot: "/",
        directory: lookupProject,
    )
    check(shell.map { $0.argv == [$0.executable, "-c", "true"] } == true, "a script runs as before: \(String(describing: shell))")

    // And it all runs. On the Mac only `.root` spawns (it runs as this
    // user); a path is read the same whoever runs it.
    func run(_ argv: [String], session: String) async -> AgentRunCodeResponse? {
        try? await AgentRunCode.run(
            AgentRunCodeRequest(sessionID: session, spec: .argv(argv), timeoutSeconds: 10, approval: .relaxed, asRoot: true),
            as: .root,
            project: project,
            installRoot: "/",
            home: lookupHome,
            stopsSeen: AgentRunCode.stopCount(session: session),
        )
    }
    let echoed = await run(["/bin/echo", "ok"], session: "lookup-absolute")
    check(echoed?.exitCode == 0 && echoed?.stdout == "ok\n", "an absolute argv[0] runs: \(String(describing: echoed))")
    let built = await run(["./build.sh"], session: "lookup-relative")
    check(built?.exitCode == 0 && built?.stdout == "built\n", "a script in the project runs by its path: \(String(describing: built))")
    let named = await run([lookupBin + "/apelin-c++", "-c", "echo $0"], session: "lookup-name")
    check(named?.exitCode == 0 && named?.stdout == lookupBin + "/apelin-c++\n",
          "the process sees the name it was called by, not its link's target: \(String(describing: named))")
}

// MARK: - Agent approvals are found and spent only when they apply

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("agent-approvals"))
    let sessions = AgentSessionTable.shared
    func session(_ id: String) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-agent", name: "Agent", path: scratchPath),
            mode: .confirm,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        tool: String,
        detail: JSONValue? = nil,
        workingDirectory: String = ".",
    ) async {
        var payload: [String: JSONValue] = [
            "approvalID": .string(approvalID),
            "tool": .string(tool),
            "workingDirectory": .string(workingDirectory),
        ]
        if let detail {
            payload["detail"] = detail
        }
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object(payload))
    }
    // What apelin-agent puts in a shell_run request's `detail`: the command,
    // as ApelinAgent's RunCodeInvocation encodes it (ApelinAgentWorker's
    // tests hold that shape).
    func command(_ invocation: String, _ value: JSONValue) -> JSONValue {
        .object(["command": .object([invocation: value])])
    }
    let makeCommand = command("argv", .object(["_0": .array([.string("make")])]))
    func runCode(_ entry: AgentSessionTable.Entry, _ approvalID: String) -> AgentRunCodeRequest {
        AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(["make"]),
            approval: .user(approvalID: approvalID),
        )
    }

    // A long session: the request comes after more events than one attach
    // batch holds.
    let long = await session("agent-long")
    for index in 0 ..< 1200 {
        await registry.append(long.task.taskID, kind: "text", payload: .object(["text": .string("\(index)")]))
    }
    let digest = "sha256:" + String(repeating: "d", count: 64)
    let changed: JSONValue = .object([
        "descriptionChanged": .object(["kind": .string("build"), "digest": .string(digest)]),
    ])
    await ask(long, "late-build", tool: "apelin_project_build", detail: changed)
    await ask(long, "late-run", tool: "shell_run", detail: makeCommand)
    let approveBuild = AgentApproveRequest(sessionID: long.sessionID, approvalID: "late-build", decision: .approve)
    try await AgentApprovals.recordInLedger(approveBuild, entry: long, registry: registry, ledger: ledger)
    let recorded = try await ledger.state(of: digest, kind: .build, project: "p-agent")
    check(recorded.baseline == .approved, "an approval asked after the first thousand events is recorded")
    await sessions.record(long.sessionID, approvalID: "late-run", decision: .approve)
    var lateRunPassed = true
    do {
        try await AgentApprovals.authorize(runCode(long, "late-run"), entry: long, registry: registry, ledger: ledger, installRoot: "/")
    } catch {
        lateRunPassed = false
    }
    check(lateRunPassed, "a shell_run approval asked after the first thousand events lets the call through")
    await expectErrorAsync("a shell_run approval is used once", code: .denied) {
        try await AgentApprovals.authorize(runCode(long, "late-run"), entry: long, registry: registry, ledger: ledger, installRoot: "/")
    }

    // An approval that does not apply is refused and left as the app gave it.
    let short = await session("agent-short")
    await ask(short, "for-build", tool: "apelin_project_build")
    await sessions.record(short.sessionID, approvalID: "for-build", decision: .approve)
    await expectErrorAsync("an approval asked for another tool", code: .denied) {
        try await AgentApprovals.authorize(
            runCode(short, "for-build"),
            entry: short,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    let kept = await sessions.entry(short.sessionID)?.approvals["for-build"]
    check(kept == .approve, "a refused shell_run call does not spend an approval asked for another tool")
    await sessions.record(short.sessionID, approvalID: "never-asked", decision: .approve)
    await expectErrorAsync("an approval the session never asked for", code: .denied) {
        try await AgentApprovals.authorize(
            runCode(short, "never-asked"),
            entry: short,
            registry: registry,
            ledger: ledger,
            installRoot: "/",
        )
    }
    let unasked = await sessions.entry(short.sessionID)?.approvals["never-asked"]
    check(unasked == .approve, "a refused shell_run call does not spend an approval with no request behind it")

    // An approval runs the command it was asked for, in the directory it was
    // asked for, and nothing else.
    let bound = await session("agent-bound")
    func authorized(_ run: AgentRunCodeRequest) async -> Bool {
        do {
            try await AgentApprovals.authorize(run, entry: bound, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }
    await ask(bound, "make-here", tool: "shell_run", detail: makeCommand)
    await sessions.record(bound.sessionID, approvalID: "make-here", decision: .approve)
    let other = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .argv(["rm", "-rf", "Sources"]),
        approval: .user(approvalID: "make-here"),
    )
    let otherPassed = await authorized(other)
    check(!otherPassed, "an approval cited for another command is refused")
    let elsewhere = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .argv(["make"]),
        workingDirectory: "Sources",
        approval: .user(approvalID: "make-here"),
    )
    let elsewherePassed = await authorized(elsewhere)
    check(!elsewherePassed, "an approval cited in another working directory is refused")
    let stillThere = await sessions.entry(bound.sessionID)?.approvals["make-here"]
    check(stillThere == .approve, "a run that is not the approved one does not spend the approval")
    let matchingPassed = await authorized(runCode(bound, "make-here"))
    check(matchingPassed, "the approved command in the approved directory runs")

    // Shell text the agent could not reduce to argv runs as an sh script.
    let shellText = "make 2>&1 | tail -n 20"
    await ask(bound, "make-piped", tool: "shell_run", detail: command("shell", .object(["_0": .string(shellText)])))
    await sessions.record(bound.sessionID, approvalID: "make-piped", decision: .approve)
    let piped = AgentRunCodeRequest(
        sessionID: bound.sessionID,
        spec: .script(interpreter: "sh", source: shellText),
        approval: .user(approvalID: "make-piped"),
    )
    let pipedPassed = await authorized(piped)
    check(pipedPassed, "approved shell text runs as the sh script it became")
    await ask(bound, "no-command", tool: "shell_run")
    await sessions.record(bound.sessionID, approvalID: "no-command", decision: .approve)
    let noCommandPassed = await authorized(runCode(bound, "no-command"))
    check(!noCommandPassed, "a shell_run approval that names no command is refused")
    // An approval asked under the name run_code had before the rename is no
    // approval for shell_run: the worker and the host change together.
    await ask(bound, "make-earlier-name", tool: "run_code", detail: makeCommand)
    await sessions.record(bound.sessionID, approvalID: "make-earlier-name", decision: .approve)
    let earlierNamePassed = await authorized(runCode(bound, "make-earlier-name"))
    check(!earlierNamePassed, "an approval recorded under run_code's earlier name is refused")
}

// MARK: - An agent sets up a toolchain or imports an SDK only as the user approved it

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-environment-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode = .confirm) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-environment", name: "Environment", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    // What apelin-agent writes into apelin_toolchain_setup's and apelin_sdk_import's
    // approvalRequested `detail` (ApelinAgentWorker's tests hold that shape).
    func ask(_ entry: AgentSessionTable.Entry, _ approvalID: String, tool: String, detail: JSONValue) async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool), "detail": detail,
        ]))
    }
    let setupDetail: JSONValue = .object(["toolchainSetup": .object([
        "productID": .string("082-1"), "version": .string("16.4"), "components": .array([.string("c")]), "sizeBytes": .number(1),
    ])])
    let sourceURL = "https://github.com/owngoal-dev/iOS-SDKs.git"
    let importDetail: JSONValue = .object(["sdkImport": .object([
        "source": .string("OwnGoal iOS SDKs"), "url": .string(sourceURL), "branch": .string("sdk/iPhoneOS17.5"), "version": .string("17.5"),
    ])])
    func authorized(_ request: some OperationRequest, _ entry: AgentSessionTable.Entry?, descriptors: Int = 0) async -> Bool {
        guard let wire = try? WireRequest(request) else { return false }
        do {
            try await AgentEnvironmentRules.authorize(wire, descriptorCount: descriptors, entry: entry, registry: registry)
            return true
        } catch {
            return false
        }
    }
    let setup = ToolchainSetupRequest(source: .appleCatalog(productID: "082-1"), components: [.c])
    let strict = await session("environment-strict")

    // The source rules hold in every mode.
    let relaxed = await session("environment-relaxed", mode: .relaxed)
    let relaxedSetup = await authorized(setup, relaxed)
    check(relaxedSetup, "a Relaxed session sets up a catalog toolchain without asking")
    let unnamed = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: nil)), relaxed)
    check(!unnamed, "but always names the product the user is shown")
    let packageFile = await authorized(ToolchainSetupRequest(source: .package(DescriptorSlot(index: 0))), relaxed, descriptors: 1)
    check(!packageFile, "and never sets one up from a file")
    for source: SDKSource in [
        .url("https://example.com/iPhoneOS17.5.sdk.tar.xz"), .inbox(path: "sdk"), .file(DescriptorSlot(index: 0)),
        .repository(url: "https://user:token@github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"),
        .repository(url: sourceURL + "?token=1", branch: "sdk/iPhoneOS17.5"),
        .repository(url: sourceURL + "#frag", branch: "sdk/iPhoneOS17.5"),
        .repository(url: "http://github.com/owngoal-dev/iOS-SDKs.git", branch: "sdk/iPhoneOS17.5"),
    ] {
        let passed = await authorized(SDKImportRequest(source: source), relaxed)
        check(!passed, "an agent imports an SDK only from an HTTPS repository without credentials (\(source))")
    }
    let relaxedImport = await authorized(SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS17.5")), relaxed)
    check(relaxedImport, "a Relaxed session imports from a source without asking")
    let noSession = await authorized(setup, nil)
    check(!noSession, "a worker with no session sets up nothing")

    // Under Confirm: exactly the approved setup, once.
    let unapproved = await authorized(setup, strict)
    check(!unapproved, "a Strict session needs the user's approval")
    await ask(strict, "setup-1", tool: "apelin_toolchain_setup", detail: setupDetail)
    let notYetGiven = await authorized(setup, strict)
    check(!notYetGiven, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "setup-1", decision: .approve)
    let otherProduct = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: "082-2"), components: [.c]), strict)
    check(!otherProduct, "an approval covers the product it named only")
    let otherComponents = await authorized(ToolchainSetupRequest(source: .appleCatalog(productID: "082-1"), components: [.c, .swift]), strict)
    check(!otherComponents, "and its components only")
    let approvedSetup = await authorized(setup, strict)
    check(approvedSetup, "the approved setup goes through")
    let again = await authorized(setup, strict)
    check(!again, "once: a second setup asks again")
    let importRequest = SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS17.5"))
    await ask(strict, "import-1", tool: "apelin_sdk_import", detail: importDetail)
    await sessions.record(strict.sessionID, approvalID: "import-1", decision: .approve)
    let otherBranch = await authorized(SDKImportRequest(source: .repository(url: sourceURL, branch: "sdk/iPhoneOS18.5")), strict)
    check(!otherBranch, "an import approval covers its branch only")
    let setupFromImport = await authorized(setup, strict)
    check(!setupFromImport, "and no setup")
    let approvedImport = await authorized(importRequest, strict)
    check(approvedImport, "the approved import goes through")
    await ask(strict, "denied-1", tool: "apelin_sdk_import", detail: importDetail)
    await sessions.record(strict.sessionID, approvalID: "denied-1", decision: .deny)
    let afterDenial = await authorized(importRequest, strict)
    check(!afterDenial, "a denied approval lets nothing through")

    // An agent reads only the environment tasks its session started.
    let started = await registry.create(kind: .environment, owner: .environment, ownerKey: nil)
    let foreign = await registry.create(kind: .environment, owner: .environment, ownerKey: nil)
    await sessions.recordStarted(started.taskID, session: strict.sessionID)
    let readsOwn = await sessions.started(started.taskID, session: strict.sessionID)
    let readsForeign = await sessions.started(foreign.taskID, session: strict.sessionID)
    let readsOthers = await sessions.started(started.taskID, session: relaxed.sessionID)
    check(readsOwn && !readsForeign && !readsOthers, "a task counts as the session's only when that session started it")
}

// MARK: - A workspace's build spends the one approval the user gave for it

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-external-build-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "external-build-strict",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "external-build-strict"),
        project: ResolvedProject(id: "p-workspace", name: "Workspace", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    // What apelin-agent writes into a workspace build's approvalRequested
    // `detail` (ApelinAgentWorker's tests hold that shape): no bootstrap
    // when the build names none.
    func ask(_ approvalID: String, configuration: String, bootstrap: String? = nil) async {
        var detail: [String: JSONValue] = [
            "projectID": .string("p-workspace"), "script": .string("apelin/build.sh"), "configuration": .string(configuration),
        ]
        detail["bootstrap"] = bootstrap.map(JSONValue.string)
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_project_build"),
            "detail": .object([AgentExternalBuildRules.detailKey: .object(detail)]),
        ]))
    }
    let debug = BuildStartRequest(projectID: "p-workspace", configuration: .debug)
    let unapproved = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(unapproved?.code == .denied, "a Strict session's workspace build needs the user's approval")
    await ask("build-1", configuration: "debug")
    let asked = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(asked != nil, "asking is not approving")
    await sessions.record(entry.sessionID, approvalID: "build-1", decision: .approve)
    let release = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", configuration: .release), session: entry.sessionID, registry: registry)
    check(release != nil, "an approval covers the configuration it named only")
    let rootless = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", bootstrap: .rootless), session: entry.sessionID, registry: registry)
    check(rootless != nil, "and the bootstrap it named only")
    let elsewhere = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-other"), session: entry.sessionID, registry: registry)
    check(elsewhere != nil, "and its project only")
    let approved = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(approved == nil, "the approved build goes through")
    let again = await AgentExternalBuildRules.authorize(debug, session: entry.sessionID, registry: registry)
    check(again != nil, "once: the next build asks again")
    await ask("build-2", configuration: "release", bootstrap: "rootless")
    await sessions.record(entry.sessionID, approvalID: "build-2", decision: .approve)
    let named = await AgentExternalBuildRules.authorize(BuildStartRequest(projectID: "p-workspace", configuration: .release, bootstrap: .rootless), session: entry.sessionID, registry: registry)
    check(named == nil, "a build naming a bootstrap is covered by an approval naming it")
    let noSession = await AgentExternalBuildRules.authorize(debug, session: nil, registry: registry)
    check(noSession != nil, "a worker with no session builds nothing")
}

// MARK: - A project is renamed by its own session, or another as the user approved

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .projectRename), "the agent may ask for a rename")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-rename-tasks"))
    await registry.load()
    let home = scratch.appendingPathComponent("rename-home", isDirectory: true)
    let projects = DataFolder(home: home.path).projects
    for (name, id) in [("Mine", "p-rename-mine"), ("Theirs", "p-rename-theirs")] {
        let folder = projects.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(#"{"projectID":"\#(id)"}"#.utf8).write(to: folder.appendingPathComponent("apelin-project.json"))
    }
    let homePath = CanonicalPath.resolve(home.path)!
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-rename-mine", name: "Mine", path: homePath + "/Documents/wiki.qaq.apelin/Projects/Mine"),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("rename-strict", mode: .confirm)
    func authorized(_ rename: ProjectRenameRequest, _ entry: AgentSessionTable.Entry?) async -> Bool {
        await AgentProjectRenameRules.authorize(rename, session: entry?.sessionID, home: homePath, registry: registry) == nil
    }
    let own = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock"), strict)
    let ownAutomatic = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock", onlyIfAutomatic: true), strict)
    check(own && ownAutomatic, "a session renames its own project, automatically too, without an approval")
    let theirs = ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Weather")
    let unasked = await authorized(theirs, strict)
    check(!unasked, "another project's rename needs the user's approval under Confirm")
    await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("rename-1"), "tool": .string("apelin_project_rename"),
        "detail": .object([AgentProjectRenameRules.detailKey: .object([
            "projectID": .string("p-rename-theirs"), "folder": .string("Theirs"),
            "currentName": .string("Theirs"), "displayName": .string("Weather"),
        ])]),
    ]))
    let asked = await authorized(theirs, strict)
    check(!asked, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "rename-1", decision: .approve)
    let otherName = await authorized(ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Rain"), strict)
    check(!otherName, "an approval covers the name it showed only")
    let approved = await authorized(theirs, strict)
    check(approved, "the approved rename goes through")
    let again = await authorized(theirs, strict)
    check(!again, "once: the next rename asks again")
    let relaxed = await session("rename-relaxed", mode: .relaxed)
    let relaxedOther = await authorized(theirs, relaxed)
    let relaxedAutomatic = await authorized(ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Weather", onlyIfAutomatic: true), relaxed)
    check(relaxedOther && !relaxedAutomatic, "Relaxed renames another project, but never automatically")
    let full = await session("rename-full", mode: .full)
    let fullOther = await authorized(theirs, full)
    let fullAutomatic = await authorized(ProjectRenameRequest(projectID: "p-rename-theirs", displayName: "Weather", onlyIfAutomatic: true), full)
    check(fullOther && !fullAutomatic, "Full renames another project as Relaxed does, which its gate never asks about")
    let byFolder = await authorized(ProjectRenameRequest(projectID: "Theirs", displayName: "Weather"), relaxed)
    check(!byFolder, "a project is named by its id, never its folder")
    let noSession = await authorized(ProjectRenameRequest(projectID: "p-rename-mine", displayName: "Clock"), nil)
    check(!noSession, "a worker with no session renames nothing")
}

// MARK: - A project is deleted only in its real folder, never by its own session, and under Strict as approved

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .projectDelete), "the agent may ask for a deletion")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .projectDelete), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .projectDelete), "nor the environment worker")
    check(AppOperation.projectDelete.domain == .project, "ProjectHandler serves it")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-delete-tasks"))
    await registry.load()
    let home = scratch.appendingPathComponent("delete-home", isDirectory: true)
    let data = DataFolder(home: home.path)
    func project(_ folder: URL, id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(#"{"projectID":"\#(id)"}"#.utf8).write(to: folder.appendingPathComponent("apelin-project.json"))
    }
    project(data.projects.appendingPathComponent("Mine", isDirectory: true), id: "p-delete-mine")
    project(data.projects.appendingPathComponent("Theirs", isDirectory: true), id: "p-delete-theirs")
    // A folder of Projects/ that is a link to a project kept elsewhere.
    let elsewhere = scratch.appendingPathComponent("delete-elsewhere/Outside", isDirectory: true)
    project(elsewhere, id: "p-delete-outside")
    try? FileManager.default.createSymbolicLink(at: data.projects.appendingPathComponent("Linked"), withDestinationURL: elsewhere)
    // A temporary chat's working folder, which is no project.
    let temporary = UUID().uuidString
    project(data.root.appendingPathComponent("Temporary/\(temporary)", isDirectory: true), id: "temporary:\(temporary)")
    let homePath = CanonicalPath.resolve(home.path)!

    func code(_ delete: ProjectDeleteRequest) -> ApelinError.Code? {
        do {
            _ = try AgentProjectDeleteRules.target(delete, home: homePath)
            return nil
        } catch {
            return (error as? ApelinError)?.code ?? .internal
        }
    }
    let theirs = try? AgentProjectDeleteRules.target(ProjectDeleteRequest(projectID: "p-delete-theirs"), home: homePath)
    check(theirs?.name == "Theirs" && theirs?.path == homePath + "/Documents/wiki.qaq.apelin/Projects/Theirs", "a project is found by its id, in its own folder")
    check(code(ProjectDeleteRequest(projectID: "temporary:\(temporary)")) == .badRequest, "a temporary chat's folder is no project to delete")
    check(code(ProjectDeleteRequest(projectID: "p-delete-outside")) == .notFound, "nor a project behind a link out of Projects/, by its id")
    check(code(ProjectDeleteRequest(projectID: "p-delete-outside", projectName: "Linked")) == .notFound, "or by the link's name")
    check(code(ProjectDeleteRequest(projectID: "p-delete-theirs", projectName: "Mine")) == .conflict, "a folder holding another id is refused")
    check(code(ProjectDeleteRequest(projectID: "p-delete-none")) == .notFound, "an id no project has is refused")
    check(code(ProjectDeleteRequest(projectID: "")) == .badRequest, "and no id at all")
    check(FileManager.default.fileExists(atPath: elsewhere.path), "deciding removes nothing")

    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode, project: ResolvedProject? = nil) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: project ?? ResolvedProject(id: "p-delete-mine", name: "Mine", path: homePath + "/Documents/wiki.qaq.apelin/Projects/Mine"),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    guard let target = theirs else { fatalError("no project to delete") }
    let strict = await session("delete-strict", mode: .confirm)
    func authorized(_ entry: AgentSessionTable.Entry?, _ project: ResolvedProject = target) async -> ApelinError? {
        await AgentProjectDeleteRules.authorize(project, session: entry?.sessionID, registry: registry)
    }
    // What apelin-agent writes into apelin_project_delete's approvalRequested
    // (ApelinAgentWorker's tests hold that shape).
    func ask(_ approvalID: String, tool: String = "apelin_project_delete", projectID: String = "p-delete-theirs", folder: String = "Theirs") async {
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool),
            "detail": .object([AgentProjectDeleteRules.detailKey: .object([
                "projectID": .string(projectID), "folder": .string(folder), "displayName": .string("Weather"),
            ])]),
        ]))
    }
    let unasked = await authorized(strict)
    check(unasked?.code == .denied, "Strict deletes another project only as the user approved it")
    await ask("delete-1", folder: "Mine")
    await sessions.record(strict.sessionID, approvalID: "delete-1", decision: .approve)
    await ask("delete-2", tool: "apelin_project_rename")
    await sessions.record(strict.sessionID, approvalID: "delete-2", decision: .approve)
    let otherFolder = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(otherFolder != nil && unspent == ["delete-1", "delete-2"], "an approval covers the folder it named, by this tool only, and stays unspent")
    await ask("delete-3")
    let asked = await authorized(strict)
    check(asked != nil, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "delete-3", decision: .approve)
    let approved = await authorized(strict)
    check(approved == nil, "the approved deletion goes through")
    let again = await authorized(strict)
    check(again != nil, "once: the next one asks again")
    for mode in [ApprovalMode.relaxed, .full] {
        let entry = await session("delete-\(mode.rawValue)", mode: mode)
        let other = await authorized(entry)
        let own = await authorized(entry, entry.project)
        check(other == nil, "\(mode.rawValue) deletes another project without asking")
        check(own?.code == .denied && own?.message.contains("General Chat") == true, "but never its own, in \(mode.rawValue) too, saying where it is deleted from")
    }
    let ownStrict = await authorized(strict, strict.project)
    check(ownStrict?.code == .denied, "nor under Strict")
    let generalChat = await session("delete-general", mode: .relaxed, project: ResolvedProject(id: "temporary:\(temporary)", name: temporary, path: "/"))
    let fromGeneral = await authorized(generalChat)
    check(fromGeneral == nil, "General Chat deletes a project")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session deletes nothing")

    // The sessions a deletion closes: the project's own that still run.
    let open = await session("delete-theirs-open", mode: .relaxed, project: target)
    let ended = await session("delete-theirs-ended", mode: .relaxed, project: target)
    await registry.finish(ended.task.taskID, .succeeded, message: "closed")
    let closing = await sessions.running(project: target.id, registry: registry).map(\.sessionID)
    check(closing == [open.sessionID], "a deletion closes the project's running sessions only (\(closing))")
}

// MARK: - Feedback is posted under Strict only as the user approved exactly it

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .feedbackSend), "the agent may file feedback")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .feedbackSend), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.diagnostics, instance: nil), .feedbackSend), "nor the diagnostics worker")
    for operation in [AppOperation.distributionRepositoryList, .distributionRepositoryCreate,
                      .distributionRepositoryLink, .distributionRepositoryUnlink]
    {
        check(!CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the package repository stays the app's: \(operation)")
    }
    for star in [AppOperation.feedbackStarState, .feedbackStar] {
        check(CallerPolicy.allows(.app, star), "the app reads and gives the star")
        for role in WorkerRole.allCases {
            check(!CallerPolicy.allows(.worker(role, instance: "s"), star), "no worker reads or gives it: \(role)")
        }
    }
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-feedback-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-feedback", name: "Feedback", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("feedback-strict", mode: .confirm)
    let feedback = FeedbackSendRequest(title: "The build log stops early", body: "It ends before the link step.")
    // What apelin-agent writes into apelin_feedback_send's approvalRequested
    // (ApelinAgentWorker's tests hold that shape).
    func ask(_ approvalID: String, body: String, repository: String = FeedbackRules.repository) async {
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_feedback_send"),
            "detail": .object([AgentFeedbackRules.detailKey: .object([
                "repository": .string(repository), "title": .string(feedback.title), "body": .string(body),
            ])]),
        ]))
    }
    func authorized(_ entry: AgentSessionTable.Entry?) async -> ApelinError? {
        await AgentFeedbackRules.authorize(feedback, session: entry?.sessionID, registry: registry)
    }
    let unasked = await authorized(strict)
    check(unasked?.code == .denied, "Strict posts an issue only as the user approved it")
    await ask("feedback-1", body: "Another body.")
    await sessions.record(strict.sessionID, approvalID: "feedback-1", decision: .approve)
    let otherBody = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(otherBody != nil && unspent == ["feedback-1"], "an approval covers the body it showed only, and stays unspent")
    await ask("feedback-2", body: feedback.body, repository: "someone/elsewhere")
    await sessions.record(strict.sessionID, approvalID: "feedback-2", decision: .approve)
    let elsewhere = await authorized(strict)
    check(elsewhere != nil, "and Apelin's own repository only")
    await ask("feedback-3", body: feedback.body)
    let asked = await authorized(strict)
    check(asked != nil, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "feedback-3", decision: .approve)
    let approved = await authorized(strict)
    check(approved == nil, "the approved issue goes through")
    let again = await authorized(strict)
    check(again != nil, "once: the next one asks again")
    let relaxed = await authorized(session("feedback-relaxed", mode: .relaxed))
    let full = await authorized(session("feedback-full", mode: .full))
    check(relaxed == nil && full == nil, "Relaxed and Full send it as they push")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session files nothing")
}

// MARK: - A feedback issue is edited under Strict only as the user approved exactly it

do {
    for operation in [AppOperation.feedbackRead, .feedbackEdit] {
        check(CallerPolicy.allows(.worker(.agent, instance: "s"), operation), "the agent may read and edit feedback: \(operation)")
        check(!CallerPolicy.allows(.worker(.build, instance: nil), operation), "the build worker may not: \(operation)")
        check(!CallerPolicy.allows(.worker(.environment, instance: nil), operation), "nor the environment worker: \(operation)")
    }
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-feedback-edit-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-feedback-edit", name: "Feedback Edit", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("feedback-edit-strict", mode: .confirm)
    let edit = FeedbackEditRequest(
        number: 12,
        title: nil,
        body: "It ends before the link step, on roothide and rootless.",
        expectedTitle: "The build log stops early",
        expectedBody: "It ends before the link step.",
    )
    // What apelin-agent writes into apelin_feedback_edit's approvalRequested
    // (ApelinAgentWorker's tests hold that shape): no title, since it stays.
    func ask(
        _ approvalID: String,
        tool: String = "apelin_feedback_edit",
        number: Double = 12,
        title: String? = nil,
        body: String = "It ends before the link step, on roothide and rootless.",
        currentBody: String = "It ends before the link step.",
    ) async {
        var detail: [String: JSONValue] = [
            "repository": .string(FeedbackRules.repository), "number": .number(number),
            "url": .string("https://github.com/owngoal-dev/Apelin/issues/12"),
            "body": .string(body), "currentTitle": .string("The build log stops early"), "currentBody": .string(currentBody),
        ]
        if let title {
            detail["title"] = .string(title)
        }
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool),
            "detail": .object([AgentFeedbackRules.editDetailKey: .object(detail)]),
        ]))
        await sessions.record(strict.sessionID, approvalID: approvalID, decision: .approve)
    }
    func authorized(_ entry: AgentSessionTable.Entry?) async -> ApelinError? {
        await AgentFeedbackRules.authorize(edit, session: entry?.sessionID, registry: registry)
    }
    let unasked = await authorized(strict)
    check(unasked?.code == .denied, "Strict edits an issue only as the user approved it")
    await ask("edit-number", number: 13)
    await ask("edit-body", body: "Another body.")
    await ask("edit-title", title: "A title it does not change")
    await ask("edit-against", currentBody: "What the issue said before the user edited it.")
    await ask("edit-tool", tool: "apelin_feedback_send")
    let near = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(
        near != nil && Set(unspent) == ["edit-number", "edit-body", "edit-title", "edit-against", "edit-tool"],
        "an approval covers the issue, the text and what it was made against it showed only, and stays unspent (\(unspent))",
    )
    let send = await AgentFeedbackRules.authorize(
        FeedbackSendRequest(title: "The build log stops early", body: edit.body ?? ""),
        session: strict.sessionID,
        registry: registry,
    )
    check(send != nil, "an edit's approval never files a new issue")
    await ask("edit-exact")
    let approved = await authorized(strict)
    check(approved == nil, "the approved edit goes through")
    let again = await authorized(strict)
    check(again != nil, "once, never for the session: the same edit asks again")
    let relaxed = await authorized(session("feedback-edit-relaxed", mode: .relaxed))
    let full = await authorized(session("feedback-edit-full", mode: .full))
    check(relaxed == nil && full == nil, "Relaxed and Full edit without asking")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session edits nothing")
}

// MARK: - A repository is made on GitHub under Strict only as the user approved exactly it

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .gitRepositoryCreate), "the agent may make a repository")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .gitRepositoryCreate), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .gitRepositoryCreate), "nor the environment worker")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-repository-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-repository", name: "Repository", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("repository-strict", mode: .confirm)
    let create = GitRepositoryCreateRequest(name: "clock-tweak", visibility: .private, description: "A clock in the status bar")
    // What apelin-agent writes into apelin_git_create_repository's
    // approvalRequested (ApelinAgentWorker's tests hold that shape).
    func ask(_ approvalID: String, owner: String? = nil, visibility: String = "private") async {
        var detail: [String: JSONValue] = [
            "name": .string(create.name), "visibility": .string(visibility), "description": .string("A clock in the status bar"),
        ]
        if let owner {
            detail["owner"] = .string(owner)
        }
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_git_create_repository"),
            "detail": .object([AgentRepositoryCreateRules.detailKey: .object(detail)]),
        ]))
    }
    func authorized(_ entry: AgentSessionTable.Entry?) async -> ApelinError? {
        await AgentRepositoryCreateRules.authorize(create, session: entry?.sessionID, registry: registry)
    }
    let unasked = await authorized(strict)
    check(unasked?.code == .denied, "Strict makes a repository only as the user approved it")
    await ask("repository-1", visibility: "public")
    await sessions.record(strict.sessionID, approvalID: "repository-1", decision: .approve)
    let otherVisibility = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(otherVisibility != nil && unspent == ["repository-1"], "a public repository approved is no private one, and stays unspent")
    await ask("repository-2", owner: "OwnGoal")
    await sessions.record(strict.sessionID, approvalID: "repository-2", decision: .approve)
    let otherOwner = await authorized(strict)
    check(otherOwner != nil, "nor is one approved in an organization one on the account")
    await ask("repository-3")
    let asked = await authorized(strict)
    check(asked != nil, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "repository-3", decision: .approve)
    let approved = await authorized(strict)
    check(approved == nil, "the approved repository is made")
    let again = await authorized(strict)
    check(again != nil, "once: the next one asks again")
    let relaxed = await authorized(session("repository-relaxed", mode: .relaxed))
    let full = await authorized(session("repository-full", mode: .full))
    check(relaxed == nil && full == nil, "Relaxed and Full make it as they push")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session makes nothing")
}

// MARK: - An issue is opened on another repository under Strict only as the user approved exactly it

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .gitIssueCreate), "the agent may open an issue")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .gitIssueCreate), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .gitIssueCreate), "nor the environment worker")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-issue-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-issue", name: "Issue", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let strict = await session("issue-strict", mode: .confirm)
    let issue = GitIssueCreateRequest(
        repository: "Lakr233/Irisin",
        title: "The installer stops at 90%",
        body: "Installing a package from the inbox stops at 90%.",
    )
    // What apelin-agent writes into apelin_git_create_issue's
    // approvalRequested (ApelinAgentWorker's tests hold that shape).
    func ask(
        _ approvalID: String,
        tool: String = "apelin_git_create_issue",
        repository: String = "Lakr233/Irisin",
        body: String = "Installing a package from the inbox stops at 90%.",
    ) async {
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool),
            "detail": .object([AgentIssueCreateRules.detailKey: .object([
                "repository": .string(repository), "title": .string(issue.title), "body": .string(body),
            ])]),
        ]))
        await sessions.record(strict.sessionID, approvalID: approvalID, decision: .approve)
    }
    func authorized(_ entry: AgentSessionTable.Entry?) async -> ApelinError? {
        await AgentIssueCreateRules.authorize(issue, session: entry?.sessionID, registry: registry)
    }
    let unasked = await authorized(strict)
    check(unasked?.code == .denied, "Strict opens an issue only as the user approved it")
    await ask("issue-elsewhere", repository: "owngoal-dev/Apelin")
    await ask("issue-body", body: "Another body.")
    await ask("issue-tool", tool: "apelin_feedback_send")
    let near = await authorized(strict)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(
        near != nil && Set(unspent) == ["issue-elsewhere", "issue-body", "issue-tool"],
        "an approval covers the repository and the text it showed only, and stays unspent (\(unspent))",
    )
    let feedback = await AgentFeedbackRules.authorize(
        FeedbackSendRequest(title: issue.title, body: issue.body),
        session: strict.sessionID,
        registry: registry,
    )
    check(feedback != nil, "an issue's approval files no feedback on Apelin's repository")
    await ask("issue-exact")
    let approved = await authorized(strict)
    check(approved == nil, "the approved issue is opened")
    let again = await authorized(strict)
    check(again != nil, "once, never for the session: the next one asks again")
    let relaxed = await authorized(session("issue-relaxed", mode: .relaxed))
    let full = await authorized(session("issue-full", mode: .full))
    check(relaxed == nil && full == nil, "Relaxed and Full open it without asking")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session opens nothing")
}

// MARK: - A forced push goes only on the user's approval of exactly it, in every mode

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-force-push-tasks"))
    await registry.load()
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-force", name: "Force", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    let theirs = String(repeating: "a", count: 40)
    let mine = String(repeating: "b", count: 40)
    let lease = GitPushLease(expectedCommit: theirs, localCommit: mine)
    let push = GitPushRequest(projectID: "p-force", branch: "main", forceWithLease: lease)
    // What apelin-agent writes into a forced git_push's approvalRequested
    // (ApelinAgentWorker's tests hold that shape).
    func ask(
        _ entry: AgentSessionTable.Entry,
        _ approvalID: String,
        tool: String = "git_push",
        project: String = "p-force",
        remote: String = "origin",
        branch: String = "main",
        expected: String? = nil,
        local: String? = nil,
    ) async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string(tool), "allowsSessionScope": .bool(false),
            "detail": .object([AgentForcePushRules.detailKey: .object([
                "projectID": .string(project), "remote": .string(remote), "branch": .string(branch),
                "expectedCommit": .string(expected ?? theirs), "localCommit": .string(local ?? mine),
                "overwritten": .array([.object(["commit": .string(theirs), "subject": .string("Theirs")])]),
                "overwrittenCount": .number(1),
            ])]),
        ]))
        await sessions.record(entry.sessionID, approvalID: approvalID, decision: .approve)
    }
    func authorized(_ entry: AgentSessionTable.Entry?, _ request: GitPushRequest = push) async -> ApelinError? {
        await AgentForcePushRules.authorize(request, session: entry?.sessionID, registry: registry)
    }
    for mode in [ApprovalMode.confirm, .relaxed, .full] {
        let entry = await session("force-\(mode.rawValue)", mode: mode)
        let unasked = await authorized(entry)
        check(unasked?.code == .denied, "\(mode.rawValue): a forced push goes only on the user's approval")
        await ask(entry, "force-\(mode.rawValue)-other-lease", expected: String(repeating: "c", count: 40))
        await ask(entry, "force-\(mode.rawValue)-other-local", local: String(repeating: "c", count: 40))
        await ask(entry, "force-\(mode.rawValue)-other-branch", branch: "release")
        await ask(entry, "force-\(mode.rawValue)-other-remote", remote: "upstream")
        await ask(entry, "force-\(mode.rawValue)-other-project", project: "p-elsewhere")
        await ask(entry, "force-\(mode.rawValue)-other-tool", tool: "git_pull")
        let near = await authorized(entry)
        let unspent = await sessions.approvedIDs(entry.sessionID)
        check(
            near != nil && unspent.count == 6,
            "\(mode.rawValue): an approval covers the remote, branch, project and lease it named only, and stays unspent (\(unspent))",
        )
        await ask(entry, "force-\(mode.rawValue)-exact")
        let approved = await authorized(entry)
        check(approved == nil, "\(mode.rawValue): the approved forced push goes")
        let again = await authorized(entry)
        check(again != nil, "\(mode.rawValue): once, never for the session: the next one asks again")
    }
    let relaxed = await session("force-unnamed", mode: .relaxed)
    let ordinary = await authorized(relaxed, GitPushRequest(projectID: "p-force", branch: "main"))
    check(ordinary == nil, "a push without a lease is never forced, and asks the host nothing")
    let unnamed = await authorized(relaxed, GitPushRequest(
        projectID: "p-force",
        forceWithLease: GitPushLease(expectedCommit: theirs, localCommit: mine),
    ))
    let noLocal = await authorized(relaxed, GitPushRequest(
        projectID: "p-force",
        branch: "main",
        forceWithLease: GitPushLease(expectedCommit: theirs),
    ))
    check(unnamed?.code == .badRequest && noLocal?.code == .badRequest, "an agent's lease names the branch and the local commit")
    let noSession = await authorized(nil)
    check(noSession?.code == .denied, "a worker with no session forces nothing")
}

// MARK: - Packages are published under Strict only as the user approved exactly them

do {
    check(CallerPolicy.allows(.worker(.agent, instance: "s"), .distributionPublish), "the agent may publish packages")
    check(!CallerPolicy.allows(.worker(.build, instance: nil), .distributionPublish), "the build worker may not")
    check(!CallerPolicy.allows(.worker(.environment, instance: nil), .distributionPublish), "nor the environment worker")
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-publish-tasks"))
    await registry.load()
    let artifacts = ArtifactRegistry(file: scratch.appendingPathComponent("agent-publish-artifacts.json"))
    let sessions = AgentSessionTable.shared
    func session(_ id: String, mode: ApprovalMode) async -> AgentSessionTable.Entry {
        let entry = await AgentSessionTable.Entry(
            sessionID: id,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: id),
            project: ResolvedProject(id: "p-publish", name: "Publish", path: scratchPath),
            mode: mode,
            createdAt: Date(),
        )
        await sessions.add(entry)
        return entry
    }
    // Two release builds of one version, as apelin-build reports them.
    let builds = [("b-hide", "iphoneos-arm64e", "a"), ("b-less", "iphoneos-arm64", "b")]
    let files = builds.map { build, architecture, _ in "/data/Builds/p-publish/\(build)/com.example.clock_1.0_\(architecture).deb" }
    let digests = builds.map { _, _, digit in "sha256:" + String(repeating: digit, count: 64) }
    for (index, build) in builds.enumerated() {
        await artifacts.record(event: .object([
            "artifactID": .string(build.0), "path": .string(files[index]), "digest": .string(digests[index]),
            "packageID": .string("com.example.clock"), "version": .string("1.0"), "projectID": .string("p-publish"),
        ]), buildID: TaskID(build.0))
    }
    let publish = DistributionPublishRequest(files: files, digests: digests, repository: "someone/packages")
    let strict = await session("publish-strict", mode: .confirm)
    // What apelin-agent writes into apelin_package_publish's
    // approvalRequested (ApelinAgentWorker's tests hold that shape).
    func ask(_ approvalID: String, _ asked: DistributionPublishRequest) async {
        let packages: [JSONValue] = zip(asked.files, asked.digests ?? []).map { file, digest in
            .object(["file": .string(file), "digest": .string(digest), "packageID": .string("com.example.clock")])
        }
        await registry.append(strict.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_package_publish"),
            "detail": .object([AgentPublishRules.detailKey: .object([
                "repository": .string(asked.repository ?? ""), "packages": .array(packages),
            ])]),
        ]))
    }
    func authorized(_ entry: AgentSessionTable.Entry?, _ request: DistributionPublishRequest) async -> ApelinError? {
        await AgentPublishRules.authorize(request, session: entry?.sessionID, registry: registry, artifacts: artifacts)
    }
    let unasked = await authorized(strict, publish)
    check(unasked?.code == .denied, "Strict publishes only as the user approved it")
    let one = DistributionPublishRequest(files: [files[0]], digests: [digests[0]], repository: "someone/packages")
    await ask("publish-1", one)
    await sessions.record(strict.sessionID, approvalID: "publish-1", decision: .approve)
    let fewer = await authorized(strict, publish)
    let unspent = await sessions.approvedIDs(strict.sessionID)
    check(fewer != nil && unspent == ["publish-1"], "an approval of one package is no approval of two, and stays unspent")
    await ask("publish-2", DistributionPublishRequest(files: files, digests: digests.reversed(), repository: "someone/packages"))
    await sessions.record(strict.sessionID, approvalID: "publish-2", decision: .approve)
    let otherDigests = await authorized(strict, publish)
    check(otherDigests != nil, "nor of the same files with other digests")
    await ask("publish-3", DistributionPublishRequest(files: files, digests: digests, repository: "someone/elsewhere"))
    await sessions.record(strict.sessionID, approvalID: "publish-3", decision: .approve)
    let elsewhere = await authorized(strict, publish)
    check(elsewhere != nil, "nor of another repository")
    await ask("publish-4", publish)
    let asked = await authorized(strict, publish)
    check(asked != nil, "asking is not approving")
    await sessions.record(strict.sessionID, approvalID: "publish-4", decision: .approve)
    let approved = await authorized(strict, publish)
    check(approved == nil, "the approved publication goes through")
    let again = await authorized(strict, publish)
    check(again != nil, "once: the next one asks again, never for the session")
    let left = await sessions.approvedIDs(strict.sessionID)
    check(left == ["publish-1", "publish-2", "publish-3"], "only the approval that covered it was spent (\(left))")
    let oneApproved = await authorized(strict, one)
    check(oneApproved == nil, "and the one-package approval still covers that one package")

    let relaxed = await session("publish-relaxed", mode: .relaxed)
    let full = await session("publish-full", mode: .full)
    let relaxedPublishes = await authorized(relaxed, publish)
    let fullPublishes = await authorized(full, publish)
    check(relaxedPublishes == nil && fullPublishes == nil, "Relaxed and Full publish as they push")
    // In every mode: only what a build reported to this host, as it reported it.
    let handMade = DistributionPublishRequest(
        files: ["/data/Builds/p-publish/made-by-hand.deb"], digests: [digests[0]], repository: "someone/packages",
    )
    let notBuilt = await authorized(relaxed, handMade)
    check(notBuilt?.code == .denied, "a .deb no build reported is refused, even in Relaxed")
    let changed = DistributionPublishRequest(files: [files[0]], digests: [digests[1]], repository: "someone/packages")
    let otherBytes = await authorized(full, changed)
    check(otherBytes?.code == .denied, "and a build's file under another digest, even in Full")
    let bare = await authorized(relaxed, DistributionPublishRequest(files: files))
    check(bare?.code == .badRequest, "an agent's publish names the repository and every digest")
    let short = await authorized(relaxed, DistributionPublishRequest(files: files, digests: [digests[0]], repository: "someone/packages"))
    check(short?.code == .badRequest, "one digest for each file")
    let noSession = await authorized(nil, publish)
    check(noSession?.code == .denied, "a worker with no session publishes nothing")
}

// MARK: - Another project's conversations are reached only as the user approved

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("agent-reach-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("agent-reach-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "reach-opener",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "reach-opener"),
        project: ResolvedProject(id: "p-reach", name: "Reach", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    let detail: JSONValue = .object([AgentConversationRules.otherProjectDetail: .object([
        "action": .string("create"), "projectID": .string("p-far"), "projectName": .string("Far"), "text": .string("Build it"),
    ])])
    await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("reach-1"), "tool": .string("apelin_conversation_create"), "detail": detail,
    ]))
    let before = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!before, "another project is out of reach until the user approves a call naming it")
    // The worker refuses the relay: nothing is left behind.
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "reach-1", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { false },
        accepted: { $0 },
    )
    let afterRefusedRelay = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!afterRefusedRelay, "an approval the worker did not take lets it reach nothing")
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "reach-1", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { true },
        accepted: { $0 },
    )
    let afterRelay = await sessions.mayReach("p-far", session: entry.sessionID)
    check(afterRelay, "once approved, the session may list and read that project's conversations")
    let open = AgentOpenRequest(projectID: "p-far", projectName: "Far", prompt: "Build it")
    let far = ResolvedProject(id: "p-far", name: "Far", path: scratchPath + "/Far")
    let spent = await AgentApprovals.spend(entry: entry, registry: registry) {
        AgentConversationRules.coversOpen(open, target: far, asked: $0)
    }
    check(spent, "the approved open spends its approval")
    let spentAgain = await AgentApprovals.spend(entry: entry, registry: registry) {
        AgentConversationRules.coversOpen(open, target: far, asked: $0)
    }
    check(!spentAgain, "and only once")
    await sessions.forgetGrants(entry.sessionID)
    let afterClose = await sessions.mayReach("p-far", session: entry.sessionID)
    check(!afterClose, "a closed session reaches no other project")
}

// MARK: - An approval the worker never got leaves nothing behind

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("relay-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("relay-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-relay",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-relay"),
        project: ResolvedProject(id: "p-relay", name: "Relay", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    let digest = "sha256:" + String(repeating: "e", count: 64)
    let changedBuild: JSONValue = .object(["kind": .string("build"), "digest": .string(digest)])
    let asks: [(String, JSONValue)] = [
        ("relay-build", .object(["descriptionChanged": changedBuild])),
        ("relay-remove", .object(["packageRemoval": .object(["installationID": .string("inst-relay")])])),
    ]
    for (approvalID, detail) in asks {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID), "tool": .string("apelin_project_build"), "detail": detail,
        ]))
    }
    func relay(_ approvalID: String, workerTakesIt: Bool) async throws {
        let approve = AgentApproveRequest(sessionID: entry.sessionID, approvalID: approvalID, decision: .approve)
        _ = try await AgentApprovals.relay(
            approve,
            registry: registry,
            ledger: ledger,
            forward: { workerTakesIt },
            accepted: { $0 },
        )
    }

    try await relay("relay-build", workerTakesIt: false)
    try await relay("relay-remove", workerTakesIt: false)
    let refusedState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(refusedState.baseline == .changed, "a description approval the worker refused is not in the ledger")
    let refusedRemoval = await ledger.takeRemoval(installationID: "inst-relay", session: entry.sessionID)
    check(!refusedRemoval, "a removal approval the worker refused is not in the ledger")
    let refusedDecision = await sessions.entry(entry.sessionID)?.approvals["relay-build"]
    check(refusedDecision == nil, "a decision the worker refused is not kept for the session")

    try await relay("relay-build", workerTakesIt: true)
    try await relay("relay-remove", workerTakesIt: true)
    let acceptedState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(acceptedState.baseline == .approved, "a description approval the worker took is in the ledger")
    let acceptedRemoval = await ledger.takeRemoval(installationID: "inst-relay", session: entry.sessionID)
    check(acceptedRemoval, "a removal approval the worker took is in the ledger")

    // Refusing the same approval again does not take back the one that held.
    try await relay("relay-build", workerTakesIt: false)
    let keptState = try await ledger.state(of: digest, kind: .build, project: "p-relay")
    check(keptState.baseline == .approved, "a refused repeat leaves an earlier approval of the same digest")

    // Two sessions approve the same digest at once: A's relay records it,
    // B's (inside A's forward) finds it there and its worker takes it, then
    // A's worker refuses. B's approval must still hold.
    let shared = "sha256:" + String(repeating: "f", count: 64)
    let sharedBuild: JSONValue = .object(["descriptionChanged": .object([
        "kind": .string("build"), "digest": .string(shared),
    ])])
    var pair: [AgentSessionTable.Entry] = []
    for name in ["agent-relay-a", "agent-relay-b"] {
        let session = await AgentSessionTable.Entry(
            sessionID: name,
            task: registry.create(kind: .agent, owner: .agent, ownerKey: name),
            project: entry.project,
            mode: .confirm,
            createdAt: Date(),
        )
        await sessions.add(session)
        await registry.append(session.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string("shared-build"), "tool": .string("apelin_project_build"), "detail": sharedBuild,
        ]))
        pair.append(session)
    }
    func approve(_ session: AgentSessionTable.Entry) -> AgentApproveRequest {
        AgentApproveRequest(sessionID: session.sessionID, approvalID: "shared-build", decision: .approve)
    }
    _ = try await AgentApprovals.relay(
        approve(pair[0]),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            _ = try? await AgentApprovals.relay(
                approve(pair[1]),
                registry: registry,
                ledger: ledger,
                forward: { true },
                accepted: { $0 },
            )
            return false
        },
        accepted: { $0 },
    )
    let sharedState = try await ledger.state(of: shared, kind: .build, project: "p-relay")
    check(sharedState.baseline == .approved, "one session's refused relay leaves another session's accepted approval")

    // And the other way round: B refuses first, then A's worker refuses
    // too, and nothing is left.
    let unheld = "sha256:" + String(repeating: "c", count: 64)
    let unheldBuild: JSONValue = .object(["descriptionChanged": .object([
        "kind": .string("build"), "digest": .string(unheld),
    ])])
    for session in pair {
        await registry.append(session.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string("unheld-build"), "tool": .string("apelin_project_build"), "detail": unheldBuild,
        ]))
    }
    func approveUnheld(_ session: AgentSessionTable.Entry) -> AgentApproveRequest {
        AgentApproveRequest(sessionID: session.sessionID, approvalID: "unheld-build", decision: .approve)
    }
    _ = try await AgentApprovals.relay(
        approveUnheld(pair[0]),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            _ = try? await AgentApprovals.relay(
                approveUnheld(pair[1]),
                registry: registry,
                ledger: ledger,
                forward: { false },
                accepted: { $0 },
            )
            return false
        },
        accepted: { $0 },
    )
    let unheldState = try await ledger.state(of: unheld, kind: .build, project: "p-relay")
    check(unheldState.baseline == .changed, "a digest no session's worker accepted is taken back")
}

// MARK: - A withdrawn approval gives back the one it pushed out

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("evict-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("evict-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "0", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    let full = try await ledger.state(of: digest(0), kind: .build, project: "p-evict")
    check(full.baseline == .approved, "the ledger holds as many approvals as its cap")
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-evict",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-evict"),
        project: ResolvedProject(id: "p-evict", name: "Evict", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(entry)
    await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
        "approvalID": .string("evict-build"),
        "tool": .string("apelin_project_build"),
        "detail": .object(["descriptionChanged": .object([
            "kind": .string("build"), "digest": .string(digest(1000)),
        ])]),
    ]))
    var pushedOut = false
    _ = try await AgentApprovals.relay(
        AgentApproveRequest(sessionID: entry.sessionID, approvalID: "evict-build", decision: .approve),
        registry: registry,
        ledger: ledger,
        forward: { () async -> Bool in
            pushedOut = await (try? ledger.state(of: digest(0), kind: .build, project: "p-evict"))?.baseline == .changed
            return false
        },
        accepted: { $0 },
    )
    check(pushedOut, "a new approval past the cap pushes the oldest out")
    let restored = try await ledger.state(of: digest(0), kind: .build, project: "p-evict")
    check(restored.baseline == .approved, "withdrawing the new approval brings the pushed-out one back")
    let withdrawn = try await ledger.state(of: digest(1000), kind: .build, project: "p-evict")
    check(withdrawn.baseline == .changed, "the withdrawn approval is gone")
    let reloaded = ApprovalLedger(directory: scratch.appendingPathComponent("evict-approvals"))
    let onDisk = try await reloaded.state(of: digest(0), kind: .build, project: "p-evict")
    check(
        onDisk.baseline == .approved && onDisk.lastApprovedDigest == digest(63),
        "the restored ledger is the one on disk",
    )
}

// MARK: - A shell_run approved for the session runs again for that command only

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("grant-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("grant-approvals"))
    let sessions = AgentSessionTable.shared
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-grant",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-grant"),
        project: ResolvedProject(id: "p-grant", name: "Grant", path: scratchPath),
        mode: .confirm,
        createdAt: Date(),
    )
    await sessions.add(entry)
    func ask(_ approvalID: String, argv: [String], sessionScope: Bool, workingDirectory: String = ".") async {
        await registry.append(entry.task.taskID, kind: "approvalRequested", payload: .object([
            "approvalID": .string(approvalID),
            "tool": .string("shell_run"),
            "workingDirectory": .string(workingDirectory),
            "allowsSessionScope": .bool(sessionScope),
            "detail": .object(["command": .object(["argv": .object(["_0": .array(argv.map { .string($0) })])])]),
        ]))
    }
    func approve(_ approvalID: String, scope: ApprovalScope?, workerTakesIt: Bool = true) async throws {
        let approve = AgentApproveRequest(
            sessionID: entry.sessionID,
            approvalID: approvalID,
            decision: .approve,
            scope: scope,
        )
        _ = try await AgentApprovals.relay(
            approve,
            registry: registry,
            ledger: ledger,
            forward: { workerTakesIt },
            accepted: { $0 },
        )
    }
    func authorized(_ argv: [String], _ approval: RunCodeApproval, in directory: String = ".") async -> Bool {
        let run = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(argv),
            workingDirectory: directory,
            approval: approval,
        )
        do {
            try await AgentApprovals.authorize(run, entry: entry, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }

    let before = await authorized(["make"], .session)
    check(!before, "a session-scoped shell_run with no grant behind it is refused")

    await ask("make-session", argv: ["make"], sessionScope: true)
    try await approve("make-session", scope: .session)
    let first = await authorized(["make"], .user(approvalID: "make-session"))
    check(first, "the call the app approved for the session runs on its own approval")
    let second = await authorized(["make"], .session)
    let third = await authorized(["make"], .session)
    check(second && third, "the same command in the same directory runs again for the session")
    let otherCommand = await authorized(["make", "install"], .session)
    check(!otherCommand, "a session grant does not cover another command")
    let otherDirectory = await authorized(["make"], .session, in: "preset-project")
    check(!otherDirectory, "a session grant does not cover another working directory")

    // Once stays once, and a request that did not offer the session scope
    // grants nothing beyond its own call.
    await ask("ls-once", argv: ["ls", "-R"], sessionScope: true)
    try await approve("ls-once", scope: .once)
    _ = await authorized(["ls", "-R"], .user(approvalID: "ls-once"))
    let onceAgain = await authorized(["ls", "-R"], .session)
    check(!onceAgain, "an approval given once grants nothing for the session")
    await ask("rm-unoffered", argv: ["rm", "x"], sessionScope: false)
    try await approve("rm-unoffered", scope: .session)
    let unoffered = await authorized(["rm", "x"], .session)
    check(!unoffered, "a request that did not offer the session scope grants nothing for the session")

    // The worker refusing the decision takes the grant back.
    await ask("cc-refused", argv: ["cc", "main.c"], sessionScope: true)
    try await approve("cc-refused", scope: .session, workerTakesIt: false)
    let refusedGrant = await authorized(["cc", "main.c"], .session)
    check(!refusedGrant, "a session grant the worker refused is not kept")

    // Closing the session forgets its grants.
    await sessions.forgetGrants(entry.sessionID)
    let afterClose = await authorized(["make"], .session)
    check(!afterClose, "a closed session's grants are gone")
}

// MARK: - shell_run presets are read-only and stay in the project

do {
    let registry = TaskRegistry(directory: scratch.appendingPathComponent("preset-tasks"))
    await registry.load()
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("preset-approvals"))
    let project = scratchPath + "/preset-project"
    write(project + "/Sources/main.m", "int main(void) { return 0; }\n")
    write(project + "/Info.plist", "<plist version=\"1.0\"><dict/></plist>\n")
    write(scratchPath + "/preset-outside.txt", "outside\n")
    symlink("/etc/hosts", project + "/hosts-link")
    run("/usr/bin/git", ["init", "-q", "."], in: project)
    let entry = await AgentSessionTable.Entry(
        sessionID: "agent-presets",
        task: registry.create(kind: .agent, owner: .agent, ownerKey: "agent-presets"),
        project: ResolvedProject(id: "p-presets", name: "Presets", path: project),
        mode: .confirm,
        createdAt: Date(),
    )
    await AgentSessionTable.shared.add(entry)
    func preset(_ argv: [String], in directory: String = ".") async -> Bool {
        let request = AgentRunCodeRequest(
            sessionID: entry.sessionID,
            spec: .argv(argv),
            workingDirectory: directory,
            approval: .preset(argv[0]),
        )
        do {
            try await AgentApprovals.authorize(request, entry: entry, registry: registry, ledger: ledger, installRoot: "/")
            return true
        } catch {
            return false
        }
    }

    let passes: [([String], String)] = [
        (["ls", "-la"], "."),
        (["cat", "Sources/main.m"], "."),
        (["head", "-n", "5", "Sources/main.m"], "."),
        (["cat", "../Info.plist"], "Sources"),
        (["wc", "-l", "--", "Sources/main.m"], "."),
        (["plutil", "-p", "Info.plist"], "."),
        (["git", "status"], "."),
        (["git", "diff", "--stat"], "."),
        (["git", "log", "--oneline", "-n", "5"], "."),
    ]
    for (argv, directory) in passes {
        let passed = await preset(argv, in: directory)
        check(passed, "\(argv.joined(separator: " ")) in \(directory) is a preset")
    }
    let refused: [([String], String)] = [
        (["cat", "/etc/passwd"], "."),
        (["cat", "../preset-outside.txt"], "."),
        (["cat", "../../preset-outside.txt"], "Sources"),
        (["cat", "hosts-link"], "."),
        (["head", "--", "/etc/hosts"], "."),
        (["stat", "-f", "%z", "/etc/hosts"], "."),
        (["file", "-C", "-m", "magic"], "."),
        (["plutil", "-p", "Info.plist", "-o", "copy.plist"], "."),
        (["git", "diff", "--output=/tmp/apelin-preset-escape"], "."),
        (["git", "log", "--output", "log.txt"], "."),
        (["git", "diff", "-o", "diff.txt"], "."),
        (["git", "diff", "--ext-diff"], "."),
        (["git", "log", "-p", "--textconv"], "."),
        (["git", "status", "-c", "core.fsmonitor=x"], "."),
        (["git", "diff", "--no-index", "/etc/hosts", "Info.plist"], "."),
        (["git", "log", "--git-dir=/var"], "."),
        (["git", "status", "--work-tree", "/"], "."),
        (["git", "diff", "-C", "/"], "."),
        (["git", "log", "--exec-path=/tmp"], "."),
        // A list of names read from a file names files outside the project.
        (["file", "-f", "Info.plist"], "."),
        (["file", "-bf", "Info.plist"], "."),
        (["file", "--files-from", "Info.plist"], "."),
        (["file", "--files=Info.plist"], "."),
        (["file", "--comp", "-m", "magic"], "."),
        (["wc", "--files0-from=Info.plist"], "."),
        (["wc", "--files0-from", "Info.plist"], "."),
        (["wc", "--files0=Info.plist"], "."),
        (["cat", "--files-from=Info.plist"], "."),
        // Nothing reaches a submodule, abbreviated or not.
        (["git", "status", "--ignore-sub=none"], "."),
        (["git", "diff", "--submodule=diff"], "."),
        (["git", "log", "--recurse-submodules"], "."),
        // file prints how it reads, with no magic file or decompressor; ls
        // follows no link and walks no tree; git reads no order file and
        // verifies no signature.
        (["file", "-m/etc/passwd", "Info.plist"], "."),
        (["file", "-z", "Info.plist"], "."),
        (["ls", "-lL", "hosts-link"], "."),
        (["ls", "-R"], "."),
        (["git", "diff", "-O/etc/passwd"], "."),
        (["git", "log", "--show-signature"], "."),
        (["git", "log", "--format=%G?"], "."),
    ]
    for (argv, directory) in refused {
        let passed = await preset(argv, in: directory)
        check(!passed, "\(argv.joined(separator: " ")) in \(directory) is not a preset")
    }

    // A repository whose own config names a command is not read without
    // asking: git would run it (filters, textconv, fsmonitor, pager).
    let gitConfig = project + "/.git/config"
    let plainConfig = try String(contentsOfFile: gitConfig, encoding: .utf8)
    for extra in [
        "[filter \"evil\"]\n\tclean = touch /tmp/apelin-preset-escape\n",
        "[core]\n\tfsmonitor = /tmp/apelin-preset-escape\n",
        "[core]\n\tpager = sh -c 'touch /tmp/apelin-preset-escape'\n",
        "[include]\n\tpath = /tmp/apelin-preset-escape\n",
        "[diff \"evil\"]\n\ttextconv = touch\n",
        // git reads a section header and a key on one line, and a second
        // header behind the first.
        "[user \"a\"][filter \"x\"]clean = touch /tmp/apelin-preset-escape #]\n",
        "[user]name = a\n[filter \"x\"] clean = touch /tmp/apelin-preset-escape\n",
        "[includeIf \"gitdir:/\"]\n\tpath = /tmp/apelin-preset-escape\n",
        "[core \"x\"]\n\tbare = false\n",
        "[core]\n\tbare = \"unterminated\n",
    ] {
        try (plainConfig + extra).write(toFile: gitConfig, atomically: true, encoding: .utf8)
        let passed = await preset(["git", "status"])
        check(!passed, "git status in a repository configured with \(extra.split(separator: "\n")[0]) is not a preset")
    }
    // What a task clone writes is inert: its remote, its branch and the
    // task that made it.
    let cloned = plainConfig + """
    [remote "origin"]
    \turl = https://example.com/tweak.git
    \tfetch = +refs/heads/*:refs/remotes/origin/*
    [branch "main"]
    \tremote = origin
    \tmerge = refs/heads/main
    [apelin]
    \tcloneTask = 0f1e2d3c-task

    """
    try cloned.write(toFile: gitConfig, atomically: true, encoding: .utf8)
    let clonedPassed = await preset(["git", "status"])
    check(clonedPassed, "git status in a repository a task cloned is a preset")
    try plainConfig.write(toFile: gitConfig, atomically: true, encoding: .utf8)

    // A submodule has a config of its own the check never read: a
    // repository with one asks.
    write(project + "/.gitmodules", "[submodule \"evil\"]\n\tpath = evil\n\turl = https://example.com/e.git\n")
    let withGitmodules = await preset(["git", "status"])
    check(!withGitmodules, "git status in a repository with .gitmodules is not a preset")
    unlink(project + "/.gitmodules")
    mkdir(project + "/.git/modules", 0o755)
    let withModules = await preset(["git", "diff"])
    check(!withModules, "git diff in a repository with .git/modules is not a preset")
    rmdir(project + "/.git/modules")
    let plainAgain = await preset(["git", "status"])
    check(plainAgain, "git status in the plain repository is a preset again")

    // A folder laid out as a bare repository is the repository git uses
    // there, ahead of the project's .git; its config was never read.
    let bare = project + "/Sources/bare"
    write(bare + "/HEAD", "ref: refs/heads/main\n")
    mkdir(bare + "/objects", 0o755)
    mkdir(bare + "/refs", 0o755)
    write(bare + "/config", "[core]\n\tbare = true\n[filter \"x\"]\n\tclean = touch /tmp/apelin-preset-escape\n")
    for argv in [["git", "status"], ["git", "diff"], ["git", "log"]] {
        let inBare = await preset(argv, in: "Sources/bare")
        check(!inBare, "\(argv.joined(separator: " ")) in a bare layout inside the project is not a preset")
    }
    write(bare + "/objects/.keep", "")
    let belowBare = project + "/Sources/bare/objects"
    let fromBelow = await preset(["git", "status"], in: "Sources/bare/objects")
    check(!fromBelow && FileManager.default.fileExists(atPath: belowBare), "nor in a folder below one")
    try FileManager.default.removeItem(atPath: bare)

    // git skips a .git that is not a repository and walks on: from a folder
    // with an empty .git it uses the project's, whose config names a filter.
    let skipped = project + "/Sources/skipped"
    mkdir(skipped, 0o755)
    mkdir(skipped + "/.git", 0o755)
    try (plainConfig + "[filter \"x\"]\n\tclean = touch /tmp/apelin-preset-escape\n")
        .write(toFile: gitConfig, atomically: true, encoding: .utf8)
    let throughEmpty = await preset(["git", "status"], in: "Sources/skipped")
    check(!throughEmpty, "git status below an empty .git, in a repository with a filter, is not a preset")
    try plainConfig.write(toFile: gitConfig, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(atPath: skipped)

    // HEAD beside a commondir is a repository to git, sharing the project's
    // objects and config; it is not the project's .git, so it asks. Asked
    // without safe.bareRepository (which a git older than 2.38 ignores), git
    // still names a git directory other than its common one and no work
    // tree, so the host's check does not lean on that setting.
    let linked = project + "/linked"
    write(linked + "/HEAD", "ref: refs/heads/main\n")
    write(linked + "/commondir", "../.git\n")
    for argv in [["git", "status"], ["git", "log"]] {
        let inLinked = await preset(argv, in: "linked")
        check(!inLinked, "\(argv.joined(separator: " ")) in a folder with HEAD and commondir is not a preset")
    }
    let unguarded = Pipe()
    let revParse = Process()
    revParse.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    revParse.arguments = ["rev-parse", "--absolute-git-dir", "--git-common-dir"]
    revParse.environment = ["PATH": "/usr/bin:/bin", "HOME": scratchPath, "GIT_CONFIG_NOSYSTEM": "1"]
    revParse.currentDirectoryURL = URL(fileURLWithPath: linked)
    revParse.standardOutput = unguarded
    revParse.standardError = FileHandle.nullDevice
    try revParse.run()
    revParse.waitUntilExit()
    let named = String(decoding: unguarded.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").map(String.init)
    check(
        named.count == 2 && named[0] == linked && named[1] != named[0],
        "without safe.bareRepository git takes the folder as a repository whose common directory is another",
    )
    try FileManager.default.removeItem(atPath: linked)

    // With no .git between the working directory and the project, git finds
    // no repository the check read: not a preset.
    let unversioned = scratchPath + "/preset-unversioned"
    write(unversioned + "/Info.plist", "<plist version=\"1.0\"><dict/></plist>\n")
    let noRepository = await AgentRunCode.preset(
        .argv(["git", "status"]),
        directory: unversioned,
        project: unversioned,
        installRoot: "/",
    )
    check(noRepository == nil, "git status in a project with no .git is not a preset")

    // git runs with configured commands overridden and only the
    // repository's own config read.
    let diff = await AgentRunCode.preset(
        .argv(["git", "diff", "--stat"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(
        diff?.argv == ["git"] + AgentRunCode.gitOverrides
            + ["diff", "--no-ext-diff", "--no-textconv", "--ignore-submodules=all", "--stat"],
        "git diff runs with the overrides and without external diff, textconv or submodules",
    )
    let status = await AgentRunCode.preset(
        .argv(["git", "status"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(
        status?.argv == ["git"] + AgentRunCode.gitOverrides + ["status", "--ignore-submodules=all"],
        "git status runs with the overrides and without submodules",
    )
    check(AgentRunCode.gitOverrides.contains("submodule.recurse=false"), "no git preset recurses into a submodule")
    let environment = status?.environment ?? []
    check(
        environment.contains("GIT_CONFIG_NOSYSTEM=1") && environment.contains("GIT_CONFIG_GLOBAL=/dev/null")
            && environment.contains("GIT_CEILING_DIRECTORIES=\(scratchPath)"),
        "git reads no system or global config and finds no repository above the project",
    )
    let gitOutput = Pipe()
    let hardened = Process()
    hardened.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    hardened.arguments = Array((status?.argv ?? []).dropFirst())
    var gitEnvironment = ["PATH": "/usr/bin:/bin", "HOME": scratchPath]
    for pair in environment {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        gitEnvironment[String(parts[0])] = String(parts[1])
    }
    hardened.environment = gitEnvironment
    hardened.currentDirectoryURL = URL(fileURLWithPath: project)
    hardened.standardOutput = gitOutput
    hardened.standardError = gitOutput
    try hardened.run()
    hardened.waitUntilExit()
    check(hardened.terminationStatus == 0, "this git accepts the preset's overrides")
    // And with them it does not take a bare layout it was not pointed at.
    let bareAgain = project + "/Sources/bare"
    mkdir(bareAgain, 0o755)
    run("/usr/bin/git", ["init", "-q", "--bare", "."], in: bareAgain)
    func gitStatus(in directory: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = gitEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    // status needs a work tree anyway; rev-parse shows what git discovered.
    let overridden = try gitStatus(in: bareAgain, AgentRunCode.gitOverrides + ["rev-parse", "--is-bare-repository"])
    let discovered = try gitStatus(in: bareAgain, ["rev-parse", "--is-bare-repository"])
    check(
        overridden != 0 && discovered == 0,
        "the overrides keep git from using a bare repository found by discovery, which it uses otherwise",
    )
    try FileManager.default.removeItem(atPath: bareAgain)

    // A signed commit in history never starts gpg: with the overrides, a
    // log that would verify it finds no program where gpg.program points,
    // not the gpg first on PATH.
    let signed = scratchPath + "/preset-signed"
    let fakeTools = scratchPath + "/preset-fake-tools"
    let started = scratchPath + "/preset-gpg-started"
    write(fakeTools + "/gpg", "#!/bin/sh\ntouch '\(started)'\nexit 1\n", mode: 0o755)
    write(fakeTools + "/gpgsm", "#!/bin/sh\ntouch '\(started)'\nexit 1\n", mode: 0o755)
    mkdir(signed, 0o755)
    run("/usr/bin/git", ["init", "-q", "."], in: signed)
    write(signed + "/commit.txt", """
    tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    author A <a@example.com> 0 +0000
    committer A <a@example.com> 0 +0000
    gpgsig -----BEGIN PGP SIGNATURE-----
     \n iQEzBAABCAAdFiEE
     -----END PGP SIGNATURE-----

    signed

    """)
    let hashed = Pipe()
    let hash = Process()
    hash.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    hash.arguments = ["hash-object", "-t", "commit", "-w", "commit.txt"]
    hash.currentDirectoryURL = URL(fileURLWithPath: signed)
    hash.standardOutput = hashed
    try hash.run()
    hash.waitUntilExit()
    let commit = String(decoding: hashed.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    run("/usr/bin/git", ["update-ref", "HEAD", commit], in: signed)
    var fakeEnvironment = gitEnvironment
    fakeEnvironment["PATH"] = fakeTools + ":/usr/bin:/bin"
    func signatureLog(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = fakeEnvironment
        process.currentDirectoryURL = URL(fileURLWithPath: signed)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
    try signatureLog(["log", "--format=%G?"])
    let startsUnguarded = FileManager.default.fileExists(atPath: started)
    unlink(started)
    for verify in [["log", "--format=%G?"], ["log", "--show-signature"], ["-c", "log.showSignature=true", "log"]] {
        try signatureLog(AgentRunCode.gitOverrides + verify)
    }
    check(
        startsUnguarded && !FileManager.default.fileExists(atPath: started),
        "the overrides keep a signed commit from starting gpg, which a plain log starts",
    )
    let cat = await AgentRunCode.preset(
        .argv(["cat", "Info.plist"]),
        directory: project,
        project: project,
        installRoot: "/",
    )
    check(cat == AgentRunCode.Preset(argv: ["cat", "Info.plist"], environment: []), "a file tool runs as asked")
}

// MARK: - A git config read holds no thread of the cooperative pool

do {
    // As many reads as the pool has threads, each a second long: while they
    // run, a task started after them still runs at once.
    final class Started: @unchecked Sendable {
        let lock = NSLock()
        var after: TimeInterval?
    }
    let started = Started()
    let width = ProcessInfo.processInfo.activeProcessorCount
    let begin = Date()
    await withTaskGroup(of: Void.self) { group in
        for _ in 0 ..< width {
            group.addTask {
                _ = await AgentRunCode.capture(["/bin/sleep", "1"], environment: [], timeoutSeconds: 5)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: 50_000_000)
            started.lock.withLock { started.after = Date().timeIntervalSince(begin) }
        }
    }
    let after = started.lock.withLock { started.after } ?? .infinity
    check(after < 0.5, "a task runs while \(width) config reads wait on git (it waited \(after) s)")
}

// MARK: - shell_run returns although a process that left its group holds the pipes

do {
    /// The script prints, forks a child that calls setsid — out of the group
    /// the host kills — and keeps stdout and stderr open, writing its pid
    /// down so the test can kill it afterwards. With `then` sleeping too,
    /// the script itself runs into the timeout.
    func escaping(_ name: String, then: String, timeout: Int) -> (AgentRunCodeResponse?, TimeInterval)? {
        let pidFile = scratchPath + "/escaped-\(name).pid"
        let script = """
        use POSIX (); $| = 1; print "hi\\n";
        if (fork() == 0) {
            POSIX::setsid();
            open(my $f, '>', '\(pidFile)'); print $f $$; close($f);
            sleep 1000; exit 0;
        }
        # Go on only once the child has left the group, or the host's
        # group kill could reach it first and the pipes would just close.
        select(undef, undef, undef, 0.05) until -e '\(pidFile)';
        \(then)
        """
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var response: AgentRunCodeResponse?
        }
        let box = Box()
        let returned = DispatchSemaphore(value: 0)
        let begin = Date()
        Task.detached {
            let response = await AgentRunCode.capture(
                ["/usr/bin/perl", "-e", script],
                environment: ["PATH=/usr/bin:/bin"],
                timeoutSeconds: timeout,
            )
            box.lock.withLock { box.response = response }
            returned.signal()
        }
        // The test's own deadline: a call that never returns fails here
        // instead of hanging the harness.
        let finished = returned.wait(timeout: .now() + .seconds(timeout + 10)) == .success
        let elapsed = Date().timeIntervalSince(begin)
        if let text = try? String(contentsOfFile: pidFile, encoding: .utf8), let pid = pid_t(text) {
            kill(pid, SIGKILL)
        }
        guard finished else { return nil }
        return (box.lock.withLock { box.response }, elapsed)
    }

    func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }
    let descriptorsBefore = openDescriptors()
    let exited = escaping("exited", then: "exit 0;", timeout: 30)
    check(exited != nil, "shell_run returns when its script exits and an escaped child keeps the pipes open")
    if let (response, elapsed) = exited {
        check(openDescriptors() == descriptorsBefore, "the cut pipes are closed, none left open")
        check(elapsed < 6, "it returns within the drain after the script exits (it took \(elapsed) s)")
        check(response?.stdout == "hi\n", "what was printed before the cut is kept: \(String(describing: response))")
        check(response?.exitCode == 0 && response?.timedOut == false, "the script's own exit is reported")
        check(response?.truncated == true, "output cut at the drain is marked truncated")
    }

    let timedOut = escaping("timed-out", then: "sleep 1000;", timeout: 2)
    check(timedOut != nil, "shell_run returns at its timeout although an escaped child keeps the pipes open")
    if let (response, elapsed) = timedOut {
        check(elapsed < 2 + 6, "it returns within the timeout and the drain (it took \(elapsed) s)")
        check(response?.stdout == "hi\n" && response?.timedOut == true, "the timeout is reported with the output")
    }
}

// MARK: - A partial last event line does not swallow the events after it

do {
    let directory = scratch.appendingPathComponent("torn-events")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "torn")
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("two")]))
    // A crash in the middle of the third line.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    let torn = try FileHandle(forWritingTo: events)
    torn.seekToEndOfFile()
    torn.write(Data(#"{"seq":3,"kind":"log","pay"#.utf8))
    try torn.close()

    let second = TaskRegistry(directory: directory)
    await second.load()
    await second.append(handle.taskID, kind: "resumed", payload: .object(["resumes": .number(1)]))
    await second.append(handle.taskID, kind: "log", payload: .object(["line": .string("three")]))
    let third = TaskRegistry(directory: directory)
    await third.load()
    let replay = try await third.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.events.map(\.kind) == ["log", "log", "resumed", "log"]
            && replay.events.map(\.seq.rawValue) == [1, 2, 3, 4],
        "events appended after a torn line survive the next load",
    )

    // A last line that lost only its newline is an event all the same.
    let unterminated = try Data(String(contentsOf: events, encoding: .utf8).dropLast().utf8)
    try unterminated.write(to: events)
    let fourth = TaskRegistry(directory: directory)
    await fourth.load()
    await fourth.append(handle.taskID, kind: "log", payload: .object(["line": .string("four")]))
    let fifth = TaskRegistry(directory: directory)
    await fifth.load()
    let kept = try await fifth.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        kept.events.map(\.seq.rawValue) == [1, 2, 3, 4, 5],
        "a last event missing only its newline is kept, and the next one follows it",
    )
}

// MARK: - A final state in the log outranks a record written before it

do {
    let directory = scratch.appendingPathComponent("state-ahead-of-record")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "ahead")
    await first.setResume(handle.taskID, .object(["operation": .string("buildStart"), "resumes": .number(0)]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("linked")]))
    // `append` writes the line, then the record: a crash between the two.
    let final = TaskEvent(
        seq: EventSeq(2),
        kind: TaskEvent.stateKind,
        payload: .object(["state": .string("succeeded"), "artifactID": .string(handle.taskID.rawValue)]),
    )
    var line = try JSONCoding.encode(final)
    line.append(0x0A)
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    let log = try FileHandle(forWritingTo: events)
    log.seekToEndOfFile()
    log.write(line)
    try log.close()

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a task whose log ends in a final state is not handed to a resumer")
    let corrected = await second.record(handle.taskID)
    check(corrected?.state == .succeeded, "its state is the one the log ended with")
    let replay = try await second.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.finished && replay.events.last?.payload?["artifactID"]?.stringValue == handle.taskID.rawValue,
        "it reads as finished, with the final event's result",
    )
    let stored = try JSONCoding.decoder().decode(
        TaskRegistry.Record.self,
        from: Data(contentsOf: directory.appendingPathComponent("\(handle.taskID.rawValue).json")),
    )
    check(stored.state == .succeeded, "the corrected record is written back")
}

// MARK: - A bad line in the middle of the log loses nothing after it

do {
    let directory = scratch.appendingPathComponent("bad-middle-line")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "middle")
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("one")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("two")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("three")]))
    await first.finish(handle.taskID, .succeeded)
    // The third line rewritten in a shape this build cannot read (a
    // corrupted line, or one a newer build wrote before a downgrade).
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[2] = #"{"seq":3,"kind":"log","time":"a shape from elsewhere"}"#
    let rewritten = lines.joined(separator: "\n")
    try Data(rewritten.utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a final state after a bad line still ends the task")
    let replay = try await second.attach(handle.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        replay.events.map(\.seq.rawValue) == [1, 2, 3, 4] && replay.finished && replay.state == .succeeded,
        "the events after a bad line are read, numbered with no gap: \(replay.events.map(\.seq.rawValue))",
    )
    check(
        replay.events.count == 4 && replay.events[2].kind == TaskRegistry.unreadableKind,
        "the bad line reads as an unreadable event",
    )
    let after = try String(contentsOf: events, encoding: .utf8)
    check(after == rewritten, "the log keeps every line, the bad one included")

    // A bad last line that has its newline is skipped, not cut, and what is
    // appended after it is read back.
    let open = await second.create(kind: .build, owner: .build, ownerKey: "middle-open")
    await second.append(open.taskID, kind: "log", payload: .object(["line": .string("one")]))
    let openEvents = directory.appendingPathComponent("\(open.taskID.rawValue).events.jsonl")
    let tail = try FileHandle(forWritingTo: openEvents)
    tail.seekToEndOfFile()
    tail.write(Data(#"{"seq":2,"kind":"log","time":"a shape from elsewhere"}"#.utf8 + [0x0A]))
    try tail.close()
    let third = TaskRegistry(directory: directory)
    await third.load()
    await third.append(open.taskID, kind: "log", payload: .object(["line": .string("two")]))
    let fourth = TaskRegistry(directory: directory)
    await fourth.load()
    let reread = try await fourth.attach(open.taskID, as: .buildAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        reread.events.map(\.seq.rawValue) == [1, 2] && reread.events.last?.payload?["line"]?.stringValue == "two",
        "an event appended after a bad last line is read back",
    )
    let openLog = try String(contentsOf: openEvents, encoding: .utf8)
    check(openLog.contains("a shape from elsewhere"), "and the bad line is still in the log")
}

// MARK: - A finished record is not pulled back to running by an unreadable final line

do {
    let directory = scratch.appendingPathComponent("unreadable-final-state")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .build, owner: .build, ownerKey: "unreadable-final")
    await first.setResume(handle.taskID, .object(["operation": .string("buildStart"), "resumes": .number(0)]))
    await first.append(handle.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("running")]))
    await first.append(handle.taskID, kind: "log", payload: .object(["line": .string("linked")]))
    await first.finish(handle.taskID, .succeeded)
    // The final line is whole, newline and all, but no longer decodes.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[2] = #"{"seq":3,"kind":"state","time":"a shape from elsewhere"}"#
    try Data(lines.joined(separator: "\n").utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.isEmpty, "a finished record is not resumed when its final state line cannot be read")
    let kept = await second.record(handle.taskID)
    check(kept?.state == .succeeded, "it keeps the finished state the record holds: \(String(describing: kept?.state))")
}

// MARK: - A finished task whose final lines cannot be read still ends with a state

do {
    let directory = scratch.appendingPathComponent("unreadable-final-lines")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .confirmLoaded, owner: .diagnostics, ownerKey: "unreadable-tail")
    await first.append(handle.taskID, kind: "stage", payload: .object(["stage": .string("listening")]))
    await first.append(handle.taskID, kind: "stage", payload: .object(["stage": .string("trigger")]))
    await first.append(
        handle.taskID,
        kind: TaskEvent.stateKind,
        payload: .object(["state": .string("succeeded"), "result": .object(["loaded": .bool(true)])]),
    )
    // The last two lines are whole, newline and all, but no longer decode.
    let events = directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl")
    var lines = try String(contentsOf: events, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    lines[1] = #"{"seq":2,"kind":"stage","time":"a shape from elsewhere"}"#
    lines[2] = #"{"seq":3,"kind":"state","time":"a shape from elsewhere"}"#
    try Data(lines.joined(separator: "\n").utf8).write(to: events)

    let second = TaskRegistry(directory: directory)
    await second.load()
    let replay = try await second.attach(
        handle.taskID,
        as: .confirmLoadedAttach,
        afterSeq: .start,
        waitMilliseconds: 0,
    )
    let final = replay.events.last
    check(
        replay.finished && final?.kind == TaskEvent.stateKind
            && final?.payload?["state"]?.stringValue == "succeeded",
        "a finished task whose final state line cannot be read ends with a state event: \(replay.events.map(\.kind))",
    )
    check(
        replay.events.map(\.seq.rawValue) == [1, 2, 3, 4]
            && replay.events[1].kind == TaskRegistry.unreadableKind
            && replay.events[2].kind == TaskRegistry.unreadableKind,
        "the trailing lines that cannot be read keep their numbers: \(replay.events.map(\.seq.rawValue))",
    )
    let record = await second.record(handle.taskID)
    check(record?.lastSeq == final?.seq, "the record's last number is the closing state's")
    let stored = try JSONCoding.decoder().decode(
        TaskRegistry.Record.self,
        from: Data(contentsOf: directory.appendingPathComponent("\(handle.taskID.rawValue).json")),
    )
    check(stored.lastSeq == EventSeq(4), "and the record on disk says so too")
    if let final {
        expectError("the load check's answer says its final line could not be read", code: .internal) {
            _ = try ConfirmLoadedResponse.from(finalState: final)
        }
    }

    // The closing state is written down, so the next load reads it as is.
    let third = TaskRegistry(directory: directory)
    await third.load()
    let reread = try await third.attach(handle.taskID, as: .confirmLoadedAttach, afterSeq: .start, waitMilliseconds: 0)
    check(
        reread.events.map(\.seq.rawValue) == [1, 2, 3, 4] && reread.events.last?.kind == TaskEvent.stateKind,
        "the closing state survives the next load with the same numbers",
    )
}

// MARK: - Ordinary events leave the record alone; a restart reads them back

do {
    let directory = scratch.appendingPathComponent("record-writes")
    let first = TaskRegistry(directory: directory)
    await first.load()
    let handle = await first.create(kind: .agent, owner: .agent, ownerKey: "record-writes")
    let recordFile = directory.appendingPathComponent("\(handle.taskID.rawValue).json")
    // The record is replaced whole when it is written (temporary file, then
    // rename), so one written again has another inode.
    func recordInode() -> ino_t {
        var metadata = stat()
        return stat(recordFile.path, &metadata) == 0 ? metadata.st_ino : 0
    }
    func storedRecord() throws -> TaskRegistry.Record {
        try JSONCoding.decoder().decode(TaskRegistry.Record.self, from: Data(contentsOf: recordFile))
    }
    let created = recordInode()
    let createdBytes = FileManager.default.contents(atPath: recordFile.path)

    // A reopened conversation relays its history into its new task, as
    // ordinary events by the thousand.
    for index in 1 ... 2000 {
        await first.append(handle.taskID, kind: "text", payload: .object(["text": .string("\(index)")]))
    }
    await first.append(handle.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("running")]))
    check(
        recordInode() == created && FileManager.default.contents(atPath: recordFile.path) == createdBytes,
        "ordinary events, and a state event that leaves the task as it was, do not write the record again",
    )
    await first.append(handle.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("waitingForApproval")]))
    let waiting = recordInode()
    let stored = try storedRecord()
    check(
        waiting != created && stored.state == .waitingForApproval && stored.lastSeq == EventSeq(2002),
        "a state event that moves the task writes the record: \(stored.state) at \(stored.lastSeq)",
    )
    await first.append(handle.taskID, kind: "approvalResolved", payload: .object(["approvalID": .string("a1")]))
    await first.append(handle.taskID, kind: TaskEvent.stateKind, payload: .object(["state": .string("running")]))
    let running = recordInode()
    let movedBack = try storedRecord()
    check(running != waiting && movedBack.state == .running, "and so does the one that moves it back")
    for index in 1 ... 500 {
        await first.append(handle.taskID, kind: "text", payload: .object(["text": .string("again \(index)")]))
    }
    check(recordInode() == running, "the events after it leave the record alone again")
    let inMemory = await first.record(handle.taskID)
    check(inMemory?.lastSeq == EventSeq(2504), "the host's own record counts every event")

    // A new host on the same directory takes the number and the time from
    // the log, which the record on disk lags behind.
    let second = TaskRegistry(directory: directory)
    let unfinished = await second.load()
    check(unfinished.map(\.id) == [handle.taskID], "the running task is handed back")
    let reloaded = await second.record(handle.taskID)
    let lines = try String(contentsOf: directory.appendingPathComponent("\(handle.taskID.rawValue).events.jsonl"), encoding: .utf8)
        .split(separator: "\n")
    let lastLine = try lines.last.map { try JSONCoding.decoder().decode(TaskEvent.self, from: Data($0.utf8)) }
    check(
        reloaded?.lastSeq == inMemory?.lastSeq && reloaded?.state == inMemory?.state,
        "its number and state are the ones the first host had: \(String(describing: reloaded?.lastSeq)), \(String(describing: reloaded?.state))",
    )
    if let reloaded, let inMemory, let lastLine {
        check(
            reloaded.updatedAt == lastLine.time && abs(reloaded.updatedAt.timeIntervalSince(inMemory.updatedAt)) < 1,
            "its time is the last event's, as the log keeps it: \(reloaded.updatedAt), \(inMemory.updatedAt)",
        )
    } else {
        check(false, "the task and its last event read back")
    }
    // agentList's time for the session is the record's.
    let table = AgentSessionTable()
    await table.add(AgentSessionTable.Entry(
        sessionID: "record-writes",
        task: handle,
        project: ResolvedProject(id: "p-record-writes", name: "Record Writes", path: scratchPath),
        mode: .confirm,
        createdAt: Date.distantPast,
    ))
    let summary = await table.summaries(registry: second).first
    check(
        summary?.updatedAt == reloaded?.updatedAt && summary?.state == .running,
        "agentList reports the time of the last event after a restart",
    )
    let next = await second.append(handle.taskID, kind: "text", payload: .object(["text": .string("after")]))
    check(next?.seq == EventSeq(2505), "numbering goes on from the last event")
    await second.finish(handle.taskID, .succeeded)
    let final = try storedRecord()
    check(final.state == .succeeded && final.lastSeq == EventSeq(2506), "the final state writes the record")
    let third = TaskRegistry(directory: directory)
    let none = await third.load()
    let ended = await third.record(handle.taskID)
    check(
        none.isEmpty && ended?.state == .succeeded && ended?.lastSeq == EventSeq(2506),
        "and a third host reads the task as finished",
    )

    // A record written long before its last events takes their time; one
    // written after them keeps its own.
    let lagging = scratch.appendingPathComponent("record-lags")
    try FileManager.default.createDirectory(at: lagging, withIntermediateDirectories: true)
    let written = Date(timeIntervalSince1970: 1_800_000_000)
    func writeRecord(updatedAt: Date, eventsAt times: [Date]) throws -> TaskID {
        let id = TaskID.make()
        let record = TaskRegistry.Record(
            id: id,
            kind: .build,
            state: .running,
            createdAt: written,
            updatedAt: updatedAt,
            lastSeq: .start,
            owner: .build,
            ownerKey: "lags",
            cancelRequested: false,
            resume: nil,
        )
        try JSONCoding.encode(record).write(to: lagging.appendingPathComponent("\(id.rawValue).json"))
        var log = Data()
        for (index, time) in times.enumerated() {
            log += try JSONCoding.encode(TaskEvent(seq: EventSeq(UInt64(index + 1)), kind: "log", time: time))
            log.append(0x0A)
        }
        try log.write(to: lagging.appendingPathComponent("\(id.rawValue).events.jsonl"))
        return id
    }
    let behind = try writeRecord(updatedAt: written, eventsAt: [written.addingTimeInterval(60), written.addingTimeInterval(120)])
    let ahead = try writeRecord(updatedAt: written.addingTimeInterval(600), eventsAt: [written.addingTimeInterval(60)])
    let fourth = TaskRegistry(directory: lagging)
    await fourth.load()
    let caughtUp = await fourth.record(behind)
    check(
        caughtUp?.updatedAt == written.addingTimeInterval(120) && caughtUp?.lastSeq == EventSeq(2),
        "a record behind its log takes the last event's time and number",
    )
    let kept = await fourth.record(ahead)
    check(kept?.updatedAt == written.addingTimeInterval(600), "a record's time never moves back")
}

// MARK: - A digest pushed out while still pending is not brought back

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("pending-evict-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "1", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-pending-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    // A is recorded and stays pending while the rest of the list turns over
    // under it, until A is the oldest entry.
    let grantA = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-pending-evict")
    for index in 2000 ..< 2000 + ApprovalLedger.maximumApprovals - 1 {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-pending-evict") {
            await ledger.confirmApproval(grant)
        }
    }
    // B pushes A out; then both workers refuse.
    let grantB = try await ledger.recordApproval(digest(3000), kind: .build, project: "p-pending-evict")
    let pushedOut = try await ledger.state(of: digest(1000), kind: .build, project: "p-pending-evict")
    check(pushedOut.baseline == .changed, "B past the cap pushes out A, the oldest")
    if let grantA {
        try await ledger.withdrawApproval(grantA)
    }
    if let grantB {
        try await ledger.withdrawApproval(grantB)
    }
    let afterB = try await ledger.state(of: digest(1000), kind: .build, project: "p-pending-evict")
    check(afterB.baseline == .changed, "withdrawing B does not bring back A, which no worker accepted")
}

// MARK: - Approving an approved description again moves it to the newest end

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("reapprove-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "2", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-reapprove") {
            await ledger.confirmApproval(grant)
        }
    }
    let again = try await ledger.recordApproval(digest(0), kind: .build, project: "p-reapprove")
    check(again == nil, "approving an accepted digest again has nothing to take back")
    let moved = try await ledger.state(of: digest(0), kind: .build, project: "p-reapprove")
    check(moved.lastApprovedDigest == digest(0), "it is now the newest approval")
    _ = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-reapprove")
    let kept = try await ledger.state(of: digest(0), kind: .build, project: "p-reapprove")
    check(kept.baseline == .approved, "the next approval past the cap pushes out another, not the re-approved one")
    let dropped = try await ledger.state(of: digest(1), kind: .build, project: "p-reapprove")
    check(dropped.baseline == .changed, "the oldest left is the one pushed out")
}

// MARK: - Approvals brought back by withdrawn grants keep their age order

do {
    let ledger = ApprovalLedger(directory: scratch.appendingPathComponent("restore-order-approvals"))
    func digest(_ index: Int) -> String {
        "sha256:" + String(repeating: "3", count: 56) + String(format: "%08x", index)
    }
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await ledger.recordApproval(digest(index), kind: .build, project: "p-restore-order") {
            await ledger.confirmApproval(grant)
        }
    }
    // E pushes out 0, then F pushes out 1; both are withdrawn in the order
    // they were made.
    let grantE = try await ledger.recordApproval(digest(1000), kind: .build, project: "p-restore-order")
    let grantF = try await ledger.recordApproval(digest(1001), kind: .build, project: "p-restore-order")
    check(grantE?.evicted == digest(0) && grantF?.evicted == digest(1), "E and F each push out the oldest")
    if let grantE {
        try await ledger.withdrawApproval(grantE)
    }
    if let grantF {
        try await ledger.withdrawApproval(grantF)
    }
    // The next approval past the cap must push out 0 again, the oldest.
    if let grant = try await ledger.recordApproval(digest(2000), kind: .build, project: "p-restore-order") {
        await ledger.confirmApproval(grant)
    }
    let oldest = try await ledger.state(of: digest(0), kind: .build, project: "p-restore-order")
    let next = try await ledger.state(of: digest(1), kind: .build, project: "p-restore-order")
    check(
        oldest.baseline == .changed && next.baseline == .approved,
        "approvals put back in the order their grants were made keep their age order",
    )

    // Withdrawn the other way round, the same order comes back.
    let reverse = ApprovalLedger(directory: scratch.appendingPathComponent("restore-reverse-approvals"))
    for index in 0 ..< ApprovalLedger.maximumApprovals {
        if let grant = try await reverse.recordApproval(digest(index), kind: .build, project: "p-restore-reverse") {
            await reverse.confirmApproval(grant)
        }
    }
    let grantG = try await reverse.recordApproval(digest(1000), kind: .build, project: "p-restore-reverse")
    let grantH = try await reverse.recordApproval(digest(1001), kind: .build, project: "p-restore-reverse")
    if let grantH {
        try await reverse.withdrawApproval(grantH)
    }
    if let grantG {
        try await reverse.withdrawApproval(grantG)
    }
    if let grant = try await reverse.recordApproval(digest(2000), kind: .build, project: "p-restore-reverse") {
        await reverse.confirmApproval(grant)
    }
    let reverseOldest = try await reverse.state(of: digest(0), kind: .build, project: "p-restore-reverse")
    let reverseNext = try await reverse.state(of: digest(1), kind: .build, project: "p-restore-reverse")
    check(
        reverseOldest.baseline == .changed && reverseNext.baseline == .approved,
        "approvals put back in the reverse order keep their age order too",
    )
}

// MARK: - An agent-opened session keeps its opener across a restart

do {
    let state = scratch.appendingPathComponent("lineage-state")
    let session = UUID().uuidString
    let parent = UUID().uuidString
    let record = AgentSessionLineage.Record(parentSessionID: parent, depth: 2)
    AgentSessionLineage.save(record, session: session, state: state)
    check(AgentSessionLineage.load(session: session, state: state) == record, "a saved opener and depth read back")
    let folder = state.appendingPathComponent("agent-sessions")
    check(
        FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(session).json").path),
        "the record is the session's own file in agent-sessions",
    )
    var folderMetadata = stat()
    check(
        stat(folder.path, &folderMetadata) == 0 && folderMetadata.st_mode & 0o777 == 0o700,
        "the records' folder is its owner's alone",
    )
    check(AgentSessionLineage.load(session: UUID().uuidString, state: state) == nil, "another session has no opener")
    let escaped = state.appendingPathComponent("x.json")
    AgentSessionLineage.save(record, session: "../x", state: state)
    check(!FileManager.default.fileExists(atPath: escaped.path), "a session ID that is not a UUID writes nothing")
    try JSONCoding.encode(record).write(to: escaped)
    check(AgentSessionLineage.load(session: "../x", state: state) == nil, "and reads nothing, even with a file there")
}

// MARK: - A shell_run call its session stopped before it spawned does not run on

do {
    let session = UUID().uuidString
    // The call took its count, then a Stop came while it was being checked.
    let seen = AgentRunCode.stopCount(session: session)
    AgentRunCode.stop(session: session)
    var begin = Date()
    let stopped = await AgentRunCode.capture(
        ["/bin/sleep", "30"],
        environment: [],
        timeoutSeconds: 30,
        session: session,
        stopsSeen: seen,
    )
    var elapsed = Date().timeIntervalSince(begin)
    check(elapsed < 3, "a call stopped before it spawned ends as it spawns (it took \(elapsed) s)")
    check(
        stopped?.exitCode == 137 && stopped?.timedOut == false,
        "it is killed, not timed out: \(String(describing: stopped))",
    )
    check(AgentRunCode.stopCount(session: session) == seen + 1, "the stop is counted once")

    // A call that took its count after the stop runs to its own end.
    let later = AgentRunCode.stopCount(session: session)
    let finished = await AgentRunCode.capture(
        ["/bin/sleep", "1"],
        environment: [],
        timeoutSeconds: 30,
        session: session,
        stopsSeen: later,
    )
    check(
        finished?.exitCode == 0 && finished?.timedOut == false,
        "a call after the stop runs: \(String(describing: finished))",
    )

    // A stop while a call runs ends it.
    begin = Date()
    let running = Task.detached {
        await AgentRunCode.capture(
            ["/bin/sleep", "30"],
            environment: [],
            timeoutSeconds: 30,
            session: session,
            stopsSeen: later,
        )
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    AgentRunCode.stop(session: session)
    let killed = await running.value
    elapsed = Date().timeIntervalSince(begin)
    check(elapsed < 3 && killed?.exitCode == 137, "a stop ends a running call (\(elapsed) s, \(String(describing: killed)))")
}

// MARK: - A negative ustar size neither loops nor traps

do {
    /// One header and one zero block: `name`, a regular file, its size
    /// field spelled `size`.
    func tar(name: String, size: String) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1024)
        bytes.replaceSubrange(0 ..< name.utf8.count, with: name.utf8)
        bytes.replaceSubrange(124 ..< 124 + size.utf8.count, with: size.utf8)
        bytes[156] = UInt8(ascii: "0")
        return bytes
    }
    // `body` on a thread of its own: a walk that never ends fails here
    // instead of hanging the harness.
    func returns(_ body: @escaping @Sendable () -> String?) -> (returned: Bool, value: String?) {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: String?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Thread {
            let value = body()
            box.lock.withLock { box.value = value }
            done.signal()
        }.start()
        guard done.wait(timeout: .now() + 5) == .success else { return (false, nil) }
        return (true, box.lock.withLock { box.value })
    }

    let backwards = tar(name: "./x", size: "-2000")
    let walked = returns { DebControlPeek.controlFile(inTar: backwards) }
    check(walked.returned && walked.value == nil, "a negative size before ./control ends the walk")
    let inverted = tar(name: "./control", size: "-1")
    let read = returns { DebControlPeek.controlFile(inTar: inverted) }
    check(read.returned && read.value == nil, "a negative size on ./control is refused")

    let deb = scratchPath + "/negative-size.deb"
    FileManager.default.createFile(
        atPath: deb,
        contents: arArchive([("debian-binary", Data("2.0\n".utf8)), ("control.tar", Data(backwards))]),
    )
    let descriptor = open(deb, O_RDONLY)
    defer { close(descriptor) }
    let outcome = returns {
        do {
            _ = try DebControlPeek.read(descriptor: descriptor)
            return "read"
        } catch DebControlPeek.Failure.unreadable {
            return "unreadable"
        } catch {
            return "\(error)"
        }
    }
    check(outcome.returned && outcome.value == "unreadable", "a deb with that control member is unreadable: \(outcome)")
}

// MARK: - One file's backups are never another's

do {
    let root = scratchPath + "/backup-root"
    let home = root + "/var/mobile"
    try FileManager.default.createDirectory(
        atPath: home + "/Documents/wiki.qaq.apelin",
        withIntermediateDirectories: true,
    )
    write(root + "/etc/a_b", "underscore\n")
    write(root + "/etc/a/b", "nested\n")
    let store = BackupStore(home: home)
    let underscore = try store.save(path: root + "/etc/a_b")
    // Names are stamped to the millisecond and made with O_EXCL.
    for _ in 0 ..< 11 {
        usleep(2000)
        _ = try store.save(path: root + "/etc/a/b")
    }
    check(store.list(for: root + "/etc/a_b") == [underscore], "a/b's backups do not prune a_b's")
    let nested = store.list(for: root + "/etc/a/b")
    check(nested.count == 10 && !nested.contains(underscore), "a/b keeps its own newest ten, none of a_b's")

    check(
        BackupStore.key(for: "/x-var/jb/etc/hosts") != BackupStore.key(for: "/var/jb/etc/hosts"),
        "a path ending in another's has another key",
    )
    // A backup of /x-var/jb/etc/hosts: its name ends in /var/jb/etc/hosts's
    // flattened path, and is still not that file's.
    let other = "20261022-000000-000-" + BackupStore.key(for: "/x-var/jb/etc/hosts")
    FileManager.default.createFile(atPath: store.folder + "/" + other, contents: Data())
    check(!store.list(for: "/var/jb/etc/hosts").contains(other), "a backup is listed for its own file only")
}

print("\(checks - failures)/\(checks) session host checks passed")
exit(failures == 0 ? 0 : 1)
