import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Exported by libSystem on every iOS this app supports (libSystem.B.tbd);
/// the iOS headers mark it unavailable.
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func spawnAddChdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>,
) -> Int32

/// `agentRunCode`: the agent's `shell_run`, run by the session host as
/// mobile (uid, gid and groups 501 set before exec) — or as root, only when
/// `AgentApprovals.authorize` answered `.root` —, in the session's project,
/// with stdin from /dev/null, every other descriptor closed, its own
/// process group (killed whole when time runs out) and both output streams
/// capped and read for at most `drainSeconds` after it exits. Never outside
/// `Projects/<name>` or the chat's temporary folder.
enum AgentRunCode {
    /// Who a call runs as, as the host decided it.
    enum Identity: Equatable {
        /// The request's own command, or under Confirm the preset the host
        /// read in its place.
        case mobile(preset: Preset?)
        /// The request's own command, never a preset.
        case root
    }

    private static let outputCap = 256 * 1024
    /// How long the pipes are read after the process has exited or been
    /// killed: what a descendant still holding them writes later is cut.
    private static let drainSeconds = 2
    private static let maximumSourceBytes = 256 * 1024
    private static let maximumArguments = 1024
    private static let timeoutRange = 1 ... 1800
    /// In the order the refusal lists them.
    private static let interpreters: [(name: String, flag: String)] = [
        ("sh", "-c"), ("bash", "-c"), ("zsh", "-c"), ("python3", "-c"), ("perl", "-e"),
    ]
    /// The process groups of the shell_run calls running now, by session.
    private static let running = RunningGroups()

    /// Kills the shell_run calls `session` is running: stopping or closing
    /// the conversation ends them rather than leaving them to their timeout.
    static func stop(session: String) {
        running.stop(session: session)
    }

    /// How many times `session` has been stopped. A call takes it when it
    /// arrives and is killed as soon as it spawns if a stop came since.
    static func stopCount(session: String) -> Int {
        running.stopCount(session: session)
    }

    /// Kills every shell_run call running, for the host's shutdown: the
    /// timeout that bounds each one ends with the host.
    static func stopAll() {
        running.stopAll()
    }

    /// What a bootstrap path is spelled after: nothing when the root is `/`.
    private static func prefix(for installRoot: String) -> String {
        installRoot == "/" ? "" : installRoot
    }

