@testable import ApelinAgent
import struct ApelinProtocol.ToolchainRecord
import Foundation
import Testing

/// The environment section's wording for the cases a device can be in, and
/// the rules the first message's file tree is cut by.
@Suite("Environment prompt and project tree")
struct EnvironmentPromptTests {
    @Test
    func `without a toolchain the prompt says so, and a binding to one that is gone is named`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("apelin-project.json", #"{"environment":{"toolchain":{"id":"gone"},"sdk":{"id":"gone-too"}}}"#)
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot, installRoot: home.home.path + "/jb")
        let root = try ScopedRoot(home.projectURL)
        let device = DeviceFacts(osVersion: "17.3.1", machine: "iPhone16,1", arm64e: true, cpuFeatures: ["FEAT_LRCPC": true, "FEAT_SHA3": false, "FEAT_DotProd": true])
        let prompt = AgentSession.systemPrompt(configuration, root: root, skills: [], device: device)
        #expect(prompt.contains("- Device: iPhone16,1 (arm64e), iOS 17.3.1; CPU features: FEAT_DotProd, FEAT_LRCPC; missing FEAT_SHA3."))
        #expect(prompt.contains("- Bootstrap: rootless, install root \(home.home.path)/jb."))
        #expect(prompt.contains("- Toolchains: none installed."))
        #expect(prompt.contains("- SDKs: none registered."))
        #expect(prompt.contains("This project binds toolchain gone, which is not installed here"))
        #expect(prompt.contains("This project binds SDK gone-too, which is not registered here"))
        #expect(prompt.contains("shell_run has no Apelin compiler until a toolchain is installed"))
        #expect(prompt.contains("never through a login shell"))
        #expect(!prompt.contains("`/rootfs`"), "the rootfs note is roothide's")
        #expect(!prompt.contains("roothide can rename the install root"), "so is the renamed jbroot's")
    }

    @Test
    func `the folders the read tools reach besides the project are named`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sdks = home.dataRoot.url.appendingPathComponent("SDKs").path
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot, installRoot: home.home.path + "/jb")
        let prompt = try AgentSession.systemPrompt(configuration, root: ScopedRoot(home.projectURL), skills: [])
        #expect(prompt.contains("- file_read, file_list, file_grep and file_find also read, never write, an absolute path inside Apelin's development extensions (\(home.home.path)/jb/usr/share/apelin/development) or the registered SDKs (\(sdks)). The headers a template's support component adds, such as the Preferences framework's, are in `<extension id>/support/include` there."))

        // Without an install root (no session host) only the SDKs are named.
        let unhosted = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let section = try EnvironmentPrompt.section(EnvironmentPrompt.inputs(unhosted, root: ScopedRoot(home.projectURL), device: .current))
        #expect(section.contains("- file_read, file_list, file_grep and file_find also read, never write, an absolute path inside the registered SDKs (\(sdks))."))
        #expect(!section.contains("development extensions"))
    }

    @Test
    func `on roothide mobile's home is inside the install root`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let jbroot = home.home.deletingLastPathComponent().path
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot, installRoot: jbroot)
        let prompt = try AgentSession.systemPrompt(configuration, root: ScopedRoot(home.projectURL), skills: [])
        #expect(prompt.contains("- Bootstrap: roothide, install root \(jbroot)."))
        #expect(prompt.contains("print `/var/mobile/…` or `/rootfs/…` for a path the toolchain's compilers know by another name"))
        // A chat that went on after the jbroot was renamed trusted the
        // paths it had written down.
        #expect(prompt.contains("roothide can rename the install root when the device is rebooted or jailbroken again"))
        #expect(prompt.contains("Never write such a path into anything that outlives this run (project files, build scripts, Makefiles, AGENTS.md or CLAUDE.md, memory, skills, package scripts, code)"))
        #expect(prompt.contains("roothide's `jbroot()`") && prompt.contains("`@PREFIX@` and `@ROOTFS@`"))
    }

    @Test
    func `the commands a build script reaches for are named, found or not`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let bin = home.home.appendingPathComponent("jb/usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("ldid").path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: bin.appendingPathComponent("ninja").path, contents: Data(), attributes: [.posixPermissions: 0o644])
        let found = EnvironmentPrompt.commandsFound(installRoot: home.home.path + "/jb")
        #expect(found.contains("ldid"))
        #expect(!found.contains("ninja"), "a file that is not executable is not a command")

        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot, installRoot: home.home.path + "/jb")
        var inputs = try EnvironmentPrompt.inputs(configuration, root: ScopedRoot(home.projectURL), device: .current)
        inputs.commandsFound = ["git", "make"]
        #expect(EnvironmentPrompt.section(inputs).contains("- Also on shell_run's PATH: git, make. Not installed: cmake, dpkg-deb, ldid, ninja, perl, python3, xcrun."))
        #expect(!EnvironmentPrompt.section(inputs).contains("dpkg-deb builds"))
        inputs.commandsFound = []
        #expect(EnvironmentPrompt.section(inputs).contains("- Also on shell_run's PATH: none of cmake, dpkg-deb, git, ldid, make, ninja, perl, python3, xcrun."))
        // A package is apelin_project_build's, a workspace's script aside.
        inputs.commandsFound = ["dpkg-deb", "git"]
        #expect(EnvironmentPrompt.section(inputs).contains(
            "- Also on shell_run's PATH: dpkg-deb, git. Not installed: cmake, ldid, make, ninja, perl, python3, xcrun. dpkg-deb builds a package only inside a workspace's declared build script, which apelin_project_build runs; never build one with it yourself.",
        ))
    }

    @Test
    func `General Chat is told the defaults, with no project of its own`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try EnvironmentContextTests.register(in: home)
        let id = UUID().uuidString
        let folder = home.dataRoot.url.appendingPathComponent("Temporary/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let identity = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        let configuration = AgentSessionConfiguration(project: identity, temporaryID: id, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let prompt = try AgentSession.systemPrompt(configuration, root: ScopedRoot(folder), skills: [])
        #expect(prompt.contains("Default, prepared."))
        #expect(!prompt.contains("This project's") && !prompt.contains("This project binds"))
        #expect(prompt.contains("IPHONEOS_DEPLOYMENT_TARGET=16.0 (Apelin's default; this chat has no project)"))
    }

    /// A toolchain an earlier version of Apelin set up (no retarget scheme
    /// recorded: scheme 2) says what it lacks, what does the same, and that
    /// its release can be set up again; one of the current scheme says none.
    @Test
    func `a toolchain an earlier version of Apelin set up says what it lacks`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try EnvironmentContextTests.register(in: home)
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let current = try AgentSession.systemPrompt(configuration, root: ScopedRoot(home.projectURL), skills: [])
        #expect(!current.contains(InstalledToolchain.earlierRetargetFacts) && !current.contains("earlier version of Apelin"))
        #expect(current.contains("never set up or import again a toolchain or SDK listed here. A project with"))

        // The record as a version before scheme 3 wrote it.
        let registry = home.dataRoot.url.appendingPathComponent("Environment/Toolchains/registry.json")
        let text = try String(contentsOf: registry, encoding: .utf8)
        let scheme = #""retargetScheme":\#(ToolchainRecord.currentRetargetScheme),"#
        #expect(text.contains(scheme))
        try text.replacingOccurrences(of: scheme, with: "").write(to: registry, atomically: true, encoding: .utf8)
        let earlier = try AgentSession.systemPrompt(configuration, root: ScopedRoot(home.projectURL), skills: [])
        #expect(earlier.contains("Default, this project's, prepared, set up by an earlier version of Apelin. Tools: "))
        #expect(earlier.contains("\n  - A toolchain marked set up by an earlier version of Apelin: it builds as before, but it lacks otool-classic and ranlib"))
        #expect(earlier.components(separatedBy: InstalledToolchain.earlierRetargetFacts).count == 2, "said once")
        #expect(earlier.contains("never set up or import again a toolchain or SDK listed here, but for a toolchain an earlier version of Apelin set up when the tools it lacks are needed."))
    }

    @Test
    func `the installed toolchains and SDKs say the user removes them in Settings`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try EnvironmentContextTests.register(in: home)
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let prompt = try AgentSession.systemPrompt(configuration, root: ScopedRoot(home.projectURL), skills: [])
        #expect(prompt.contains("- Toolchains (each registered only after its installed tools passed the self-test; the user removes one in Settings ▸ Toolchains):"))
        #expect(prompt.contains("- iPhoneOS SDKs (registered; the user removes one in Settings ▸ SDKs):"))
    }

    @Test
    func `the same environment gives the same section, whatever the order the records were written in`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try EnvironmentContextTests.register(in: home)
        let configuration = AgentSessionConfiguration(project: home.project, provider: .githubCopilot(model: "m"), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let root = try ScopedRoot(home.projectURL)
        let first = AgentSession.systemPrompt(configuration, root: root, skills: [])
        // Written again, touched later: the same records read the same.
        try EnvironmentContextTests.register(in: home)
        let second = AgentSession.systemPrompt(configuration, root: root, skills: [])
        #expect(first == second)
    }

    // MARK: Ignore rules

    @Test
    func `ignore patterns follow git's rules closely enough to cut the tree`() {
        func ignored(_ path: String, folder: Bool = false, _ text: String, base: String = "") -> Bool {
            IgnoreRules.ignores(path, isFolder: folder, [IgnoreRules(base: base, rules: IgnoreRules.parse(text))])
        }
        #expect(ignored("a.log", "*.log"))
        #expect(ignored("deep/in/a.log", "*.log"), "a pattern without a slash matches at any depth")
        #expect(!ignored("a.log", "*.log\n!a.log"), "a later negation wins")
        #expect(ignored("build", folder: true, "build/") && !ignored("build", "build/"), "a trailing slash is for folders only")
        #expect(ignored("doc/frotz", "doc/frotz") && !ignored("a/doc/frotz", "doc/frotz"), "a slash in the middle anchors")
        #expect(ignored("top", "/top") && !ignored("sub/top", "/top"), "a leading slash anchors")
        #expect(ignored("x/y/z/foo", "**/foo") && ignored("foo", "**/foo"))
        #expect(ignored("abc/x/y", "abc/**") && !ignored("abc", "abc/**"))
        #expect(ignored("a/x/y/b", "a/**/b") && ignored("a/b", "a/**/b"))
        #expect(ignored("file1.o", "file[0-9].o") && !ignored("fileA.o", "file[0-9].o"))
        #expect(ignored("fileA.o", "file[!0-9].o"))
        #expect(!ignored("#notes", "#notes") && ignored("#notes", "\\#notes"), "a comment, and an escaped #")
        #expect(ignored("Sources/gen.m", "/gen.m", base: "Sources") && !ignored("Sources/sub/gen.m", "/gen.m", base: "Sources"),
                "a nested file's anchored pattern is relative to its folder")
    }

    @Test
    func `a link is listed, never followed, and a name with a line break stays on its line`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("real/file.txt", "")
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent("loop").path, withDestinationPath: ".")
        try home.write("bad\nname", "")
        let tree = ProjectTree(root: EnvironmentContextTests.canonical(home.projectURL.path))
        #expect(tree.lines == ["bad?name", "loop@", "real/", "  file.txt"])
        #expect(!tree.truncated)
    }

    @Test
    func `folders past the depth are shown but not opened`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try home.write("a/b/c/d/e/f/g/deep.txt", "")
        let tree = ProjectTree(root: EnvironmentContextTests.canonical(home.projectURL.path))
        #expect(tree.lines == ["a/", "  b/", "    c/", "      d/", "        e/", "          f/ …"])
    }
}
