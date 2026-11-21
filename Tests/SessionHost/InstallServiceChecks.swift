import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

// Issue #66: when irisind does not answer the handshake, the failure says
// why, as far as root can tell (Apelind/Session/Install/InstallServiceDiagnosis.swift):
// Irisin missing, unfinished or too old by the package database; irisind's
// files gone; its job not loaded; irisind's admission rule refusing a folder,
// the executable or a missing entitlement. A handshake nobody answers ends.
// A transaction that fails while another program holds the package database
// names that program before Irisin's words.

/// The package database a check says it is, or one that cannot be read.
private struct StaticDatabase: InstalledPackageSource {
    var packages: [String: InstalledPackage]?

    func installedPackages() throws -> [String: InstalledPackage] {
        guard let packages else { throw ApelinError(.unavailable, "unreadable") }
        return packages
    }

    static func irisin(_ version: String, status: String = "install ok installed") -> StaticDatabase {
        StaticDatabase(packages: [
            InstallServiceRequirement.irisinPackage: InstalledPackage(
                packageID: InstallServiceRequirement.irisinPackage,
                version: version,
                status: status,
                essential: false,
                priority: nil,
            ),
        ])
    }
}

/// irisind as a device that never lets the handshake through shows it:
/// every attempt fails `code`, or, with no code, nothing ever answers.
private final class UnansweringIrisin: InstallService, @unchecked Sendable {
    let code: InstallServiceError.Code?
    let lock = NSLock()
    var attempts = 0
    var resets = 0

    init(_ code: InstallServiceError.Code?) {
        self.code = code
    }

    func serviceInfo() async throws -> InstallServiceInfo {
        lock.withLock { attempts += 1 }
        guard let code else {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw InstallServiceError(.interrupted)
        }
        throw InstallServiceError(code)
    }

    func reset() {
        lock.withLock { resets += 1 }
    }

    func submitInstall(transaction _: UUID, descriptor _: Int32, sha256 _: String) async throws -> InstallTransactionStatus {
        throw InstallServiceError(.unavailable)
    }

    func removePackage(transaction _: UUID, packageID _: String) async throws -> InstallTransactionStatus {
        throw InstallServiceError(.unavailable)
    }

    func respring(transaction _: UUID) async throws -> InstallTransactionStatus {
        throw InstallServiceError(.unavailable)
    }

    func status(of _: UUID) async throws -> InstallTransactionStatus {
        throw InstallServiceError(.unavailable)
    }

    func events(
        of _: UUID,
        after _: UInt64,
    ) async throws -> (status: InstallTransactionStatus, events: [InstallTransactionEvent]) {
        throw InstallServiceError(.unavailable)
    }
}