    /// Where `sh` would find the command `name`: the first directory of
    /// `searchPath` holding an executable file of that name, canonical. Nil
    /// when none does, and for a path, which is not looked up.
    static func findExecutable(_ name: String, in searchPath: [String]) -> String? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return searchPath.lazy.compactMap { executableFile($0 + "/" + name) }.first
    }

    /// `path` canonicalised, when that is a regular file with an execute bit.
    private static func executableFile(_ path: String) -> String? {
        guard let real = CanonicalPath.resolve(path) else { return nil }
        var metadata = stat()
        guard stat(real, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o111 != 0 else {
            return nil
        }
        return real
    }

    /// Where a run looks a bare command name up. An ordinary one looks
    /// where its shell would, on the `PATH` it gets, the prepared
    /// toolchain's tools first, so `argv: ["clang", …]` runs what
    /// `bash -c "clang …"` does. A preset and a run as root look in the
    /// bootstrap's and the system's directories alone: a preset's checks
    /// vetted the bootstrap's git, and root runs a dependency install, never
    /// a compiler, so it takes no command from the toolchain's place, which
    /// a record in mobile's folder names.
    static func searchPath(for identity: Identity, environment: [String], installRoot: String) -> [String] {
        guard identity == .mobile(preset: nil), let path = environment.first(where: { $0.hasPrefix("PATH=") }) else {
            return DevelopmentEnvironment.searchPath(installRoot: installRoot)
        }
        return path.dropFirst("PATH=".count).split(separator: ":").map(String.init)
    }

    /// What a run execs and the argv it hands over. A word with a slash is
    /// a path, read from `directory` unless absolute; any other is looked
    /// up in `searchPath(for:)`. What runs is the canonical file checked
    /// here, but an argv keeps the request's own words, as a shell's does:
    /// `clang++` and `swiftc` are links to tools that read the name they
    /// were called by, and called `clang` or `swift-frontend` they would not
    /// compile C++ or Swift.
    static func invocation(
        _ spec: RunCodeSpec,
        as identity: Identity,
        environment: [String],
        installRoot: String,
        directory: String,
    ) throws -> (executable: String, argv: [String]) {
        let searched = searchPath(for: identity, environment: environment, installRoot: installRoot)
        let lookedIn = switch identity {
        case .mobile(preset: nil):
            "on shell_run's PATH (the prepared toolchain's tools, when one is installed, then the bootstrap's bin directories)"
        case .mobile:
            "in the bootstrap's bin directories, where a preset looks"
        case .root:
            "in the bootstrap's bin directories, where a run as root looks"
        }
        switch spec {
        case let .argv(argv):
            guard let name = argv.first, !name.isEmpty else {
                throw ApelinError(.badRequest, "shell_run needs an executable")
            }
            guard argv.allSatisfy({ !CanonicalPath.containsNUL($0) }), argv.count <= maximumArguments else {
                throw ApelinError(
                    .badRequest,
                    "shell_run takes at most \(maximumArguments) arguments, and none may contain a NUL byte",
                )
            }
            if name.contains("/") {
                guard let path = executableFile(name.hasPrefix("/") ? name : directory + "/" + name) else {
                    throw ApelinError(.notFound, "\(name) is not an executable file")
                }
                return (path, argv)
            }
            guard let path = findExecutable(name, in: searched) else {
                throw ApelinError(
                    .notFound,
                    "\(name) is not \(lookedIn): give the executable's path, or run a shell builtin with bash -c",
                )
            }
            return (path, argv)
        case let .script(interpreter, source):
            guard let flag = interpreters.first(where: { $0.name == interpreter })?.flag else {
                let names = interpreters.map(\.name).joined(separator: ", ")
                throw ApelinError(.badRequest, "\(interpreter) is not one of \(names)")
            }
            guard !CanonicalPath.containsNUL(source), source.utf8.count <= maximumSourceBytes else {
                throw ApelinError(
                    .badRequest,
                    "the script must not contain a NUL byte or be larger than \(maximumSourceBytes / 1024) KiB",
                )
            }
            guard let path = findExecutable(interpreter, in: searched) else {
                throw ApelinError(.notFound, "\(interpreter) is not \(lookedIn)")
            }
            return (path, [path, flag, source])
        }
    }

    /// The working directory: a plain relative path that still resolves
    /// inside the project, by component.
    static func workingDirectory(_ relative: String, project: String) throws -> String {
        let relative = relative.isEmpty ? "." : relative
        guard relative == "." || CanonicalPath.isPlainRelative(relative),
              let path = CanonicalPath.resolve(project + "/" + relative),
              CanonicalPath.isCanonical(path, inside: project)
        else {
            throw ApelinError(.denied, "the working directory must stay inside the project")
        }
        var metadata = stat()
        guard stat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ApelinError(.notFound, "\(relative) is not a directory in the project")
        }
        return path
    }

    /// Runs the request as `identity` (`AgentApprovals.authorize`): when
    /// Confirm let it through as a preset, the preset as the host reads it.
    static func run(
        _ request: AgentRunCodeRequest,
        as identity: Identity,
        project: ResolvedProject,
        installRoot: String,
        home: String,
        stopsSeen: Int,
    ) async throws -> AgentRunCodeResponse {
        guard timeoutRange.contains(request.timeoutSeconds) else {
            throw ApelinError(
                .badRequest,
                "timeoutSeconds must be \(timeoutRange.lowerBound)–\(timeoutRange.upperBound)",
            )
        }
        let preset: Preset? = if case let .mobile(preset) = identity {
            preset
        } else {
            nil
        }
        let asRoot = identity == .root
        let directory = try workingDirectory(request.workingDirectory, project: project.path)
        let environment = Self.environment(
            preset: preset,
            project: project,
            installRoot: installRoot,
            home: home,
            asRoot: asRoot,
        )
        let command = try invocation(
            preset.map { .argv($0.argv) } ?? request.spec,
            as: identity,
            environment: environment,
            installRoot: installRoot,
            directory: directory,
        )
        let timeout = request.timeoutSeconds
        let session = request.sessionID
        return try await offThePool {
            try execute(
                command.executable,
                argv: command.argv,
                environment: environment,
                directory: directory,
                timeoutSeconds: timeout,
                asMobile: !asRoot,
                session: session,
                stopsSeen: stopsSeen,
            )
        }
    }

    /// Root's own home, so a run as root leaves nothing of root's in mobile's.
    static var rootHome: String {
        getpwuid(0).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? "/var/root"
    }

    /// What a run sees. A preset keeps its own short list and the bare
    /// search path: it is a read-only command the host chose the words of,
    /// and needs no compiler. Any other run gets the development environment
    /// (`DevelopmentEnvironment`): the project's toolchain — else the
    /// default — first on `PATH`, and `SDKROOT` with
    /// `IPHONEOS_DEPLOYMENT_TARGET`, the same the terminal gets and the
    /// agent's system prompt describes. A temporary chat has no project to
    /// bind one, so it gets the defaults. A run as root has root's own
    /// `HOME`; `home` still names mobile's, where the registries are read.
    static func environment(
        preset: Preset?,
        project: ResolvedProject,
        installRoot: String,
        home: String,
        asRoot: Bool = false,
    ) -> [String] {
        let base = DevelopmentEnvironment.searchPath(installRoot: installRoot)
        let common = [
            "HOME=\(asRoot ? rootHome : home)",
            "LANG=en_US.UTF-8",
            "TERM=dumb",
            "TMPDIR=\(prefix(for: installRoot))/var/tmp",
            "APELIN_PROJECT_ROOT=\(project.path)",
        ]
        if let preset {
            return preset.environment + ["PATH=\(base.joined(separator: ":"))"] + common
        }
        let development = DevelopmentEnvironment.prepared(
            home: home,
            projectDirectory: project.isTemporary ? nil : project.path,
        )
        return common + development.entries(basePath: base)
    }

    /// Runs `body` — a spawn waited on for up to its timeout — on a Dispatch
    /// thread, so it never holds a thread of the cooperative pool.
    private static func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    // MARK: Spawning

    /// Runs a tool of the host's own choosing (`argv[0]` a canonical path)
    /// from `directory` (`/` unless asked) to read what it prints, the way
    /// shell_run runs: as mobile when the host is root, as the user running
    /// it on a test host, which is no more than that user may do anyway.
    /// With a `session`, it is one of that session's calls, as `run` makes
    /// it: a stop since it took `stopsSeen` ends it. Nil when it could not start.
    static func capture(
        _ argv: [String],
        environment: [String],
        directory: String = "/",
        timeoutSeconds: Int,
        session: String? = nil,
        stopsSeen: Int = 0,
    ) async -> AgentRunCodeResponse? {
        try? await offThePool {
            try execute(
                argv[0],
                argv: argv,
                environment: environment,
                directory: directory,
                timeoutSeconds: timeoutSeconds,
                asMobile: geteuid() == 0,
                session: session,
                stopsSeen: stopsSeen,
            )
        }
    }

    /// Execs `executable` with `argv`, which a run takes from the request
    /// (`invocation`) and `capture` starts with the path itself.
    private static func execute(
        _ executable: String,
        argv: [String],
        environment: [String],
        directory: String,
        timeoutSeconds: Int,
        asMobile: Bool,
        session: String?,
        stopsSeen: Int,
    ) throws -> AgentRunCodeResponse {
        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw ApelinError(.internal, "pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw ApelinError(.internal, "pipe: \(String(cString: strerror(errno)))")
        }
        for descriptor in out + err {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        guard spawnAddChdir(&actions, directory) == 0 else {
            [out[0], out[1], err[0], err[1]].forEach { close($0) }
            throw ApelinError(.internal, "could not set shell_run's working directory")
        }

        var everySignal = sigset_t()
        var noSignal = sigset_t()
        sigfillset(&everySignal)
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP,
        )
        posix_spawnattr_setflags(&attributes, flags)

        var groups = [gid_t(WorkerRole.mobileGID)]
        guard !asMobile
            || (spawnSetGroups(&attributes, 1, &groups, uid_t(WorkerRole.mobileUID)) == 0
                && spawnSetGID(&attributes, gid_t(WorkerRole.mobileGID)) == 0
                && spawnSetUID(&attributes, uid_t(WorkerRole.mobileUID)) == 0)
        else {
            [out[0], out[1], err[0], err[1]].forEach { close($0) }
            throw ApelinError(.internal, "could not set mobile's identity for shell_run")
        }

        let started = Date()
        var pid: pid_t = 0
        let status = cStrings(argv) { argvPointer in
            cStrings(environment) { environmentPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, environmentPointer)
            }
        }
        close(out[1])
        close(err[1])
        guard status == 0 else {
            close(out[0]); close(err[0])
            throw ApelinError(.internal, "posix_spawn \(executable): \(String(cString: strerror(status)))")
        }

        let stdout = CappedReader(descriptor: out[0], cap: outputCap)
        let stderr = CappedReader(descriptor: err[0], cap: outputCap)
        let timedOut = SharedFlag()
        let killer = DispatchWorkItem {
            timedOut.set()
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: killer)
        if let session {
            Self.running.insert(pid, session: session, stopsSeen: stopsSeen)
        }

        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) < 0, errno == EINTR {}
        Self.running.remove(pid)
        killer.cancel()
        // Anything the process group left behind is not ours to keep.
        kill(-pid, SIGKILL)
        // A descendant that left the group (setsid) survives that kill and
        // may still hold the pipes' write ends, so EOF may never come. The
        // host cannot reliably find such a process — it is mobile's, in a
        // session of its own — and leaves it running; what bounds the call
        // is reading for no longer than the drain, then closing the pipes.
        let drained = DispatchTime.now() + .seconds(drainSeconds)
        let output = stdout.finish(by: drained)
        let errors = stderr.finish(by: drained)

        let exitCode: Int32 = if timedOut.isSet {
            -1
        } else if waitStatus & 0x7F == 0 {
            (waitStatus >> 8) & 0xFF
        } else {
            128 + (waitStatus & 0x7F)
        }
        return AgentRunCodeResponse(
            exitCode: exitCode,
            stdout: output.text,
            stderr: errors.text,
            truncated: output.truncated || errors.truncated || timedOut.isSet,
            timedOut: timedOut.isSet,
            durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000),
        )
    }

    private static func cStrings<T>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T,
    ) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

