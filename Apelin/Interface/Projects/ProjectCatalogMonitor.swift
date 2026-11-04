import ApelinCore
import Darwin
import Foundation

/// Watches both in-place writes and atomic manifest replacements, including
/// edits made by the agent or another app. Nothing is written by the observer.
@MainActor
final class ProjectCatalogMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    deinit { sources.forEach { $0.cancel() }; pending?.cancel() }

    @objc dynamic func start() {
        updateWatches()
    }

    @objc private dynamic func updateWatches() {
        sources.forEach { $0.cancel() }
        sources = []
        var paths = CanonicalPath.resolve(DataFolder.app.root.path).map { [$0] } ?? []
        if let projects = CanonicalPath.resolve(DataFolder.app.projects.path) {
            paths.append(projects)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
                guard ProjectName.validate(name) == nil,
                      let folder = CanonicalPath.resolve(projects + "/" + name), folder == projects + "/" + name
                else { continue }
                paths.append(folder)
                if let manifest = CanonicalPath.resolve(folder + "/apelin-project.json"),
                   manifest == folder + "/apelin-project.json"
                {
                    paths.append(manifest)
                }
            }
        }
        for path in paths {
            let descriptor = open(path, O_EVTONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main,
            )
            source.setEventHandler { [weak self] in self?.changed() }
            source.setCancelHandler { close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }

    @objc private dynamic func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            updateWatches()
            NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
}