func installServiceChecks(scratchPath: String) async throws {
    // MARK: Irisin's version

    let versions: [(String, Bool?)] = [
        ("4.7.3", true), ("5.1.8", true), ("4.10.0", true), ("4.7.3-1", true), ("4.7.3.1", true), ("1:0.1", true),
        ("4.7.2", false), ("4.7", false), ("4", false), ("0:4.7.2", false),
        ("4.7.3~beta1", nil), ("", nil), ("4..7", nil), ("x:4.7.3", nil),
    ]
    for (version, expected) in versions {
        check(
            InstallServiceRequirement.meetsMinimum(version) == expected,
            "\(version.debugDescription) against \(InstallServiceRequirement.minimumIrisin): \(String(describing: expected))",
        )
    }

    // MARK: A bootstrap as the session host sees it

    let base = scratchPath + "/install-service"
    let root = base + "/root"
    let usr = root + "/usr"
    let libexec = usr + "/libexec"
    let daemons = root + "/Library/LaunchDaemons"
    let own = libexec + "/apelind"
    write(own, "#!/bin/sh\n", mode: 0o755)
    write(libexec + "/irisind", "", mode: 0o755)
    write(daemons + "/wiki.qaq.irisind.plist", "<plist/>\n")
    for folder in [root, usr, libexec, root + "/Library", daemons] {
        chmod(folder, 0o755)
    }
    let me = getuid()
    let allEntitlements = Set(InstallServiceRequirement.clientEntitlements)
    func diagnosis(entitled: Set<String> = allEntitlements) -> InstallServiceDiagnosis {
        var made = InstallServiceDiagnosis(
            installRoot: root,
            ownExecutable: { canonicalPath(own) },
            hasEntitlement: { entitled.contains($0) },
        )
        made.trustedOwners = [me]
        return made
    }
    let current = StaticDatabase.irisin("5.1.8")

    // MARK: The package database

    check(
        diagnosis().problem(after: .unavailable, packages: StaticDatabase(packages: [:])) == .notInstalled,
        "no Irisin in the package database: not installed",
    )
    check(
        diagnosis().problem(after: .interrupted, packages: StaticDatabase.irisin("5.1.8", status: "deinstall ok config-files")) == .notInstalled,
        "Irisin removed with its settings kept: not installed",
    )
    check(
        diagnosis().problem(after: .interrupted, packages: StaticDatabase.irisin("5.1.8", status: "install ok half-configured")) == .unfinished(state: "half-configured"),
        "Irisin half-configured: its install did not finish",
    )
    check(
        diagnosis().problem(after: .interrupted, packages: StaticDatabase.irisin("4.7.2")) == .tooOld(version: "4.7.2"),
        "Irisin 4.7.2: too old, by its version",
    )
    check(
        diagnosis().problem(after: .unavailable, packages: StaticDatabase.irisin("5.1.8", status: "install ok triggers-pending")) == .notLoaded,
        "Irisin with its triggers still to run counts as installed",
    )
    check(
        diagnosis().problem(after: .unavailable, packages: StaticDatabase.irisin("4.7.3~beta1")) == .notLoaded,
        "a version spelt otherwise is not judged",
    )

    // MARK: What launchd and irisind answered

    check(diagnosis().problem(after: .unavailable, packages: current) == .notLoaded, "no such service: irisind's job is not loaded")
    check(diagnosis().problem(after: .noAnswer, packages: current) == .noAnswer, "a handshake nobody answered")
    check(diagnosis().problem(after: .interrupted, packages: current) == .refused, "closed every time, nothing found: refused")
    check(
        diagnosis().problem(after: .interrupted, packages: StaticDatabase(packages: nil)) == .unknown,
        "closed every time and nothing could be read: the sentence of old",
    )
    check(
        diagnosis(entitled: allEntitlements.subtracting(["wiki.qaq.irisin.client"]))
            .problem(after: .interrupted, packages: current) == .missingEntitlement("wiki.qaq.irisin.client"),
        "an entitlement irisind requires is missing",
    )
    check(
        diagnosis(entitled: []).problem(after: .unavailable, packages: current) == .notLoaded,
        "entitlements are judged only when irisind closed the connection",
    )

    // irisind's own files.
    let plist = daemons + "/wiki.qaq.irisind.plist"
    rename(plist, plist + ".gone")
    let canonicalRoot = canonicalPath(root) ?? root
    check(
        diagnosis().problem(after: .unavailable, packages: current)
            == .missing(path: root + "/Library/LaunchDaemons/wiki.qaq.irisind.plist"),
        "irisind's launchd job file is gone: missing, by its path",
    )
    rename(plist + ".gone", plist)
    unlink(libexec + "/irisind")
    symlink(libexec + "/nowhere", libexec + "/irisind")
    check(
        diagnosis().problem(after: .interrupted, packages: current) == .missing(path: root + "/usr/libexec/irisind"),
        "irisind a link to nothing: missing",
    )
    unlink(libexec + "/irisind")
    write(libexec + "/irisind", "", mode: 0o755)

    // MARK: irisind's admission rule, run here

    let canonicalLibexec = canonicalRoot + "/usr/libexec"
    check(diagnosis().admissionRefusal() == nil, "a root-owned tree no one else can write is admitted")
    chmod(libexec, 0o775)
    check(
        diagnosis().problem(after: .interrupted, packages: current)
            == .untrustedFolder(path: canonicalLibexec, owner: me, mode: 0o775),
        "a group-writable usr/libexec is named, with its owner and permissions",
    )
    chmod(libexec, 0o755)
    chmod(root, 0o777)
    check(
        diagnosis().admissionRefusal() == .untrustedFolder(path: canonicalRoot, owner: me, mode: 0o777),
        "the install root itself is checked",
    )
    chmod(root, 0o755)
    chmod(own, 0o775)
    check(
        diagnosis().admissionRefusal() == .untrustedExecutable(path: canonicalRoot + "/usr/libexec/apelind", owner: me, mode: 0o775),
        "a group-writable executable is named",
    )
    chmod(own, 0o644)
    check(
        diagnosis().admissionRefusal() == .untrustedExecutable(path: canonicalRoot + "/usr/libexec/apelind", owner: me, mode: 0o644),
        "an executable its owner cannot run is named",
    )
    chmod(own, 0o755)
    if me != 0 {
        var rootOnly = diagnosis()
        rootOnly.trustedOwners = [0]
        check(
            rootOnly.admissionRefusal() == .untrustedExecutable(path: canonicalRoot + "/usr/libexec/apelind", owner: me, mode: 0o755),
            "an executable not owned by root is named",
        )
    }
    let outside = base + "/elsewhere/apelind"
    write(outside, "", mode: 0o755)
    let elsewhere = InstallServiceDiagnosis(
        installRoot: root,
        ownExecutable: { canonicalPath(outside) },
        hasEntitlement: { _ in true },
        trustedOwners: [me],
    )
    check(elsewhere.admissionRefusal() == nil, "an executable outside the install root is not judged by the folder rule")

    // Every sentence says what to do, and only the last keeps the old words.
    let problems: [InstallServiceProblem] = [
        .notInstalled, .unfinished(state: "half-configured"), .tooOld(version: "4.7.2"),
        .missing(path: "/var/jb/usr/libexec/irisind"), .notLoaded, .noAnswer,
        .untrustedFolder(path: "/var/jb/usr/libexec", owner: 501, mode: 0o775),
        .untrustedExecutable(path: "/var/jb/usr/libexec/apelind", owner: 501, mode: 0o755),
        .missingEntitlement("platform-application"), .refused, .unknown,
    ]
    for problem in problems {
        let message = problem.message
        check(message.hasSuffix("try again."), "\(problem): the sentence ends on what to do (\(message))")
        check(!message.contains("·"), "\(problem): no separator inside the sentence")
        check(
            (problem == .unknown) == message.contains("Make sure Irisin"),
            "\(problem): only the unexplained case keeps the old sentence",
        )
    }
    check(
        InstallServiceProblem.untrustedFolder(path: "/var/jb/usr/libexec", owner: 501, mode: 0o775).message
            .contains("/var/jb/usr/libexec") && InstallServiceProblem.untrustedFolder(path: "/x", owner: 501, mode: 0o775)
            .message.contains("775"),
        "a refused folder is named with its permissions",
    )

    // MARK: Through the bridge

    let state = URL(fileURLWithPath: base + "/state")
    let registry = TaskRegistry(directory: state.appendingPathComponent("tasks"))
    await registry.load()
    let data = base + "/home/Documents/wiki.qaq.apelin"
    try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
    func bridge(
        _ service: InstallService,
        packages: InstalledPackageSource = current,
        handshakeWait: TimeInterval = 5,
    ) -> InstallBridge {
        InstallBridge(
            paths: .init(installRoot: root, dataFolder: data, staging: state.appendingPathComponent("staging")),
            service: service,
            registry: registry,
            artifacts: ArtifactRegistry(file: state.appendingPathComponent("artifacts.json")),
            installations: InstallationStore(directory: state.appendingPathComponent("installations")),
            packages: packages,
            fileLists: FakeFileLists(),
            approvals: ApprovalLedger(directory: state.appendingPathComponent("approvals")),
            pollInterval: 0.01,
            grace: 0.2,
            handshakeWait: handshakeWait,
            diagnosis: diagnosis(),
        )
    }
    func refusal(_ bridge: InstallBridge) async -> ApelinError? {
        do {
            try await bridge.respring()
            return nil
        } catch let error as ApelinError {
            return error
        } catch {
            return ApelinError(.internal, String(describing: error))
        }
    }

    // Closed every time, with usr/libexec group-writable: that folder.
    chmod(libexec, 0o775)
    let closing = UnansweringIrisin(.interrupted)
    let refused = await refusal(bridge(closing))
    chmod(libexec, 0o755)
    let folderMessage = InstallServiceProblem.untrustedFolder(path: canonicalLibexec, owner: me, mode: 0o775).message
    check(refused?.code == .unavailable && refused?.message == folderMessage, "the bridge names the folder irisind refuses (\(String(describing: refused)))")
    check(closing.lock.withLock { closing.attempts } > 1, "a closed connection is asked again through the grace")

    // No such service, Irisin 4.7.2: the version comes first.
    let old = await refusal(bridge(UnansweringIrisin(.unavailable), packages: StaticDatabase.irisin("4.7.2")))
    check(old?.message == InstallServiceProblem.tooOld(version: "4.7.2").message, "an old Irisin is named by its version (\(String(describing: old)))")

    // Nobody answers: the call ends, and the call left out is given up.
    let silent = UnansweringIrisin(nil)
    let begin = Date()
    let unanswered = await refusal(bridge(silent, handshakeWait: 0.3))
    let waited = Date().timeIntervalSince(begin)
    check(unanswered?.message == InstallServiceProblem.noAnswer.message, "an unanswered handshake is an answer (\(String(describing: unanswered)))")
    check(waited < 5, "an unanswered handshake ends at its limit (\(waited) s)")
    check(silent.lock.withLock { silent.resets } == 1, "the unanswered call is given up")

    // MARK: Another program holding the package database

    let database = root + "/Library/dpkg"
    try FileManager.default.createDirectory(atPath: database, withIntermediateDirectories: true)
    write(database + "/lock-frontend", "")
    write(database + "/lock", "")
    write(database + "/status", "")
    try FileManager.default.createDirectory(atPath: root + "/var/lib", withIntermediateDirectories: true)
    symlink("../../Library/dpkg", root + "/var/lib/dpkg")
    check(PackageDatabaseLock.holders(installRoot: root).isEmpty, "nobody holds the database: no holder")
    check(PackageDatabaseLock.sentence([]) == nil, "no holder, no sentence")

    // perl takes apt's lock with fcntl, as dpkg and apt do, and waits.
    let ready = base + "/locked"
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    holder.arguments = [
        "-e",
        """
        use Fcntl;
        open(my $f, '+<', $ARGV[0]) or die "open: $!";
        my $lock = pack('qqlss', 0, 0, 0, F_WRLCK, 0);
        fcntl($f, F_SETLK, $lock) or die "lock: $!";
        open(my $r, '>', $ARGV[1]) or die; close($r);
        sleep 60;
        """,
        database + "/lock-frontend",
        ready,
    ]
    try holder.run()
    defer {
        holder.terminate()
        holder.waitUntilExit()
    }
    for _ in 0 ..< 250 where access(ready, F_OK) != 0 {
        usleep(20000)
    }
    let holders = PackageDatabaseLock.holders(installRoot: root)
    check(
        holders.count == 1 && holders.first?.pid == holder.processIdentifier
            && holders.first?.name?.hasPrefix("perl") == true,
        "the lock's holder is found once, by its process and name, through either folder (\(holders))",
    )
    let busy = PackageDatabaseLock.sentence(holders) ?? ""
    check(busy.contains("(process \(holder.processIdentifier))"), "the sentence names the process (\(busy))")
    check(
        PackageDatabaseLock.sentence([.init(pid: 7, name: "dpkg-fill"), .init(pid: 8, name: nil)])
            == "The package database is in use by dpkg-fill (process 7) and process 8. Wait for them to finish, then try again.",
        "two holders are both named",
    )

    // An install Irisin refuses while the database is held: who holds it first.
    let deb = data + "/locked.deb"
    makeDeb(at: deb, package: "com.example.locked", version: "1.0")
    let irisin = FakeIrisin(root: root)
    let failure = "Installation stopped: Failure(errno: 35)"
    irisin.lock.withLock {
        irisin.failNext = true
        irisin.failNextText = failure
    }
    let installing = bridge(irisin, packages: FakeDatabase(irisin: irisin))
    let handle = try await installing.install(
        InstallPackageRequest(artifactID: "file:locked.deb", digest: sha256(deb)),
        caller: .app,
    )
    let batch = try await waitForEnd(registry, handle)
    let message = batch.events.last?.payload?["message"]?.stringValue ?? ""
    check(batch.state == .failed, "the install fails")
    check(message == "\(busy) Irisin reported: \(failure)", "the holder comes before Irisin's words (\(message))")

    // Past `preparing` Irisin held the locks itself: whoever holds them now
    // came later, and is not named.
    let later = "Installation stopped at com.example.locked (configuring): exit status 1"
    irisin.lock.withLock {
        irisin.failNext = true
        irisin.failNextText = later
        irisin.failNextPhase = "verifying"
    }
    let again = try await installing.install(
        InstallPackageRequest(artifactID: "file:locked.deb", digest: sha256(deb)),
        caller: .app,
    )
    let laterBatch = try await waitForEnd(registry, again)
    let laterMessage = laterBatch.events.last?.payload?["message"]?.stringValue ?? ""
    check(laterMessage == later, "a failure past preparing is Irisin's alone (\(laterMessage))")

    holder.terminate()
    holder.waitUntilExit()
    check(PackageDatabaseLock.holders(installRoot: root).isEmpty, "a lock let go is not reported")
}
