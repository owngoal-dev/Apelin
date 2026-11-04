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
    func startConfirmLoaded(_ request: ApelinProtocol.ConfirmLoadedRequest, taskID: TaskID) async throws {
        let check = try await prepareConfirmLoaded(request)
        let emit = emit
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let response = runConfirmLoaded(check) { stage in
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
            var final: [String: JSONValue] = ["state": .string(TaskState.succeeded.rawValue)]
            do {
                final[ApelinProtocol.ConfirmLoadedResponse.stateMember] = try JSONValue(encoding: response)
            } catch {
                final = [
                    "state": .string(TaskState.failed.rawValue),
                    "message": .string("the answer does not encode: \(error)"),
                ]
            }
            emit(taskID, TaskEvent.stateKind, .object(final))
        }
    }

    /// The whole check in one call, for tests: checked, run, answered.
    func confirmLoaded(
        _ request: ApelinProtocol.ConfirmLoadedRequest,
    ) async throws -> ApelinProtocol.ConfirmLoadedResponse {
        let check = try await prepareConfirmLoaded(request)
        return await blocking { runConfirmLoaded(check, stage: nil) }
    }

    static let maximumBuildIDBytes = 200
    static let maximumTargetIDBytes = 256
    /// Seconds a check may listen for the marker.
    static let logWindowRange: ClosedRange<Double> = 1 ... 60

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
        // A respring has to bring SpringBoard back inside the window.
        let window = request.logWindowSeconds ?? (request.trigger == .respring ? 30 : 15)
        guard window.isFinite, Self.logWindowRange.contains(window) else {
            let range = Self.logWindowRange
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

    /// Blocks for the window. The target's image list is never read.
    func runConfirmLoaded(
        _ check: LoadCheck,
        stage: (@Sendable (ConfirmLoaded.Stage) -> Void)?,
    ) -> ApelinProtocol.ConfirmLoadedResponse {
        var trigger: (@Sendable () throws -> Void)?
        if check.trigger == .respring {
            let host = host
            let diagnostics = diagnostics
            trigger = { try DiagnosticsService.respring(host: host, diagnostics: diagnostics) }
        }
        let confirm = ConfirmLoaded(logs: diagnostics)
        let result = confirm.run(check.confirmation, trigger: trigger, stage: stage)
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
        if let failure = result.triggerFailure {
            evidence.append(LoadEvidence(kind: "trigger", passed: false, detail: failure))
        }
        return ApelinProtocol.ConfirmLoadedResponse(loaded: result.isLoaded, evidence: evidence)
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

    /// An executable name, or a bundle id resolved through the running apps.
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
        guard let app = apps.first(where: { $0.bundleIdentifier == targetID }) else {
            throw ApelinError(.notFound, "\(targetID) is not running; open it and confirm again")
        }
        let executable = app.executable.isEmpty ? app.name : (app.executable as NSString).lastPathComponent
        return Target(executable: executable, bundleIdentifier: targetID)
    }
}

private final class OutcomeBox: @unchecked Sendable {
    @objc dynamic var error: Error?
}
