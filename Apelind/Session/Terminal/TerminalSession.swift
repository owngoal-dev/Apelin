import Darwin
import Dispatch
import Foundation

// After iGhostVT's PTYSession (owngoal-dev/iGhostVT, iGhostVTIO/Session):
// `forkpty`, everything the child touches allocated before the fork, the
// child making bare syscalls only, the privilege drop one fatal step reported
// through a close-on-exec pipe, every descriptor above 2 closed before exec.

/// `forkpty` does the child's terminal setup — `setsid`, the controlling
/// terminal, the slave on 0–2 — which `posix_spawn` cannot express.
@_silgen_name("forkpty")
private func terminalForkPTY(
    _ master: UnsafeMutablePointer<Int32>,
    _ name: UnsafeMutablePointer<CChar>?,
    _ termios: UnsafeMutableRawPointer?,
    _ winsize: UnsafeMutablePointer<winsize>?,
) -> pid_t

/// One pseudo-terminal and the shell on it, run as mobile.
///
/// The session host is root; the shell never is. Before `execve` the child
/// hands the terminal to mobile, sets groups, gid and uid (and refuses to go
/// on if the uid did not change), enters the working directory as mobile,
/// and closes every descriptor the host had open. After `execve` the host
/// asks the kernel for the shell's credentials and kills it if any of them
/// is not mobile's.
final class TerminalSession: @unchecked Sendable {
    struct Launch {
        var shell: String
        var arguments: [String]
        var environment: [String: String]
        var identity: SpawnIdentity?
        var workingDirectory: String
        var fallbackDirectory: String
        var columns: UInt16
        var rows: UInt16
    }

    enum Failure: Error, CustomStringConvertible {
        case system(String, Int32)
        case child(step: Int32, code: Int32)

        var description: String {
            switch self {
            case let .system(call, code): return "\(call): \(String(cString: strerror(code)))"
            case let .child(step, code):
                let what = step == TerminalSession.stepExec
                    ? "starting the shell"
                    : step == TerminalSession.stepTTY ? "handing the terminal to mobile" : "dropping to mobile"
                return "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    static let stepTTY: Int32 = 1
    static let stepDrop: Int32 = 2
    static let stepExec: Int32 = 3
    /// Output is delivered in pieces of at most this, joined from reads already waiting.
    static let deliveryBytes = 16 * 1024

    let pid: pid_t
    let master: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var peers: [Int32: DispatchSourceRead] = [:]
    private var onOutput: ((Data) -> Void)?
    @objc dynamic private var onExit: ((Int32) -> Void)?
    @objc dynamic private var alive = true

    private init(pid: pid_t, master: Int32, queue: DispatchQueue) {
        self.pid = pid
        self.master = master
        self.queue = queue
    }

    static func spawn(_ launch: Launch, queue: DispatchQueue) throws -> TerminalSession {
        let command = [launch.shell] + launch.arguments
        let environment = launch.environment.map { "\($0.key)=\($0.value)" }.sorted()
        let argv = cStrings(command)
        let envp = cStrings(environment)
        let executable = strdup(launch.shell)
        let directory = strdup(launch.workingDirectory)
        let fallback = strdup(launch.fallbackDirectory)
        defer {
            freeCStrings(argv, count: command.count)
            freeCStrings(envp, count: environment.count)
            free(executable)
            free(directory)
            free(fallback)
        }
        var size = winsize(ws_row: launch.rows, ws_col: launch.columns, ws_xpixel: 0, ws_ypixel: 0)
        var groups: [gid_t] = launch.identity.map { [$0.gid] } ?? []
        let identity = launch.identity

        var reportPipe: [Int32] = [-1, -1]
        guard pipe(&reportPipe) == 0 else { throw Failure.system("pipe", errno) }
        let reportRead = reportPipe[0]
        let reportWrite = reportPipe[1]
        _ = fcntl(reportWrite, F_SETFD, FD_CLOEXEC)
        let report = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { report.deallocate() }

        var master: Int32 = -1
        let pid = terminalForkPTY(&master, nil, nil, &size)
        if pid == 0 {
            // The child: bare syscalls on memory allocated before the fork.
            close(reportRead)
            let table = getdtablesize()
            var descriptor: Int32 = 3
            while descriptor < table {
                if descriptor != reportWrite {
                    close(descriptor)
                }
                descriptor += 1
            }
            func fail(_ step: Int32) -> Never {
                report[0] = step
                report[1] = errno
                _ = Darwin.write(reportWrite, report, MemoryLayout<Int32>.size * 2)
                _exit(step == stepExec ? 127 : 126)
            }
            if let identity {
                if fchown(STDIN_FILENO, identity.uid, identity.gid) != 0 {
                    fail(stepTTY)
                }
                _ = fchmod(STDIN_FILENO, 0o620)
                if setgroups(1, &groups) != 0 {
                    fail(stepDrop)
                }
                if setgid(identity.gid) != 0 {
                    fail(stepDrop)
                }
                if setuid(identity.uid) != 0 {
                    fail(stepDrop)
                }
                if getuid() != identity.uid || geteuid() != identity.uid
                    || getgid() != identity.gid || getegid() != identity.gid
                {
                    fail(stepDrop)
                }
                // Root cannot be regained after a real setuid; prove it.
                if setuid(0) == 0 {
                    fail(stepDrop)
                }
            }
            if chdir(directory) != 0 {
                _ = chdir(fallback)
            }
            signal(SIGPIPE, SIG_DFL)
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            sigprocmask(SIG_SETMASK, &unblocked, nil)
            execve(executable, argv, envp)
            fail(stepExec)
        }
        close(reportWrite)
        guard pid > 0, master >= 0 else {
            close(reportRead)
            throw Failure.system("forkpty", errno)
        }
        // Blocks until the child execs (EOF) or reports why it could not.
        var total = 0
        let wanted = MemoryLayout<Int32>.size * 2
        while total < wanted {
            let count = read(reportRead, UnsafeMutableRawPointer(report).advanced(by: total), wanted - total)
            if count > 0 {
                total += count; continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            break
        }
        close(reportRead)
        if total == wanted {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            close(master)
            throw Failure.child(step: report[0], code: report[1])
        }
        if let identity {
            do {
                try verifyDropped(pid, to: identity)
            } catch {
                var status: Int32 = 0
                waitpid(pid, &status, 0)
                close(master)
                throw error
            }
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL, 0) | O_NONBLOCK)
        return TerminalSession(pid: pid, master: master, queue: queue)
    }

    /// Starts reading. `onOutput` and `onExit` run on the session's queue;
    /// `onExit` once, with the wait status.
    func start(onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) {
        queue.async { [self] in
            self.onOutput = onOutput
            self.onExit = onExit
            let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            readSource = source
            source.activate()
            let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            exit.setEventHandler { [weak self] in self?.pollReap(attempt: 0) }
            exitSource = exit
            exit.activate()
            pollReap(attempt: Self.reapAttempts)
        }
    }

    /// The user's typing.
    func write(_ data: Data) {
        queue.async { [self] in writeAll(data) }
    }

    @objc dynamic func resize(columns: UInt16, rows: UInt16) {
        queue.async { [self] in
            guard alive else { return }
            var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(master, TIOCSWINSZ, &size)
        }
    }

    /// One end of a new socket for the app: what it writes is typed into
    /// the terminal, and the shell's output is copied to it from now on.
    func attachPeer() throws -> Int32 {
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.system("socketpair", errno) }
        for descriptor in pair {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        var on: Int32 = 1
        setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(pair[0], F_SETFL, fcntl(pair[0], F_GETFL, 0) | O_NONBLOCK)
        let local = pair[0]
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: local, queue: queue)
            source.setEventHandler { [weak self] in self?.readPeer(local) }
            source.setCancelHandler { close(local) }
            peers[local] = source
            source.activate()
        }
        return pair[1]
    }

