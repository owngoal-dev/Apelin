import CToolchainSystem
import Darwin
import Foundation

public struct ToolchainSelfTest: Sendable {
    public init() {}
    /// The SDK must already be registered. Its physical canonical path is passed to every compiler call.
    /// The host commits registration only when every required result passes.
    public func run(
        toolchain: URL,
        sdk: URL,
        scratch: URL,
        progress: @escaping ToolchainProgressHandler = { _ in },
    ) async throws -> [ToolchainTestResult] {
        let root = try canonical(toolchain), sdk = try canonical(sdk)
        guard FileManager.default.fileExists(atPath: sdk.appendingPathComponent("SDKSettings.json").path) else {
            throw ToolchainFailure("The registered SDK is incomplete. Remove it and add it again.")
        }
        try directory(scratch)
        let scratch = try canonical(scratch)
        let manifest = try JSONDecoder().decode(
            ToolchainManifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")),
        )
        try ToolchainSetup.verify(manifest, at: root)
        let bin = root.appendingPathComponent("usr/bin")
        let samples: [(String, String, String)] = [
            // __builtin_available needs the builtins' __isPlatformVersionAtLeast at link time.
            ("C", "c", "#include <stdio.h>\nint main(void) { if (__builtin_available(iOS 13.0, *)) puts(\"apelin-ok\"); else puts(\"bad\"); return 0; }\n"),
            ("C++", "cpp", "#include <iostream>\n#include <vector>\nint main() { std::vector<int> v{1,2,3}; std::cout << (v.size()==3 ? \"apelin-ok\" : \"bad\") << std::endl; }\n"),
            ("ObjC", "m", "#import <Foundation/Foundation.h>\n#include <stdio.h>\nint main(void) { @autoreleasepool { NSArray *a = @[@1,@2]; puts(a.count==2 ? \"apelin-ok\" : \"bad\"); } return 0; }\n"),
        ]
        var results: [ToolchainTestResult] = []
        for arch in ["arm64", "arm64e"] {
            for (language, suffix, source) in samples {
                try Task.checkCancellation()
                let start = Date()
                let work = scratch.appendingPathComponent(UUID().uuidString)
                try directory(work)
                defer { try? FileManager.default.removeItem(at: work) }
                do {
                    progress(.init(
                        stage: .validating,
                        completedBytes: 0,
                        totalBytes: nil,
                        detail: "\(language) \(arch)",
                    ))
                    let input = work.appendingPathComponent("hello." + suffix),
                        object = work.appendingPathComponent("hello.o"),
                        executable = work.appendingPathComponent("hello")
                    try Data(source.utf8).write(to: input)
                    var flags = [
                        "-target", "\(arch)-apple-ios\(manifest.minimumOS)",
                        "-isysroot", sdk.path,
                        "-B" + bin.path,
                        "-g",
                    ]
                    if language == "C++" {
                        flags += ["-stdlib=libc++", "-std=c++17"]
                    }
                    if language == "ObjC" {
                        flags += ["-fobjc-arc"]
                    }
                    _ = try await runProcess(
                        bin.appendingPathComponent("clang"),
                        flags + ["-c", input.path, "-o", object.path],
                        cwd: work,
                        bin: bin,
                    )
                    var link = flags + [object.path, "-o", executable.path]
                    if language == "C++" {
                        link += ["-lc++"]
                    }
                    if language == "ObjC" {
                        link += ["-framework", "Foundation"]
                    }
                    _ = try await runProcess(bin.appendingPathComponent("clang"), link, cwd: work, bin: bin)
                    let dsym = work.appendingPathComponent("hello.dSYM")
                    _ = try await runProcess(
                        bin.appendingPathComponent("dsymutil"),
                        [executable.path, "-o", dsym.path],
                        cwd: work,
                        bin: bin,
                    )
                    var image = try MachOImage(Data(contentsOf: executable))
                    let symbols = try MachOImage(
                        Data(contentsOf: dsym.appendingPathComponent("Contents/Resources/DWARF/hello")),
                        allowDSYM: true,
                    )
                    guard let uuid = image.uuid, uuid == symbols.uuid else {
                        throw ToolchainFailure("dSYM UUID differs from executable")
                    }
                    try image.signed(identifier: "hello").write(to: executable, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                    let output = try await runProcess(executable, [], cwd: work, bin: bin)
                    guard output.contains("apelin-ok") else {
                        throw ToolchainFailure("The test program did not produce the expected output.")
                    }
                    results.append(.init(
                        language: language,
                        architecture: arch,
                        passed: true,
                        detail: "Compile, link, run and dSYM UUID \(uuid) matched",
                        seconds: Date().timeIntervalSince(start),
                    ))
                } catch {
                    try Task.checkCancellation()
                    results.append(.init(
                        language: language,
                        architecture: arch,
                        passed: false,
                        detail: String(describing: error),
                        seconds: Date().timeIntervalSince(start),
                    ))
                    // Do not keep launching tools that may be crashing on
                    // this host. The failed case already refuses registration.
                    return results
                }
            }
        }
        if manifest.components.contains(.swift) {
            results += try await SwiftSelfTest(
                bin: bin,
                sdk: sdk,
                scratch: scratch,
                minimumOS: manifest.minimumOS,
            ).run(
                progress: progress,
                cltVersion: manifest.source.version,
            )
        }
        // Last, so a failure here never keeps a Swift case from running; an
        // earlier scheme's tree lacks the siblings these run.
        if manifest.retargetSchemeVersion >= BinaryToolsSelfTest.scheme {
            results += try await BinaryToolsSelfTest(
                bin: bin,
                sdk: sdk,
                scratch: scratch,
                minimumOS: manifest.minimumOS,
            ).run(progress: progress)
        }
        return results
    }
}

/// Scheme 3's cases, for the siblings two tools exec by path beside
/// themselves, which no load command names and no compile or link runs:
/// `ar rcs` execs ranlib for its `s`, and the archive it makes must link;
/// `otool` (llvm-otool) execs otool-classic for every flag, and `-hv`, `-L`
/// and `-l` read the program linked from that archive. One case each, on
/// arm64; the otool case links the objects directly when the archive did
/// not come out, so each failure names its own tool.
struct BinaryToolsSelfTest {
    /// The retarget scheme that ships what these cases run.
    static let scheme = 3
    let bin: URL, sdk: URL, scratch: URL, minimumOS: String

