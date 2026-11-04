import Foundation

/// `~/Documents/wiki.qaq.apelin`, the app's data folder, and everything
/// Apelin keeps inside it. The package's postinst makes the folder for
/// mobile; whatever runs as mobile makes the levels below it.
///
/// `home` is mobile's home as the caller knows it: `RoothideRoot.mobileHome`
/// in the app and the session host, `HOME` in a worker (the session host
/// sets it at spawn). On roothide that is `<jbroot>/var/mobile`, on rootless
/// `/var/mobile`.
public struct DataFolder: Sendable, Equatable {
    public static let bundleIdentifier = "wiki.qaq.apelin"

    public let root: URL

    public init(home: String) {
        root = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
    }

    public init(root: URL) {
        self.root = root
    }

    /// `Projects/<name>/`, the only place a project lives.
    public var projects: URL {
        folder("Projects")
    }

    /// `SDKs/<CanonicalName>-<sha8>/`.
    public var sdks: URL {
        folder("SDKs")
    }

    /// Downloads, staging and registration metadata for environment tasks.
    public var environment: URL {
        folder("Environment")
    }

    /// `Environment/Toolchains/`, the toolchain registry and job records.
    public var toolchains: URL {
        environment.appendingPathComponent("Toolchains", isDirectory: true)
    }

    /// `Environment/Toolchains/registry.json`, the registered toolchains.
    public var toolchainRegistry: URL {
        toolchains.appendingPathComponent("registry.json")
    }

    /// `SDKs/.registry/`, one record per registered SDK.
    public var sdkRegistry: URL {
        sdks.appendingPathComponent(".registry", isDirectory: true)
    }

    /// Agent sessions.
    public var sessions: URL {
        folder("sessions")
    }

    /// Copies taken before a protected edit replaces a file.
    public var backups: URL {
        folder("backups")
    }

    /// User skills the agent reads.
    public var skills: URL {
        folder("skills")
    }

    /// `Exports/<kind>-<id>/`: transfer files written for the app to share.
    public var exports: URL {
        folder("Exports")
    }

    /// The console's folders: scripts dropped in `inbox`, claimed into
    /// `running`, moved to `done`; results in `out/<runID>.jsonl`.
    public var console: URL {
        folder("console")
    }

    public var consoleInbox: URL {
        console.appendingPathComponent("inbox", isDirectory: true)
    }

    public var consoleRunning: URL {
        console.appendingPathComponent("running", isDirectory: true)
    }

    public var consoleDone: URL {
        console.appendingPathComponent("done", isDirectory: true)
    }

    public var consoleOut: URL {
        console.appendingPathComponent("out", isDirectory: true)
    }

    /// The directory of the project named `name`, or nil when the name breaks
    /// `ProjectName`'s rules.
    public func project(named name: String) -> URL? {
        guard ProjectName.validate(name) == nil else { return nil }
        return projects.appendingPathComponent(name, isDirectory: true)
    }

    /// Removes one real project directory; links inside it are removed, never followed.
    public func removeProject(named name: String) throws {
        guard let project = project(named: name),
              let rootPath = CanonicalPath.resolve(root.path),
              let projectsPath = CanonicalPath.resolve(projects.path),
              projectsPath == rootPath + "/Projects"
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let projectPath = CanonicalPath.resolve(project.path)
        var metadata = stat()
        if lstat(project.path, &metadata) != 0 {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              let projectPath,
              projectPath == projectsPath + "/" + name
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: project)
    }

    /// Makes each missing level from `root` down to `url` as the current user,
    /// one at a time, refusing to follow a symlink. `root` itself must exist.
    public func makeLevels(to url: URL) throws {
        let rootPath = root.path
        let target = url.path
        guard !CanonicalPath.components(target).contains(".."),
              CanonicalPath.isCanonical(target, inside: rootPath)
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var current = rootPath
        for component in CanonicalPath.components(String(target.dropFirst(rootPath.count))) {
            current += "/" + component
            var metadata = stat()
            if lstat(current, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { throw CocoaError(.fileWriteFileExists) }
                continue
            }
            guard mkdir(current, 0o755) == 0 || errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func folder(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}