    /// SIGHUP to the shell's process group, SIGKILL after `grace`.
    @objc dynamic func terminate(grace: TimeInterval = 2) {
        queue.async { [self] in
            guard alive else { return }
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            queue.asyncAfter(deadline: .now() + grace) { [self] in
                if alive {
                    kill(-pid, SIGKILL); kill(pid, SIGKILL)
                }
            }
        }
    }

    // MARK: Private (on the queue)

    @objc dynamic private func drain() {
        var chunk = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while chunk.count < Self.deliveryBytes {
            let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.append(contentsOf: buffer[0 ..< count])
                continue
            }
            if count < 0, errno == EINTR {
                continue
            }
            if count == 0 || (count < 0 && errno != EAGAIN) {
                // EOF or EIO: the slave side is gone.
                readSource?.cancel()
                readSource = nil
            }
            break
        }
        guard !chunk.isEmpty else { return }
        onOutput?(chunk)
        for (peer, _) in peers {
            chunk.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let count = send(peer, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                    if count > 0 {
                        sent += count; continue
                    }
                    if count < 0, errno == EINTR {
                        continue
                    }
                    break // a peer that does not keep up loses live output; the events have it all
                }
            }
        }
    }

    @objc dynamic private func readPeer(_ peer: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { recv(peer, $0.baseAddress, $0.count, 0) }
        if count > 0 {
            writeAll(Data(buffer[0 ..< count]))
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            peers.removeValue(forKey: peer)?.cancel()
        }
    }

    private func writeAll(_ data: Data) {
        guard alive else { return }
        data.withUnsafeBytes { bytes in
            var written = 0
            var spins = 0
            while written < bytes.count {
                let count = Darwin.write(master, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count > 0 {
                    written += count; continue
                }
                if count < 0, errno == EINTR {
                    continue
                }
                if count < 0, errno == EAGAIN, spins < 200 {
                    spins += 1
                    usleep(5000)
                    continue
                }
                break
            }
        }
    }

    /// How often the reap is polled after NOTE_EXIT; starting at it checks once.
    private static let reapAttempts = 25

    /// NOTE_EXIT can arrive before the child is a zombie, so the reap is polled.
    @objc dynamic private func pollReap(attempt: Int) {
        guard alive else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            alive = false
            drain()
            readSource?.cancel()
            readSource = nil
            exitSource?.cancel()
            exitSource = nil
            peers.values.forEach { $0.cancel() }
            peers.removeAll()
            close(master)
            onExit?(status)
            onExit = nil
            onOutput = nil
            return
        }
        guard result == 0, attempt < Self.reapAttempts else { return }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.pollReap(attempt: attempt + 1) }
    }

    @objc dynamic private static func cStrings(_ values: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: values.count + 1)
        for (index, value) in values.enumerated() {
            array[index] = strdup(value)
        }
        array[values.count] = nil
        return array
    }

    @objc dynamic private static func freeCStrings(_ array: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, count: Int) {
        for index in 0 ..< count {
            free(array[index])
        }
        array.deallocate()
    }
}
