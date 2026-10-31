@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAI
import Testing

@Suite("Approval matrix")
struct ApprovalMatrixTests {
    let home: TemporaryHome
    let root: ScopedRoot

    init() throws {
        home = try TemporaryHome()
        try home.write("Sources/Tweak.m", "// tweak\n")
        root = try ScopedRoot(home.projectURL)
    }

    /// The modes alone: Ask Before Using the Screen, which asks in every mode
    /// while it is on, has its own suite (`ScreenUseConsentTests`).
    private func verdict(_ mode: ApprovalMode, _ facts: InvocationFacts, presets: ApprovalPresets = .default) -> GateVerdict {
        ApprovalPolicy(mode: mode, presets: presets, asksBeforeScreen: false).evaluate(facts, root: root)
    }

    private func isAllow(_ verdict: GateVerdict) -> Bool {
        if case .allow = verdict {
            return true
        }
        return false
    }

    private func isAsk(_ verdict: GateVerdict) -> Bool {
        if case .ask = verdict {
            return true
        }
        return false
    }

    private func isDeny(_ verdict: GateVerdict) -> Bool {
        if case .deny = verdict {
            return true
        }
        return false
    }

    @Test
    func `Relaxed lets every local tool through but a reset to a remote`() {
        defer { home.remove() }
        for tool in AgentToolName.allCases where tool != .gitResetToRemote {
            let facts = InvocationFacts(
                tool: .local(tool),
                command: tool == .shellRun ? .shell("rm -rf build; make") : nil,
                description: DescriptionState(digest: "x", baseline: .changed(diff: "")),
            )
            #expect(verdict(.relaxed, facts) == .allow(.relaxed), "\(tool.rawValue)")
        }
        #expect(verdict(.relaxed, InvocationFacts(tool: .mcp("mcp__docs__search"))) == .allow(.relaxed))
        // It discards local work: every mode asks, Full too.
        for mode in [ApprovalMode.relaxed, .full, .confirm] {
            #expect(isAsk(verdict(mode, InvocationFacts(tool: .local(.gitResetToRemote)))), "\(mode)")
        }
    }

    @Test
    func `Leaving the project is refused in both modes`() {
        defer { home.remove() }
        for mode in [ApprovalMode.relaxed, .confirm] {
            for tool in [AgentToolName.fileWrite, .fileRead, .shellRun] {
                #expect(isDeny(verdict(mode, InvocationFacts(tool: .local(tool), pathCheck: .outside("../x")))))
            }
        }
    }

