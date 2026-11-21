import ApelinProtocol
import Darwin
import Foundation

/// icli's `device passcode` command line, the one way Apelin's passcode
/// reaches the keybag: the owner's rule is that a passcode is used only
/// after this command has unlocked the device with it, so the test and
/// every later unlock go through the same executable. It carries
/// `com.apple.keystore.device`, which apelin-diagnostics does not.
///
/// The passcode goes on standard input (`--passcode-stdin`), never in argv,
/// the environment or a file. The executable must be a regular file root
/// owns and only root may write, in a folder only root may write, as the
/// session host holds its workers. One run is bounded by `timeout` and
/// killed past it; a killed attempt keeps no promise (`UnlockAnswer`).
struct IcliPasscodeCommand: PasscodeKeybag {
    let executable: String
    let environment: [String]
    var timeout: TimeInterval = 30
    /// Root's uid, which the executable and its folder must have; a test
    /// passes its own.
    var owner: uid_t = 0

    init(installRoot: String, home: String) {
        let prefix = installRoot == "/" ? "" : installRoot
        executable = "\(prefix)/usr/bin/icli"
        environment = [
            "PATH=\(prefix)/usr/bin:/usr/bin:/bin",
            "HOME=\(home)",
            "DISABLE_TWEAKS=1",
        ]
    }

    init(executable: String, environment: [String], timeout: TimeInterval, owner: uid_t) {
        self.executable = executable
        self.environment = environment
        self.timeout = timeout
        self.owner = owner
    }

    // MARK: Commands

    func status() throws -> KeybagStatus {
        let run = try run(["device", "passcode", "status"], input: nil)
        guard run.status == 0, let answer = run.answer, let status = KeybagStatus(json: answer) else {
            throw KeybagFailure.failed("icli's passcode status did not read (\(run.summary))")
        }
        return status
    }

    func unlock(passcode: String) -> UnlockAnswer {
        let arguments = [
            "device", "passcode", "unlock", "--passcode-stdin",
            "--max-failures", String(DevicePasscode.maximumFailures),
        ]
        do {
            let run = try run(arguments, input: passcode)
            return UnlockAnswer.reading(status: run.status, answer: run.answer)
        } catch let failure as KeybagFailure {
            // Not started: nothing reached the keybag.
            return UnlockAnswer(outcome: .refused, detail: failure.detail)
        } catch {
            return UnlockAnswer(outcome: .unknown, detail: "\(error)")
        }
    }

    func forgetRejected() throws {
        let run = try run(["device", "passcode", "forget", "--force"], input: nil)
        guard run.status == 0 else {
            throw KeybagFailure.failed("icli could not clear its rejected passcodes (\(run.summary))")
        }
    }

    // MARK: Running icli

    struct Run {
        /// The exit status; nil when the run was killed or ended by a signal.
        var status: Int32?
        var answer: [String: Any]?
        var timedOut: Bool

        var summary: String {
            if timedOut {
                return "no answer in time"
            }
            guard let status else { return "ended by a signal" }
            return "status \(status)"
        }
    }

    /// ArgumentParser's status for a command it does not know.
    static let usageStatus: Int32 = 64
    static let maximumAnswerBytes = 64 * 1024

    /// Runs icli once. Throws `KeybagFailure` when it was not started, or
    /// when it does not know `device passcode` (status 64, before anything
    /// ran); every other end is in the `Run`.
    func run(_ arguments: [String], input: String?) throws -> Run {
        try checkExecutable()
        var output: [Int32] = [0, 0]
        guard pipe(&output) == 0 else { throw KeybagFailure.failed("no pipe for icli's answer") }
        var feed: [Int32] = [-1, -1]
        if input != nil {
            guard pipe(&feed) == 0 else {
                close(output[0])
                close(output[1])
                throw KeybagFailure.failed("no pipe for icli's input")
            }
            _ = fcntl(feed[1], F_SETNOSIGPIPE, 1)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, feed[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A group of its own, so a run past its time goes with anything it
        // started that still holds the answer's pipe.
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

        var pid: pid_t = 0
        let argv = ["icli"] + arguments
        let spawned = Self.withCStrings(argv) { argvPointer in
            Self.withCStrings(environment) { environmentPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, environmentPointer)
            }
        }
        close(output[1])
        if input != nil {
            close(feed[0])
        }
        guard spawned == 0 else {
            close(output[0])
            if input != nil {
                close(feed[1])
            }
            throw KeybagFailure.failed("icli could not be started: \(String(cString: strerror(spawned)))")
        }

        let watchdog = Watchdog(pid: pid)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog.item)
        if let input {
            // One line, as icli reads it; a pipe this small never blocks.
            var bytes = Array(input.utf8) + [0x0A]
            _ = bytes.withUnsafeBytes { write(feed[1], $0.baseAddress, $0.count) }
            bytes.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    memset_s(base, buffer.count, 0, buffer.count)
                }
            }
            close(feed[1])
        }
        let data = Self.readAll(output[0], limit: Self.maximumAnswerBytes)
        close(output[0])
        var wait: Int32 = 0
        while waitpid(pid, &wait, 0) < 0, errno == EINTR {}
        let timedOut = watchdog.disarm()

        let exited = wait & 0x7F == 0
        let status: Int32? = exited && !timedOut ? (wait >> 8) & 0xFF : nil
        let answer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status == Self.usageStatus, arguments.starts(with: ["device", "passcode"]) {
            throw KeybagFailure.outdated
        }
        return Run(status: status, answer: answer, timedOut: timedOut)
    }

    /// The executable may be handed a passcode only while nobody but root
    /// could have put it there.
    private func checkExecutable() throws {
        var file = stat()
        guard lstat(executable, &file) == 0 else {
            throw KeybagFailure.failed("icli is not installed at \(executable)")
        }
        guard file.st_mode & S_IFMT == S_IFREG, file.st_uid == owner, file.st_mode & 0o022 == 0 else {
            throw KeybagFailure.failed("\(executable) is not a regular file only root may write")
        }
        var folder = stat()
        let parent = (executable as NSString).deletingLastPathComponent
        guard stat(parent, &folder) == 0, folder.st_uid == owner, folder.st_mode & 0o022 == 0 else {
            throw KeybagFailure.failed("\(parent) is writable by others than root")
        }
    }

    private static func readAll(_ descriptor: Int32, limit: Int) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else { break }
            // Read on past the limit, so icli never blocks on a full pipe.
            if data.count < limit {
                data.append(buffer, count: min(count, limit - data.count))
            }
        }
        return data
    }

    private static func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    /// Kills the run once its time is up, unless disarmed first.
    private final class Watchdog: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        @objc private dynamic var fired = false
        @objc private dynamic var disarmed = false
        private(set) var item: DispatchWorkItem!

        init(pid: pid_t) {
            self.pid = pid
            item = DispatchWorkItem { [weak self] in self?.fire() }
        }

        @objc dynamic func fire() {
            lock.lock()
            defer { lock.unlock() }
            guard !disarmed else { return }
            fired = true
            killpg(pid, SIGKILL)
        }

        /// Whether it fired; after this it never will.
        @objc dynamic func disarm() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            disarmed = true
            item.cancel()
            return fired
        }
    }
}
