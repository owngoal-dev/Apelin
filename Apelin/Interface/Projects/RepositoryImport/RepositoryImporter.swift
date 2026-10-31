import ApelinCore
import ApelinProtocol
import UIKit

/// Why an import that had made its project did not finish, once that
/// project is gone again — or, in `leftProject`, could not be removed.
struct RepositoryImportFailure: Error {
    /// The host's words, or what the task's state means.
    var message: String
    /// `ApelinError.Reason`'s raw value, when the host named one.
    var reason: String?
    /// The folder of a project that should have gone and did not.
    var leftProject: String?
}

/// The host's half of Open in Apelin for a repository, the same requests
/// New Project and the agent's git_clone make: an empty workspace
/// (`projectCreate`), then the repository imported into it
/// (`gitCloneInto`, with the host's own checks of the address and branch,
/// and the credential saved for its host), read to its end. Nothing else is
/// asked: nothing builds, runs or goes to the agent.
@MainActor
enum RepositoryImporter {
    static let workspaceTemplate = "wiki.qaq.apelin.workspace/empty"

    /// The project imported. A failure or a cancel after the workspace was
    /// made takes that workspace away (`projectDelete`, only that project)
    /// before it throws; a failure before throws the host's error as it is.
    static func run(
        _ request: RepositoryImportPlan.Request,
        name: String,
        update: @escaping @MainActor (ProgressCard.Status) -> Void,
    ) async throws -> ProjectSummary {
        let service = ApelinService.app
        // Each request is sent whole, never cut off by a cancel, so what it
        // made is known and can be taken away.
        let created = try await Task {
            try await service.projectCreate(ProjectCreateRequest(
                templateID: workspaceTemplate,
                name: name,
                automaticallyName: false,
            ))
        }.value
        var clone: TaskHandle?
        var projectID = created.projectID
        do {
            try Task.checkCancellation()
            let handle = try await Task {
                try await service.gitCloneInto(GitCloneIntoRequest(
                    projectID: created.projectID,
                    url: request.address,
                    branch: request.branch,
                ))
            }.value
            clone = handle
            // the repository's own apelin-project.json may bring its own ID
            projectID = try await follow(handle, update: update) ?? created.projectID
        } catch {
            // a task of its own: the cancel that ended the import must not
            // end the clean-up too
            let removed = await Task { [clone] in await discard(created, clone: clone) }.value
            if error is CancellationError, removed {
                throw error
            }
            var failure = error as? RepositoryImportFailure ?? RepositoryImportFailure(
                message: error is CancellationError ? String(localized: "The task was cancelled.") : error.readableMessage,
                reason: (error as? ApelinError)?.reason?.rawValue,
            )
            failure.leftProject = removed ? nil : created.name
            throw failure
        }
        return ProjectSummary(
            name: created.name,
            kind: .workspace,
            displayName: created.name,
            projectID: projectID,
        )
    }

    /// The clone's events on the card, to its final `state`: the project's
    /// ID the clone reported, which is the repository's own when its
    /// `apelin-project.json` came with it.
    private static func follow(
        _ handle: TaskHandle,
        update: @escaping @MainActor (ProgressCard.Status) -> Void,
    ) async throws -> String? {
        var progress = EnvironmentTaskProgress(work: .repositoryImport)
        var reason: String?
        var projectID: String?
        for try await event in ApelinService.app.events(of: handle) {
            progress.apply(event)
            if event.kind == TaskEvent.stateKind {
                reason = event.payload?["reason"]?.stringValue
                projectID = event.payload?["result"]?["projectID"]?.stringValue ?? projectID
            } else if event.kind == "result" {
                projectID = event.payload?["projectID"]?.stringValue ?? projectID
            }
            update(ProgressCard.Status(
                subtitle: progress.stage.map(EnvironmentTaskProgress.activeTitle(of:)) ?? "",
                fraction: progress.fraction,
            ))
        }
        try Task.checkCancellation()
        guard progress.state == .succeeded else {
            throw RepositoryImportFailure(
                message: EnvironmentTaskProgress.readableDetail(progress.outcomeMessage),
                reason: reason,
            )
        }
        return projectID
    }

    /// How long a stopped clone may take to end before the workspace is
    /// left where it is and the user told: a host that stopped answering
    /// mid-fetch can hold a clone, and the sheet must not wait on it.
    static let discardWait: Duration = .seconds(15)

    /// Takes the workspace away again, its clone stopped and read to its
    /// end first, so the folder goes only once nothing writes in it.
    /// Answers whether it went; a clone that does not end within
    /// `discardWait` leaves it.
    private static func discard(_ created: ProjectCreateResponse, clone: TaskHandle?) async -> Bool {
        let service = ApelinService.app
        if let clone {
            try? await service.environmentCancel(taskID: clone.taskID)
            let ended = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        for try await _ in service.events(of: clone) {}
                    } catch {
                        // the host may have gone with the task; the delete says so
                    }
                    return true
                }
                group.addTask {
                    try? await Task.sleep(for: discardWait)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            guard ended else { return false }
        }
        do {
            _ = try await service.projectDelete(ProjectDeleteRequest(
                projectID: created.projectID,
                projectName: created.name,
            ))
            return true
        } catch {
            return false
        }
    }
}