/// Drains a pipe on its own thread, keeping the first `cap` bytes and
/// reading the rest away so the writer never blocks on a full pipe. The
/// thread polls, so a stop asked for by `finish(by:)` ends it within a
/// tenth of a second even while nothing arrives; it closes the descriptor
/// itself on the way out.
private final class CappedReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let stopped = SharedFlag()
    private var data = Data()
    @objc dynamic private var overflow = false
    @objc dynamic private var cut = false

    init(descriptor: Int32, cap: Int) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                if stopped.isSet {
                    cut = true
                    break
                }
                var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let polled = poll(&ready, 1, 100)
                if polled < 0, errno == EINTR {
                    continue
                }
                if polled < 0 {
                    break
                }
                if polled == 0 {
                    continue
                }
                let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR {
                    continue
                }
                if count <= 0 {
                    break
                }
                let room = cap - data.count
                if room > 0 {
                    data.append(contentsOf: buffer[0 ..< min(room, count)])
                }
                if count > max(room, 0) {
                    overflow = true
                }
            }
            close(descriptor)
            done.signal()
        }
    }

    /// What was read: to EOF, or up to `deadline` and cut there.
    func finish(by deadline: DispatchTime) -> (text: String, truncated: Bool) {
        if done.wait(timeout: deadline) == .timedOut {
            stopped.set()
            done.wait()
        }
        return (String(decoding: data, as: UTF8.self), overflow || cut)
    }
}

