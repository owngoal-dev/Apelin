import ApelinCore
import ApelinDiagnostics
import ApelinProtocol
import ConfirmLoaded
import Foundation

extension DiagnosticsService {
    // MARK: confirmLoaded

    /// A checked request: what to look for, where, and what to do first.
    struct LoadCheck: Sendable {
        var confirmation: LoadConfirmationRequest
        var trigger: LoadTrigger?
    }

    /// Checks the request — a bad one is the reply, not a failed task — then
    /// runs the check on its own thread and ends the host's task with the
    /// answer as `result` in the final `state`. The respring it may trigger
    /// takes the app down, not this worker or the host, so the answer is
    /// kept with the task whether or not anyone is attached.
    ///
    /// The check is in `loadChecks` before the host hears the task
    /// accepted, so the host's cancel, which only a caller holding the
    /// task's handle can ask for, always finds it: the listen ends at once
    /// and the task ends `cancelled`.
    func startConfirmLoaded(_ request: ApelinProtocol.ConfirmLoadedRequest, taskID: TaskID) async throws {
        let check = try await prepareConfirmLoaded(request)
        let emit = emit
        let loadChecks = loadChecks
        let stop = loadChecks.begin(taskID)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let response = runConfirmLoaded(check, stop: stop) { stage in
                var payload: [String: JSONValue] = ["stage": .string(stage.rawValue)]
                switch stage {
                case .listening:
                    payload["marker"] = .string(check.confirmation.marker)
                    payload["process"] = .string(check.confirmation.targetExecutable)
                    payload["windowSeconds"] = .number(check.confirmation.logWindow)
                case .trigger:
                    payload["trigger"] = .string(check.trigger?.rawValue ?? "")
                }
                emit(taskID, "stage", .object(payload))
            }
            loadChecks.end(taskID)
            var final: [String: JSONValue] = ["state": .string(TaskState.succeeded.rawValue)]
            if stop.isStopped {
                final = ["state": .string(TaskState.cancelled.rawValue)]
            } else {
                do {
                    final[ApelinProtocol.ConfirmLoadedResponse.stateMember] = try JSONValue(encoding: response)
                } catch {
                    final = [
                        "state": .string(TaskState.failed.rawValue),
                        "message": .string("the answer does not encode: \(error)"),
                    ]
                }
            }
            emit(taskID, TaskEvent.stateKind, .object(final))
        }
    }

    /// The whole check in one call, for tests: checked, run, answered.
    func confirmLoaded(
        _ request: ApelinProtocol.ConfirmLoadedRequest,
    ) async throws -> ApelinProtocol.ConfirmLoadedResponse {
        let check = try await prepareConfirmLoaded(request)
        return await blocking { runConfirmLoaded(check, stop: nil, stage: nil) }
    }

    static let maximumBuildIDBytes = 200
    static let maximumTargetIDBytes = 256

    func prepareConfirmLoaded(_ request: ApelinProtocol.ConfirmLoadedRequest) async throws -> LoadCheck {
        let buildID = request.buildID
        guard !buildID.isEmpty, buildID.utf8.count <= Self.maximumBuildIDBytes, !buildID.contains("\0") else {
            throw ApelinError(.badRequest, "buildID must be 1–\(Self.maximumBuildIDBytes) bytes")
        }
        if request.imageCheck != nil {
            throw ApelinError(
                .badRequest,
                "imageCheck is disabled on every iOS version: reading another process's image list panicked the kernel on a test device.",
            )
        }
        let window = request.logWindowSeconds
            ?? ApelinProtocol.ConfirmLoadedRequest.defaultLogWindowSeconds(trigger: request.trigger)
        guard window.isFinite, ApelinProtocol.ConfirmLoadedRequest.logWindowRange.contains(window) else {
            let range = ApelinProtocol.ConfirmLoadedRequest.logWindowRange
            throw ApelinError(
                .badRequest,
                String(format: "logWindowSeconds must be %g–%g", range.lowerBound, range.upperBound),
            )
        }
        let target = try await resolveTarget(request.targetID)
        var plan = LoadPlan(
            marker: BuildLoadCheck.marker(buildID: buildID),
            subsystem: nil,
            dylibPath: "",
            filterPlist: nil,
        )
        if let projectID = request.projectID {
            let manifest = try ProjectFolders.manifest(projectID: projectID, home: home)
            // A workspace has no package in its manifest: its own build
            // recorded what the package it made installs.
            if manifest["package"] == nil, let check = ProjectFolders.loadCheck(buildID: buildID, home: home) {
                plan = LoadPlan.from(loadCheck: check)
            } else {
                plan = try LoadPlan.from(manifest: manifest, buildID: buildID, installRoot: installRoot)
            }
        }
        let confirmation = LoadConfirmationRequest(
            marker: plan.marker,
            markerSubsystem: plan.subsystem,
            targetExecutable: target.executable,
            targetBundleIdentifier: target.bundleIdentifier,
            dylibPath: plan.dylibPath,
            filterPlist: plan.filterPlist,
            coreFoundationVersion: kCFCoreFoundationVersionNumber,
            logWindow: window,
        )
        return LoadCheck(confirmation: confirmation, trigger: request.trigger)
    }

    /// Blocks until the marker is heard, the window ends or `stop` is told
    /// to. The target's image list is never read; the process list is, by
    /// pid and name, to say whether the target ran meanwhile.
    func runConfirmLoaded(
        _ check: LoadCheck,
        stop: LoadCheckStop?,
        stage: (@Sendable (ConfirmLoaded.Stage) -> Void)?,
    ) -> ApelinProtocol.ConfirmLoadedResponse {
        var trigger: (@Sendable () throws -> Void)?
        if check.trigger == .respring {
            let host = host
            let diagnostics = diagnostics
            trigger = { try DiagnosticsService.respring(host: host, diagnostics: diagnostics) }
        }
        let confirm = ConfirmLoaded(logs: diagnostics, processes: diagnostics, lookInterval: processLookInterval)
        let result = confirm.run(check.confirmation, trigger: trigger, stage: stage, stop: stop)
        var evidence = [
            LoadEvidence(
                kind: "log",
                passed: result.marker.status == .confirmed,
                detail: "\(result.marker.status.rawValue): \(result.marker.detail)",
            ),
            LoadEvidence(
                kind: "image",
                passed: false,
                detail: "\(result.image.status.rawValue): \(result.image.detail)",
            ),
            LoadEvidence(
                kind: "filter",
                passed: result.filter.status == .confirmed,
                detail: "\(result.filter.status.rawValue): \(result.filter.detail)",
            ),
        ]
        var process: LoadTargetProcess?
        if let seen = result.process {
            evidence.append(LoadEvidence(
                kind: "process",
                passed: seen.status == .confirmed,
                detail: "\(seen.status.rawValue): \(seen.detail)",
            ))
            if seen.status != .unavailable {
                process = LoadTargetProcess(
                    runningAtStart: seen.runningAtStart,
                    startedDuring: seen.startedDuring,
                    watchedSeconds: seen.watchedSeconds,
                )
            }
        }
        if let failure = result.triggerFailure {
            evidence.append(LoadEvidence(kind: "trigger", passed: false, detail: failure))
        }
        return ApelinProtocol.ConfirmLoadedResponse(loaded: result.isLoaded, evidence: evidence, process: process)
    }

    /// The host's closed respring first; icli's FrontBoard relaunch only
    /// when the host has none to give.
    static func respring(host: ApelinService, diagnostics: Diagnostics) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        Task {
            do { try await host.respring() } catch { outcome.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        guard let error = outcome.error else { return }
        if let error = error as? ApelinError, error.code != .unimplemented, error.code != .unavailable {
            throw error
        }
        _ = try diagnostics.respring()
    }

    struct Target {
        var executable: String
        var bundleIdentifier: String?
    }

    /// An executable name, or a bundle id: the running app's executable,
    /// else the installed app's, since a check may wait for the app to be
    /// opened.
    func resolveTarget(_ targetID: String) async throws -> Target {
        guard !targetID.isEmpty, targetID.utf8.count <= Self.maximumTargetIDBytes, !targetID.contains("/"),
              !targetID.contains("\0")
        else {
            throw ApelinError(
                .badRequest,
                "targetID must be an executable name or a bundle ID of 1–\(Self.maximumTargetIDBytes) bytes, with no slash or NUL.",
            )
        }
        if targetID == "SpringBoard" || targetID == "com.apple.springboard" {
            return Target(executable: "SpringBoard", bundleIdentifier: "com.apple.springboard")
        }
        guard targetID.contains(".") else { return Target(executable: targetID, bundleIdentifier: nil) }
        let apps = await (try? blocking { try diagnostics.runningApps() }) ?? []
        if let app = apps.first(where: { $0.bundleIdentifier == targetID }) {
            let executable = app.executable.isEmpty ? app.name : (app.executable as NSString).lastPathComponent
            return Target(executable: executable, bundleIdentifier: targetID)
        }
        let installed = try? await blocking { try diagnostics.installedAppExecutable(bundleIdentifier: targetID) }
        guard let executable = installed else {
            throw ApelinError(
                .notFound,
                "No app with the bundle ID \(targetID) is running or installed. For a process that is not an app, give its executable name.",
            )
        }
        return Target(executable: executable, bundleIdentifier: targetID)
    }
}

private final class OutcomeBox: @unchecked Sendable {
    @objc dynamic var error: Error?
}

/// The load checks this worker runs, by task, so the host's cancel reaches
/// the one it names. One for the worker's life, beside the log pump; a
/// cancel for a task it does not run (a log stream's, one already ended)
/// does nothing here.
public final class LoadCheckRegistry: @unchecked Sendable {
    private let lock = PthreadLock()
    private var running: [TaskID: LoadCheckStop] = [:]

    public init() {}

    func begin(_ taskID: TaskID) -> LoadCheckStop {
        let stop = LoadCheckStop()
        lock.withLock { running[taskID] = stop }
        return stop
    }

    func end(_ taskID: TaskID) {
        lock.withLock { _ = running.removeValue(forKey: taskID) }
    }

    public func cancel(_ taskID: TaskID) {
        lock.withLock { running[taskID] }?.stop()
    }
}
