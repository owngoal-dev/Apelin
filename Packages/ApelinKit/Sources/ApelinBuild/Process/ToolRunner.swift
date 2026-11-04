import Darwin
import Foundation

/// libSystem's posix_spawn_file_actions_addchdir_np: present on every iOS this
/// runs on, marked unavailable in the iOS SDK's header, so it is declared by
/// its symbol the way Apelind/Spawn.swift declares the credential SPI.
@_silgen_name("posix_spawn_file_actions_addchdir_np")
private func spawnAddChdir(
    _ actions: UnsafeMutablePointer<posix_spawn_file_actions_t?>,
    _ path: UnsafePointer<CChar>,
) -> Int32

/// One tool invocation: an executable, its argv, a working directory and an
/// environment. Always an array — nothing apelin-build runs is ever a
/// string handed to a shell.
public struct ToolInvocation: Sendable, Equatable {
    public var executable: String
    /// The arguments after argv[0], which is the executable's own path.
    public var arguments: [String]
    public var workingDirectory: String
    public var environment: [String: String]

    public init(executable: String, arguments: [String], workingDirectory: String, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// For the build log: argv as one line, each element quoted when it
    /// needs it. Display only; never parsed back.
    public var displayLine: String {
        ([executable] + arguments).map { word in
            word.isEmpty || word.contains(where: { " \"'\\$`".contains($0) })
                ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
                : word
        }.joined(separator: " ")
    }
}

public struct ToolResult: Sendable, Equatable {
    public var status: Int32
    /// stdout and stderr, interleaved as written.
    public var output: String
    public var succeeded: Bool {
        status == 0
    }
}

/// Stops the tools of one build: everything spawned through it runs in its
/// own process group, and `cancel()` sends the group SIGTERM, then SIGKILL
/// after a grace period. A tool started after the cancel is not started.
public final class BuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    @objc private dynamic var cancelled = false
    @objc private dynamic var groups: Set<pid_t> = []

    public init() {}

    @objc public dynamic var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    @objc public dynamic func cancel() {
        lock.lock()
        cancelled = true
        let running = groups
        lock.unlock()
        for group in running {
            killpg(group, SIGTERM)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock()
            let still = groups
            lock.unlock()
            for group in still {
                killpg(group, SIGKILL)
            }
        }
    }

    /// Kills the tools at once, for a worker about to exit: the host that
    /// ran this build is gone, and a resumed build starts over in its folder.
    @objc public dynamic func kill() {
        lock.lock()
        cancelled = true
        let running = groups
        lock.unlock()
        for group in running {
            killpg(group, SIGKILL)
        }
    }

    @objc dynamic func register(_ pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        groups.insert(pid)
        return true
    }

    @objc dynamic func unregister(_ pid: pid_t) {
        lock.lock()
        groups.remove(pid)
        lock.unlock()
    }
}

public struct BuildCancelled: Error, CustomStringConvertible, Sendable {
    public var description: String {
        "the build was cancelled"
    }
}

/// posix_spawn with an argv array, stdin from /dev/null, stdout and stderr
/// into one pipe, every other descriptor closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`),
/// a process group of its own. It runs as whoever calls it: apelin-build is
/// already mobile, and nothing here changes identity.
public enum ToolRunner {
    public static func run(
        _ invocation: ToolInvocation,
        cancellation: BuildCancellation,
        onLine: ((String) -> Void)? = nil,
    ) throws -> ToolResult {
        if cancellation.isCancelled {
            throw BuildCancelled()
        }
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { throw POSIXError(.EMFILE) }
        let (readEnd, writeEnd) = (pipe[0], pipe[1])
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        guard spawnAddChdir(&actions, invocation.workingDirectory) == 0 else {
            close(readEnd)
            close(writeEnd)
            throw ToolFailure(description: "cannot set the working directory of \(invocation.executable)")
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK),
        )
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attributes, &empty)

        let argv = [invocation.executable] + invocation.arguments
        let environment = invocation.environment.map { "\($0.key)=\($0.value)" }.sorted()
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointer in
            withCStrings(environment) { environmentPointer in
                posix_spawn(&pid, invocation.executable, &actions, &attributes, argvPointer, environmentPointer)
            }
        }
        close(writeEnd)
        guard status == 0 else {
            close(readEnd)
            throw ToolFailure(
                description: "could not start \(invocation.executable): \(String(cString: strerror(status)))",
            )
        }
        guard cancellation.register(pid) else {
            killpg(pid, SIGKILL)
            close(readEnd)
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
            throw BuildCancelled()
        }
        defer { cancellation.unregister(pid) }

        var collected = Data()
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(readEnd, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            collected.append(buffer, count: count)
            if let onLine {
                pending.append(buffer, count: count)
                while let newline = pending.firstIndex(of: 0x0A) {
                    onLine(String(decoding: pending[pending.startIndex ..< newline], as: UTF8.self))
                    pending.removeSubrange(pending.startIndex ... newline)
                }
            }
        }
        if let onLine, !pending.isEmpty {
            onLine(String(decoding: pending, as: UTF8.self))
        }
        close(readEnd)
        var waitStatus: Int32 = 0
        while waitpid(pid, &waitStatus, 0) < 0, errno == EINTR {}
        if cancellation.isCancelled {
            throw BuildCancelled()
        }
        let exitCode: Int32 = if waitStatus & 0x7F == 0 {
            (waitStatus >> 8) & 0xFF
        } else {
            128 + (waitStatus & 0x7F)
        }
        return ToolResult(status: exitCode, output: String(decoding: collected, as: UTF8.self))
    }

    private static func withCStrings<R>(
        _ strings: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R,
    ) -> R {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

public struct ToolFailure: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(description: String) {
        self.description = description
    }
}