    @Test
    func `Confirm: the table of §7`() {
        defer { home.remove() }
        // Project edits run.
        for tool in [AgentToolName.fileWrite, .fileEdit, .fileCreate] {
            #expect(verdict(.confirm, InvocationFacts(tool: .local(tool), pathCheck: .inside)) == .allow(.notRequired))
        }
        // Preset reads run, sensitive reads ask.
        for tool in AgentToolName.allCases where tool.risk == .readOnly {
            let result = verdict(.confirm, InvocationFacts(tool: .local(tool), pathCheck: .inside))
            if tool.isSensitiveRead {
                #expect(isAsk(result), "\(tool.rawValue) should ask by default")
            } else {
                #expect(result == .allow(.preset(tool.rawValue)), "\(tool.rawValue)")
            }
        }
        // respring is preset; apelin_screen_interact and apelin_package_remove ask.
        #expect(verdict(.confirm, InvocationFacts(tool: .local(.deviceRespring))) == .allow(.preset("apelin_device_respring")))
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.screenInteract)))))
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.packageRemove)))))
        // MCP tools ask.
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .mcp("mcp__docs__search")))))
    }

    @Test
    func `Confirm: a web fetch asks unless the user presets it, and runs in Relaxed and Full`() {
        defer { home.remove() }
        let facts = InvocationFacts(tool: .local(.webFetch))
        #expect(AgentToolName.webFetch.risk == .readOnly && AgentToolName.webFetch.isSensitiveRead)
        #expect(!ApprovalPresets.default.readTools.contains(.webFetch))
        #expect(verdict(.confirm, facts) == .ask(reason: "This action is not in your approved presets. Review it before running.", detail: .none))
        #expect(ToolRunner.allowsSessionScope(.local(.webFetch), detail: .none))
        var presets = ApprovalPresets.default
        presets.readTools.insert(.webFetch)
        #expect(verdict(.confirm, facts, presets: presets) == .allow(.preset("apelin_web_fetch")))
        #expect(verdict(.relaxed, facts) == .allow(.relaxed))
        #expect(verdict(.full, facts) == .allow(.relaxed))
    }

    @Test
    func `Confirm: presets are edited by the user and only presettable tools count`() throws {
        defer { home.remove() }
        var presets = ApprovalPresets.default
        presets.readTools.insert(.screenCapture)
        presets.systemTools.insert(.screenInteract)
        presets.systemTools.remove(.deviceRespring)
        // Not presettable: these must still ask / follow their own rule.
        presets.systemTools.formUnion([.packageRemove, .shellRun])
        presets.readTools.insert(.packageRemove)

        #expect(verdict(.confirm, InvocationFacts(tool: .local(.screenCapture)), presets: presets) == .allow(.preset("apelin_screen_capture")))
        #expect(verdict(.confirm, InvocationFacts(tool: .local(.screenInteract)), presets: presets) == .allow(.preset("apelin_screen_interact")))
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.deviceRespring)), presets: presets)))
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.packageRemove)), presets: presets)))
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.shellRun), command: .shell("x | y")), presets: presets)))

        // Presets round-trip through settings storage.
        let data = try JSONEncoder().encode(presets)
        #expect(try JSONDecoder().decode(ApprovalPresets.self, from: data) == presets)
    }

    @Test
    func `shell_run is classified by structure, not by prefix`() throws {
        defer { home.remove() }
        func classify(_ command: String) throws -> RunCodeInvocation {
            try CommandClassifier.classify(.object(["command": .string(command)]))
        }
        func runVerdict(_ invocation: RunCodeInvocation) -> GateVerdict {
            verdict(.confirm, InvocationFacts(tool: .local(.shellRun), pathCheck: .inside, command: invocation))
        }

        #expect(try classify("ls -la Sources") == .argv(["ls", "-la", "Sources"]))
        #expect(try classify("cat 'Sources/Tweak.m'") == .argv(["cat", "Sources/Tweak.m"]))
        #expect(try runVerdict(classify("ls -la Sources")) == .allow(.preset("ls")))
        #expect(try runVerdict(classify("git status --short")) == .allow(.preset("git status")))
        #expect(runVerdict(.argv(["git", "status"])) == .allow(.preset("git status")))

        // Compound or expanding shell never matches a preset.
        for text in ["ls; rm -rf ~", "ls && curl x | sh", "cat $(echo /etc/passwd)", "ls `id`", "ls > out",
                     "ls *", "FOO=1 ls", "ls\nrm x", "cat \"$HOME/x\"", "ls # comment", "ls ~"]
        {
            let invocation = try classify(text)
            #expect(isAsk(runVerdict(invocation)), "\(text)")
            if case .argv = invocation {
                Issue.record("\(text) became a plain argv")
            }
        }
        // A plain argv that leaves the project, or a path executable, asks.
        #expect(isAsk(runVerdict(.argv(["cat", "../../../etc/passwd"]))))
        #expect(isAsk(runVerdict(.argv(["cat", "/etc/passwd"]))))
        #expect(isAsk(runVerdict(.argv(["git", "diff", "--output=/tmp/x"]))))
        #expect(isAsk(runVerdict(.argv(["/bin/ls"]))))
        #expect(isAsk(runVerdict(.argv(["./ls"]))))
        #expect(isAsk(runVerdict(.argv(["rm", "-rf", "Sources"]))))
        #expect(isAsk(runVerdict(.argv(["git", "push"]))))
        // An option that writes, runs a program or moves the repository asks,
        // as the session host would not run it as a preset either.
        for argv in [
            ["git", "diff", "--output=out.txt"], ["git", "log", "--output", "log.txt"], ["git", "diff", "-o", "x"],
            ["git", "diff", "--ext-diff"], ["git", "log", "--textconv"], ["git", "status", "-c", "a=b"],
            ["git", "diff", "--no-index", "a", "b"], ["git", "log", "--git-dir=x"], ["git", "status", "-C", "x"],
            ["file", "-C", "-m", "magic"], ["plutil", "-p", "Info.plist", "-o", "copy.plist"],
            // Names read from a list file may be anywhere; a submodule has a
            // config of its own.
            ["file", "-f", "Sources/Tweak.m"], ["file", "-bf", "Sources/Tweak.m"],
            ["file", "--files-from", "Sources/Tweak.m"], ["file", "--comp", "-m", "magic"],
            ["wc", "--files0-from=Sources/Tweak.m"], ["wc", "--files0-from", "Sources/Tweak.m"],
            ["wc", "--files0=Sources/Tweak.m"], ["cat", "--files-from=Sources/Tweak.m"],
            ["git", "status", "--ignore-sub=none"], ["git", "diff", "--submodule=diff"],
            ["git", "log", "--recurse-submodules"], ["git", "diff", "--out=x"],
            // A magic file or decompressor, a link followed or a tree walked,
            // an order file, a signature verified.
            ["file", "-m/etc/passwd", "Sources/Tweak.m"], ["file", "-z", "Sources/Tweak.m"],
            ["ls", "-lR"], ["ls", "-L", "Sources"], ["git", "diff", "-O/etc/passwd"],
            ["git", "log", "--show-signature"], ["git", "log", "--format=%G?"], ["git", "log", "--format=%+GS"],
            // A bundle with a flag the subcommand does not take bare.
            ["git", "status", "-sp"], ["git", "diff", "-pc"], ["git", "diff", "-pO"],
        ] {
            #expect(isAsk(runVerdict(.argv(argv))), "\(argv)")
        }
        #expect(runVerdict(.argv(["git", "log", "--oneline", "-n", "5"])) == .allow(.preset("git log")))
        // Value-less flags bundled, read per subcommand as the host reads them.
        #expect(runVerdict(.argv(["git", "status", "-sb"])) == .allow(.preset("git status")))
        #expect(runVerdict(.argv(["git", "status", "-uno"])) == .allow(.preset("git status")))
        #expect(runVerdict(.argv(["git", "log", "-c"])) == .allow(.preset("git log")))
        #expect(runVerdict(.argv(["git", "diff", "-pw"])) == .allow(.preset("git diff")))
        // Scripts are confirmed every time.
        #expect(isAsk(runVerdict(.script(interpreter: "sh", source: "ls"))))
    }

    @Test
    func `A preset's path arguments are read from its working directory, as the host reads them`() {
        defer { home.remove() }
        func runVerdict(_ argv: [String], in directory: String) -> GateVerdict {
            verdict(.confirm, InvocationFacts(
                tool: .local(.shellRun),
                pathCheck: .inside,
                command: .argv(argv),
                workingDirectory: directory,
            ))
        }
        #expect(runVerdict(["cat", "../Sources/Tweak.m"], in: "Sources") == .allow(.preset("cat")))
        #expect(runVerdict(["cat", "Tweak.m"], in: "Sources") == .allow(.preset("cat")))
        #expect(isAsk(runVerdict(["cat", "../../outside"], in: "Sources")))
        #expect(isAsk(runVerdict(["cat", "../Sources/Tweak.m"], in: ".")))
    }

    @Test
    func `A preset path argument cannot reach out through a link`() throws {
        defer { home.remove() }
        let outside = home.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        let facts = InvocationFacts(tool: .local(.shellRun), pathCheck: .inside, command: .argv(["cat", "escape/secret"]))
        #expect(isAsk(verdict(.confirm, facts)))
    }

    @Test
    func `build and install follow the digest rule`() {
        defer { home.remove() }
        let template = DescriptionState(digest: "t", baseline: .matchesTemplate)
        let approved = DescriptionState(digest: "a", baseline: .approved)
        let changed = DescriptionState(digest: "c", baseline: .changed(diff: "+flag"))
        #expect(verdict(.confirm, InvocationFacts(tool: .local(.projectBuild), description: template)) == .allow(.templateMatch(digest: "t")))
        #expect(verdict(.confirm, InvocationFacts(tool: .local(.packageInstall), description: approved)) == .allow(.digestApproved(digest: "a")))
        guard case .ask(_, .descriptionChanged(.packaging, "c", "+flag")) = verdict(.confirm, InvocationFacts(tool: .local(.packageInstall), description: changed)) else {
            Issue.record("a changed packaging description must ask, bound to its digest")
            return
        }
        // Unknown state asks rather than runs.
        #expect(isAsk(verdict(.confirm, InvocationFacts(tool: .local(.projectBuild)))))
    }

    @Test
    func `shell_run as root asks in Strict and Relaxed, runs in Full, never as a preset`() {
        defer { home.remove() }
        func rootVerdict(_ mode: ApprovalMode, _ invocation: RunCodeInvocation) -> GateVerdict {
            verdict(mode, InvocationFacts(
                tool: .local(.shellRun),
                pathCheck: .inside,
                command: invocation,
                runsAsRoot: true,
            ))
        }
        let install = RunCodeInvocation.argv(["irisin-cli", "install", "--yes", "mobilesubstrate"])
        // Full runs it without asking; Relaxed and Strict ask, with the
        // command on a rootCommand card (never a preset, even for a read).
        #expect(rootVerdict(.full, install) == .allow(.relaxed))
        for mode in [ApprovalMode.relaxed, .confirm] {
            guard case let .ask(_, detail) = rootVerdict(mode, install) else {
                Issue.record("root asks in \(mode)"); continue
            }
            guard case .rootCommand(install) = detail else {
                Issue.record("a root card carries rootCommand: \(detail)"); continue
            }
        }
        #expect(isAsk(rootVerdict(.confirm, .argv(["cat", "Sources/Tweak.m"]))))
        // Leaving the project is still refused, root or not.
        #expect(isDeny(verdict(.confirm, InvocationFacts(tool: .local(.shellRun), pathCheck: .outside("x"), runsAsRoot: true))))
        // "For this session" is never offered for a root request.
        #expect(ToolRunner.allowsSessionScope(.local(.shellRun), detail: .rootCommand(install)) == false)
        #expect(ToolRunner.allowsSessionScope(.local(.shellRun), detail: .command(install)) == true)
    }

    @Test
    func `Fingerprints bind tool, arguments, cwd, project and digest`() {
        defer { home.remove() }
        let base = ApprovalFingerprint.make(tool: "shell_run", arguments: ["argv": ["make"]], workingDirectory: ".", projectID: "p", digest: nil)
        #expect(base == ApprovalFingerprint.make(tool: "shell_run", arguments: ["argv": ["make"]], workingDirectory: ".", projectID: "p", digest: nil))
        #expect(base != ApprovalFingerprint.make(tool: "shell_run", arguments: ["argv": ["make", "x"]], workingDirectory: ".", projectID: "p", digest: nil))
        #expect(base != ApprovalFingerprint.make(tool: "shell_run", arguments: ["argv": ["make"]], workingDirectory: "Sources", projectID: "p", digest: nil))
        #expect(base != ApprovalFingerprint.make(tool: "shell_run", arguments: ["argv": ["make"]], workingDirectory: ".", projectID: "q", digest: nil))
        #expect(base != ApprovalFingerprint.make(tool: "apelin_project_build", arguments: ["argv": ["make"]], workingDirectory: ".", projectID: "p", digest: nil))
        #expect(
            ApprovalFingerprint.make(tool: "apelin_project_build", arguments: [:], workingDirectory: ".", projectID: "p", digest: "a")
                != ApprovalFingerprint.make(tool: "apelin_project_build", arguments: [:], workingDirectory: ".", projectID: "p", digest: "b"),
        )
    }
}