/// Run_code process groups and the session each runs for: the spawning
/// thread adds its own and removes it once reaped; a stop kills them.
private final class RunningGroups: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc dynamic private var sessions: [pid_t: String] = [:]
    @objc dynamic private var stops: [String: Int] = [:]

    @objc dynamic func stopCount(session: String) -> Int {
        lock.withLock { stops[session, default: 0] }
    }

    /// Adds `group`, killing it at once when `session` was stopped after
    /// its call took `stopsSeen`: a stop that came while the call was
    /// being checked or spawned still ends it.
    @objc dynamic func insert(_ group: pid_t, session: String, stopsSeen: Int) {
        lock.withLock {
            sessions[group] = session
            if stops[session, default: 0] != stopsSeen {
                kill(-group, SIGKILL)
                kill(group, SIGKILL)
            }
        }
    }

    @objc dynamic func remove(_ group: pid_t) {
        lock.withLock { sessions[group] = nil }
    }

    @objc dynamic func stop(session: String) {
        lock.withLock {
            stops[session, default: 0] += 1
            for (group, owner) in sessions where owner == session {
                kill(-group, SIGKILL)
                kill(group, SIGKILL)
            }
        }
    }

    @objc dynamic func stopAll() {
        lock.withLock {
            for group in sessions.keys {
                kill(-group, SIGKILL)
                kill(group, SIGKILL)
            }
        }
    }
}

private final class SharedFlag: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc dynamic private var value = false
    @objc dynamic func set() {
        lock.withLock { value = true }
    }

    @objc dynamic var isSet: Bool {
        lock.withLock { value }
    }
}