    static let library = "int apelin_answer(void) { return 42; }\n"
    static let program = """
    #include <stdio.h>
    int apelin_answer(void);
    int main(void) { puts(apelin_answer() == 42 ? "apelin-ok" : "bad"); return 0; }

    """

    func run(progress: ToolchainProgressHandler) async throws -> [ToolchainTestResult] {
        let architecture = "arm64"
        let work = scratch.appendingPathComponent(UUID().uuidString)
        try directory(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let flags = ["-target", "\(architecture)-apple-ios\(minimumOS)", "-isysroot", sdk.path, "-B" + bin.path]
        let library = work.appendingPathComponent("answer.o"), main = work.appendingPathComponent("main.o")
        let archive = work.appendingPathComponent("libanswer.a"), executable = work.appendingPathComponent("hello")
        func tool(_ name: String, _ arguments: [String]) async throws -> String {
            try await runProcess(bin.appendingPathComponent(name), arguments, cwd: work, bin: bin)
        }
        func compile() async throws {
            try Data(Self.library.utf8).write(to: work.appendingPathComponent("answer.c"))
            try Data(Self.program.utf8).write(to: work.appendingPathComponent("main.c"))
            _ = try await tool("clang", flags + ["-c", work.appendingPathComponent("answer.c").path, "-o", library.path])
            _ = try await tool("clang", flags + ["-c", work.appendingPathComponent("main.c").path, "-o", main.path])
        }
        var results: [ToolchainTestResult] = []
        func record(_ name: String, _ start: Date, _ body: () async throws -> String) async throws {
            try Task.checkCancellation()
            progress(.init(stage: .validating, completedBytes: 0, totalBytes: nil, detail: "\(name) \(architecture)"))
            do {
                let detail = try await body()
                results.append(.init(
                    language: name,
                    architecture: architecture,
                    passed: true,
                    detail: detail,
                    seconds: Date().timeIntervalSince(start),
                ))
            } catch {
                try Task.checkCancellation()
                results.append(.init(
                    language: name,
                    architecture: architecture,
                    passed: false,
                    detail: String(describing: error),
                    seconds: Date().timeIntervalSince(start),
                ))
            }
        }
        try await record("ar", Date()) {
            try await compile()
            // ar execs ranlib beside itself for `s`, and fails without it.
            _ = try await tool("ar", ["rcs", archive.path, library.path])
            _ = try await tool("clang", flags + [main.path, "-L" + work.path, "-lanswer", "-o", executable.path])
            try sign(executable)
            let output = try await runProcess(executable, [], cwd: work, bin: bin)
            guard output.contains("apelin-ok") else {
                throw ToolchainFailure("The test program did not produce the expected output.")
            }
            return "Archived with ar rcs (ranlib), linked and run"
        }
        try await record("otool", Date()) {
            if !FileManager.default.fileExists(atPath: executable.path) {
                if !FileManager.default.fileExists(atPath: main.path) {
                    try await compile()
                }
                _ = try await tool("clang", flags + [main.path, library.path, "-o", executable.path])
            }
            let checks: [(flag: String, expected: [String])] = [
                ("-hv", ["MH_MAGIC_64", "EXECUTE"]),
                ("-L", ["/usr/lib/libSystem.B.dylib"]),
                ("-l", ["LC_MAIN", "LC_LOAD_DYLIB"]),
            ]
            for (flag, expected) in checks {
                let output = try await tool("otool", [flag, executable.path])
                guard expected.allSatisfy(output.contains) else {
                    throw ToolchainFailure("otool \(flag) did not print \(expected.joined(separator: " and ")): \(output)")
                }
            }
            return "otool -hv, -L and -l read the program"
        }
        return results
    }

    private func sign(_ executable: URL) throws {
        var image = try MachOImage(Data(contentsOf: executable))
        try image.signed(identifier: executable.lastPathComponent).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
}

/// The Swift component's cases, beside the C family's: an executable on the
/// standard library, a library module in its own dylib with an executable
/// that imports and loads it, and structured concurrency. Each is compiled
/// to an object by `swiftc`, linked by `swiftc` (which links through clang),
/// given a dSYM whose UUID must match, signed, and run for `apelin-ok`.
/// An architecture runs only when the SDK has Swift interfaces for it: the
/// iOS 27 SDK carries arm64e ones only.
struct SwiftSelfTest {
    let bin: URL, sdk: URL, scratch: URL, minimumOS: String

    static let executable = """
    protocol Shape { var area: Double { get } }
    struct Square: Shape { let side: Double; var area: Double { side * side } }
    final class Box<T: Shape> { let item: T; init(_ item: T) { self.item = item } }
    enum Failure: Error { case odd(Int) }
    func check(_ value: Int) throws -> Int { if value % 2 == 1 { throw Failure.odd(value) }; return value }
    let words = ["swift", "on", "ios"].sorted()
    let table = Dictionary(grouping: [1, 2, 3, 4, 5, 6], by: { $0 % 3 })
    let caught = (try? check(3)) == nil && (try? check(4)) == 4
    let box = Box(Square(side: 3))
    let ok = words == ["ios", "on", "swift"] && table[0] == [3, 6] && caught && box.item.area == 9
        && "\\(words.joined(separator: "-"))" == "ios-on-swift"
    print(ok ? "apelin-ok" : "bad")
    """
    static let library = """
    public struct Greeter {
        public let name: String
        public init(name: String) { self.name = name }
        public func greeting() -> String { "apelin-" + name }
    }
    open class Counter { public private(set) var value = 0; public init() {}; open func step() { value += 1 } }
    """
    static let libraryClient = """
    import ApelinSelfTest
    final class Twice: Counter { override func step() { super.step(); super.step() } }
    let counter = Twice()
    counter.step()
    print(Greeter(name: "ok").greeting() == "apelin-ok" && counter.value == 2 ? "apelin-ok" : "bad")
    """
    static let cases = ["Swift", "Swift dylib", "Swift async", "Swift macro"]
    /// A macro, expanded by a plugin the in-process plugin server loads from
    /// `usr/lib/swift/host/plugins`. Observation needs iOS 17, so this case
    /// targets 17.0 when the toolchain's floor is lower.
    static let macro = """
    import Observation
    @Observable final class Model { var count = 0 }
    let model = Model()
    var changed = false
    withObservationTracking { _ = model.count } onChange: { changed = true }
    model.count += 1
    print(changed && model.count == 1 ? "apelin-ok" : "bad")
    """
    /// The newer of two `major.minor` versions.
    static func newer(_ lhs: String, _ rhs: String) -> String {
        lhs.compare(rhs, options: .numeric) == .orderedAscending ? rhs : lhs
    }

    static let concurrency = """
    actor Ledger {
        private var total = 0
        func add(_ amount: Int) { total += amount }
        var sum: Int { total }
    }
    func square(_ value: Int) async -> Int { await Task.yield(); return value * value }
    @main struct Main {
        static func main() async {
            let ledger = Ledger()
            await withTaskGroup(of: Int.self) { group in
                for value in 1...10 { group.addTask { await square(value) } }
                for await result in group { await ledger.add(result) }
            }
            async let first = square(11)
            let squared = await first
            let stream = AsyncStream<Int> { continuation in
                for value in 1...3 { continuation.yield(value) }
                continuation.finish()
            }
            var streamed = 0
            for await value in stream { streamed += value }
            let resumed = await withCheckedContinuation { continuation in
                Task.detached { continuation.resume(returning: 7) }
            }
            let total = await ledger.sum
            let ok = total == 385 && squared == 121 && streamed == 6 && resumed == 7
            print(ok ? "apelin-ok" : "bad")
        }
    }
    """

    /// Architectures the SDK has Swift interfaces for, of arm64 and arm64e.
    func architectures() -> [String] {
        let module = sdk.appendingPathComponent("usr/lib/swift/Swift.swiftmodule")
        return ["arm64", "arm64e"].filter {
            FileManager.default.fileExists(atPath: module.appendingPathComponent("\($0)-apple-ios.swiftinterface").path)
        }
    }

    func run(progress: ToolchainProgressHandler, cltVersion: String) async throws -> [ToolchainTestResult] {
        let swiftc = bin.appendingPathComponent("swiftc")
        // One module cache for every case: the SDK's interfaces are built once per architecture.
        let cache = scratch.appendingPathComponent("swift-module-cache")
        try directory(cache)
        let arches = architectures()
        guard !arches.isEmpty else {
            return [.init(
                language: "Swift",
                architecture: "arm64e",
                passed: false,
                detail: "The SDK has no Swift interfaces for arm64 or arm64e",
                seconds: 0,
            )]
        }
        var results: [ToolchainTestResult] = []
        // Swift macros were introduced with Swift 5.9 (CLT 15). A research
        // probe of an earlier compiler tests its supported language features.
        let swift59OrLater = cltVersion.compare("15.0", options: .numeric) != .orderedAscending
        let cases = swift59OrLater ? Self.cases : Self.cases.filter { $0 != "Swift macro" }
        for arch in arches {
            for language in cases {
                try Task.checkCancellation()
                let start = Date()
                let work = scratch.appendingPathComponent(UUID().uuidString)
                try directory(work)
                defer { try? FileManager.default.removeItem(at: work) }
                progress(.init(stage: .validating, completedBytes: 0, totalBytes: nil, detail: "\(language) \(arch)"))
                do {
                    let floor = language == "Swift macro" ? Self.newer(minimumOS, "17.0") : minimumOS
                    var flags = [
                        "-sdk", sdk.path, "-target", "\(arch)-apple-ios\(floor)",
                        "-module-cache-path", cache.path, "-g",
                    ]
                    // CLT 14.2's driver does not recognize this option. Newer
                    // drivers need it because the tree omits libSwiftScan.
                    if swift59OrLater {
                        flags.append("-nonlib-dependency-scanner")
                    }
                    func swift(_ arguments: [String]) async throws {
                        _ = try await runProcess(swiftc, flags + arguments, cwd: work, bin: bin, timeout: 900)
                    }
                    let executable = work.appendingPathComponent("hello")
                    var images = [executable]
                    switch language {
                    case "Swift dylib":
                        let library = work.appendingPathComponent("libApelinSelfTest.dylib")
                        try Data(Self.library.utf8).write(to: work.appendingPathComponent("lib.swift"))
                        try Data(Self.libraryClient.utf8).write(to: work.appendingPathComponent("main.swift"))
                        try await swift([
                            "-parse-as-library", "-module-name", "ApelinSelfTest", "-emit-module",
                            "-emit-module-path", work.appendingPathComponent("ApelinSelfTest.swiftmodule").path,
                            work.appendingPathComponent("lib.swift").path,
                        ])
                        // The legacy driver treats module emission as the
                        // output action, so emit the object in a separate call.
                        try await swift([
                            "-parse-as-library", "-module-name", "ApelinSelfTest",
                            "-c", work.appendingPathComponent("lib.swift").path,
                            "-o", work.appendingPathComponent("lib.o").path,
                        ])
                        try await swift([
                            "-emit-library", "-module-name", "ApelinSelfTest",
                            work.appendingPathComponent("lib.o").path, "-o", library.path,
                            "-Xlinker", "-install_name", "-Xlinker", "@rpath/libApelinSelfTest.dylib",
                        ])
                        try await swift([
                            "-I", work.path, "-module-name", "main",
                            "-c", work.appendingPathComponent("main.swift").path,
                            "-o", work.appendingPathComponent("main.o").path,
                        ])
                        try await swift([
                            work.appendingPathComponent("main.o").path, "-L", work.path, "-lApelinSelfTest",
                            "-Xlinker", "-rpath", "-Xlinker", "@executable_path", "-o", executable.path,
                        ])
                        images.append(library)
                    default:
                        let source = [
                            "Swift": Self.executable, "Swift async": Self.concurrency, "Swift macro": Self.macro,
                        ][language] ?? ""
                        try Data(source.utf8).write(to: work.appendingPathComponent("main.swift"))
                        let object = work.appendingPathComponent("main.o")
                        try await swift(
                            (language == "Swift async" ? ["-parse-as-library"] : [])
                                + ["-module-name", "main", "-c", work.appendingPathComponent("main.swift").path,
                                   "-o", object.path],
                        )
                        try await swift([object.path, "-o", executable.path])
                    }
                    var uuids: [String] = []
                    for image in images {
                        let dsym = work.appendingPathComponent(image.lastPathComponent + ".dSYM")
                        _ = try await runProcess(
                            bin.appendingPathComponent("dsymutil"),
                            [image.path, "-o", dsym.path],
                            cwd: work,
                            bin: bin,
                        )
                        var binary = try MachOImage(Data(contentsOf: image))
                        let symbols = try MachOImage(
                            Data(contentsOf: dsym.appendingPathComponent(
                                "Contents/Resources/DWARF/" + image.lastPathComponent,
                            )),
                            allowDSYM: true,
                        )
                        guard let uuid = binary.uuid, uuid == symbols.uuid else {
                            throw ToolchainFailure("dSYM UUID differs from \(image.lastPathComponent)")
                        }
                        uuids.append(uuid)
                        try binary.signed(identifier: image.lastPathComponent, forSelfTest: true)
                            .write(to: image, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: image.path)
                    }
                    let output = try await runProcess(executable, [], cwd: work, bin: bin)
                    guard output.contains("apelin-ok") else {
                        throw ToolchainFailure("The test program did not produce the expected output: \(output)")
                    }
                    results.append(.init(
                        language: language,
                        architecture: arch,
                        passed: true,
                        detail: "Compile, link, run and dSYM UUID \(uuids.joined(separator: ", ")) matched",
                        seconds: Date().timeIntervalSince(start),
                    ))
                } catch {
                    try Task.checkCancellation()
                    results.append(.init(
                        language: language,
                        architecture: arch,
                        passed: false,
                        detail: String(describing: error),
                        seconds: Date().timeIntervalSince(start),
                    ))
                    return results
                }
            }
        }
        return results
    }
}

/// No shell, explicit argv, bounded runtime, disk-backed output, cancellation reaps the child.
func runProcess(
    _ executable: URL,
    _ arguments: [String],
    cwd: URL,
    bin: URL,
    timeout: Double = 120,
) async throws -> String {
    let log = cwd.appendingPathComponent("process.log")
    let fd = open(log.path, O_CREAT | O_TRUNC | O_WRONLY | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw ToolchainFailure("Unable to start the self-test. Try again.") }
    defer { close(fd) }
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        throw ToolchainFailure("Unable to start the self-test. Try again.")
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)
    posix_spawn_file_actions_addclose(&actions, fd)
    let argv = ([executable.path] + arguments).map { (value: String) in value.withCString { strdup($0) } } + [nil]
    let env = [
        "PATH=\(bin.path):/usr/bin:/bin",
        "HOME=\(cwd.path)",
        "TMPDIR=\(cwd.path)",
        "LC_ALL=C",
    ].map { (value: String) in value.withCString { strdup($0) } } + [nil]
    defer { argv.forEach { free($0) }; env.forEach { free($0) } }
    var pid: pid_t = 0
    let status = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
        posix_spawn(
            &pid,
            executable.path,
            &actions,
            nil,
            UnsafeMutablePointer(mutating: a.baseAddress!),
            UnsafeMutablePointer(mutating: e.baseAddress!),
        )
    } }
    guard status == 0 else {
        throw ToolchainFailure("Cannot launch \(executable.lastPathComponent): \(String(cString: strerror(status)))")
    }
    let deadline = Date().addingTimeInterval(timeout)
    var result: Int32 = 0
    do {
        while true {
            let waited = waitpid(pid, &result, WNOHANG)
            if waited == pid {
                break
            }
            if waited < 0 {
                if errno == EINTR {
                    continue
                }
                throw ToolchainFailure("Unable to read the self-test result. Run the self-test again.")
            }
            try Task.checkCancellation()
            if Date() > deadline {
                throw ToolchainFailure("The self-test did not finish within \(Int(timeout)) seconds.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    } catch {
        kill(pid, SIGKILL)
        while waitpid(pid, &result, 0) < 0, errno == EINTR {}
        throw error
    }
    let handle = try FileHandle(forReadingFrom: log); defer { try? handle.close() }
    let output = try String(decoding: handle.read(upToCount: 64 * 1024) ?? Data(), as: UTF8.self)
    guard result == 0 else {
        throw ToolchainFailure("\(executable.lastPathComponent) exited with wait status \(result): \(output)")
    }
    return output
}
