@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Skills and the system prompt")
struct SkillAndPromptTests {
    private func writeSkill(_ home: TemporaryHome, folder: String, name: String, body: String, files: [String: String] = [:]) throws {
        let directory = home.dataRoot.skills.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skill = "---\nname: \(name)\ndescription: Use for \(name) work.\n---\n\(body)\n"
        try skill.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        for (path, content) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func runner(_ home: TemporaryHome) throws -> ToolRunner {
        try ToolRunner(sessionID: UUID().uuidString, project: home.project, root: ScopedRoot(home.projectURL),
                       policy: ApprovalPolicy(mode: .confirm), backend: MockBackend(), digests: MockDigestLedger(),
                       gate: ApprovalGate { _ in }, skills: home.dataRoot.skills)
    }

    /// The repository this package sits in, for the templates the skills
    /// and the prompt name.
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap {
            if case let .text(content) = $0 {
                content.text
            } else {
                nil
            }
        }
        .joined()
    }

    @Test
    func `the prompt lists skills by name and description, never their bodies`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try writeSkill(home, folder: "theme", name: "theme-colours", body: "skill-body-marker")
        let skills = SkillCatalog.load(userDirectory: home.dataRoot.skills).skills
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: skills, mcpServers: [])
        #expect(prompt.contains("<skill name=\"theme-colours\" source=\"user\">Use for theme-colours work.</skill>"))
        #expect(prompt.contains("<skill name=\"apelin-tweak-development\">"))
        #expect(!prompt.contains("skill-body-marker"))
        #expect(!prompt.contains(BuiltInSkills.all[0].body))
        #expect(prompt.contains("call apelin_skill_read"))
        // The date and the mode on are each message's (`SystemState`).
        #expect(!prompt.contains("Current date"))
        #expect(prompt.hasSuffix("</available_skills>"))
    }

    @Test(.timeLimit(.minutes(1)))
    func `apelin_skill_read answers a body, lists and reads the skill's files, and stays in its folder`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        try writeSkill(home, folder: "theme", name: "theme-colours", body: "Use the palette.",
                       files: ["references/palette.md": "palette-marker", ".hidden/secret.md": "hidden"])
        try "outside-marker".write(to: home.dataRoot.skills.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: home.dataRoot.skills.appendingPathComponent("theme/link.md").path,
            withDestinationPath: home.dataRoot.skills.appendingPathComponent("outside.txt").path,
        )
        let runner = try runner(home)
        func call(_ arguments: JSONValue) async throws -> String {
            try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
        }

        let body = try await call(["name": "theme-colours"])
        #expect(body.contains("Use the palette."))
        #expect(body.contains("references/palette.md"))
        #expect(!body.contains(".hidden"))
        #expect(!body.contains("link.md"))
        #expect(try await call(["name": "theme-colours", "file": "references/palette.md"]) == "palette-marker")
        #expect(try await call(["name": "apelin-tweak-development"]).contains(BuiltInSkills.all[0].body))

        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "../outside.txt"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "theme-colours", "file": "link.md"]) }
        await #expect(throws: (any Error).self) { _ = try await call(["name": "apelin-tweak-development", "file": "x.md"]) }
        await #expect(throws: ToolArgumentError.self) { _ = try await call(["name": "missing"]) }
    }

    @Test(.timeLimit(.minutes(1)))
    func `an empty file reads a built-in skill's instructions, and its own files are served`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let runner = try runner(home)
        func call(_ arguments: JSONValue) async throws -> String {
            try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
        }
        #expect(try await call(["name": "apelin-tweak-development", "file": ""]).contains("# Tweak development"))
        let guide = try await call(["name": "apelin-project-description"])
        #expect(guide.contains("Files in this skill's folder (apelin_skill_read with file): apelin-project.schema.json"))
        let schema = try await call(["name": "apelin-project-description", "file": "apelin-project.schema.json"])
        #expect(schema.contains(#""title": "Apelin project description, version 1""#))
    }

    @Test
    func `the apelin-project-description skill names every member of the schema`() throws {
        let body = BuiltInSkills.projectDescription.body
        let text = try #require(BuiltInSkills.projectDescription.files["apelin-project.schema.json"])
        let schema = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let definitions = schema["$defs"] as? [String: Any] ?? [:]
        func resolved(_ node: Any?) -> [String: Any] {
            guard var node = node as? [String: Any] else { return [:] }
            if let reference = node["$ref"] as? String, let name = reference.split(separator: "/").last {
                node = definitions[String(name)] as? [String: Any] ?? [:]
            }
            return node
        }
        func members(_ node: [String: Any]) -> [String] {
            (node["properties"] as? [String: Any] ?? [:]).keys.sorted()
        }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let product = resolved(resolved(properties["products"])["items"])
        let package = resolved(properties["package"])
        let configuration = resolved(resolved(properties["configurations"])["properties"].flatMap { ($0 as? [String: Any])?["Debug"] })
        let named = members(schema) + members(product) + members(package) + members(configuration)
        #expect(named.count > 40, "the walk found the schema's members")
        for member in named {
            #expect(body.contains(member), "the guide never names \(member)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `every built-in skill is listed by name and apelin_skill_read serves its body`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skills = BuiltInSkills.all
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: skills, mcpServers: [])
        let names = Set(skills.map(\.name))
        // The device's hard-won rules each have a skill.
        for name in ["apelin-tweak-development", "apelin-bootstrap-paths", "apelin-tweak-runtime", "apelin-preference-bundle",
                     "apelin-project-description", "apelin-external-build", "apelin-packaging-and-install",
                     "apelin-package-dependencies", "apelin-crash-triage", "apelin-icli", "apelin-device-executables",
                     "apelin-package-depiction"]
        {
            #expect(names.contains(name), "no built-in skill \(name)")
            #expect(prompt.contains("<skill name=\"\(name)\">"), "the prompt does not list \(name)")
        }
        let runner = try runner(home)
        for skill in skills {
            let body = try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString,
                                                 arguments: ["name": .string(skill.name)], cancellation: nil, mcp: nil))
            #expect(body.contains(skill.body.prefix(32)), "apelin_skill_read did not serve \(skill.name)")
            #expect(!prompt.contains(skill.body), "the prompt leaked \(skill.name)'s body")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `the apelin-bootstrap-paths skill carries its C helper and apelin_skill_read serves it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-bootstrap-paths" })
        let header = try #require(skill.files["ApelinBootstrap.h"])
        // The helper is the one that builds for both bootstraps: the roothide
        // branch finds the jbroot from its own image, the rootless branch is
        // the fixed prefix.
        #expect(header.contains("ApelinBootstrapPath"))
        #expect(header.contains("APELIN_BOOTSTRAP_ROOTHIDE"))
        #expect(header.contains(".jbroot-"))
        #expect(header.contains("@\"/var/jb\""))
        // A resolved jbroot path is never written down: roothide renames it.
        #expect(skill.body.contains("## Never store a resolved path"))
        // read as words, whatever the lines' breaks
        let words = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for kept in ["`AGENTS.md` or `CLAUDE.md`, memory, skills", "`ApelinBootstrapPath(@\"/Library/…\")` at run time", "`@PREFIX@/…`, `@ROOTFS@/…`", "On rootless `/var/jb` and `/var/mobile` do not move"] {
            #expect(words.contains(kept), "the skill no longer says \(kept)")
        }
        let runner = try runner(home)
        let served = try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString,
                                               arguments: ["name": "apelin-bootstrap-paths", "file": "ApelinBootstrap.h"],
                                               cancellation: nil, mcp: nil))
        #expect(served == header)
    }

    /// A package's page in a package manager comes from the depiction its
    /// control names (issue #44). The skill is loaded on demand like the
    /// others: the prompt has its name and description, apelin_skill_read
    /// its body, and its page to start from is a file read only when asked
    /// for. That page draws in Irisin: it uses the view classes Irisin's
    /// renderer has, a tab name and a class on every tab.
    @Test(.timeLimit(.minutes(1)))
    func `the apelin-package-depiction skill is listed, read on demand, and carries a depiction to start from`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-package-depiction" })
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: BuiltInSkills.all, mcpServers: [])
        #expect(prompt.contains("<skill name=\"apelin-package-depiction\">\(skill.description)</skill>"))
        #expect(!prompt.contains("# A package's depiction"), "the body is read on demand, not listed")
        #expect(!prompt.contains("DepictionTabView"))

        let runner = try runner(home)
        func call(_ arguments: JSONValue) async throws -> String {
            try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString, arguments: arguments, cancellation: nil, mcp: nil))
        }
        let body = try await call(["name": "apelin-package-depiction"])
        #expect(body.contains("# A package's depiction"))
        for named in ["`package.depiction`", "`package.sileoDepiction`", "`Depiction`", "`SileoDepiction`",
                      "Never make one up", "apelin-package-repository"]
        {
            #expect(body.contains(named), "the skill no longer says \(named)")
        }
        #expect(body.contains("Files in this skill's folder (apelin_skill_read with file): depiction.json"))
        // the project description's guide sends the reader here
        #expect(BuiltInSkills.projectDescription.body.contains("apelin-package-depiction"))

        let served = try await call(["name": "apelin-package-depiction", "file": "depiction.json"])
        #expect(served == BuiltInSkills.sampleDepiction)
        let root = try #require(JSONSerialization.jsonObject(with: Data(served.utf8)) as? [String: Any])
        #expect(root["class"] as? String == "DepictionTabView")
        let tabs = try #require(root["tabs"] as? [[String: Any]])
        #expect(tabs.map { $0["tabname"] as? String } == ["Details", "Changelog"])
        let drawn: Set = ["DepictionHeaderView", "DepictionSubheaderView", "DepictionMarkdownView",
                          "DepictionSeparatorView", "DepictionTableTextView"]
        for tab in tabs {
            #expect(tab["class"] as? String == "DepictionStackView")
            for view in try #require(tab["views"] as? [[String: Any]]) {
                let name = try #require(view["class"] as? String)
                #expect(drawn.contains(name), "\(name) is not a view the skill names")
                #expect(body.contains("`\(name)`"))
                if name == "DepictionMarkdownView" {
                    #expect(view["markdown"] is String)
                } else if name != "DepictionSeparatorView" {
                    #expect(view["title"] is String)
                }
            }
        }
        // a changelog is a version, then its notes, newest first
        let changelog = try #require(tabs[1]["views"] as? [[String: Any]])
        #expect(changelog.map { $0["class"] as? String } == [
            "DepictionSubheaderView", "DepictionMarkdownView", "DepictionSubheaderView", "DepictionMarkdownView",
        ])
        #expect(changelog.compactMap { $0["title"] as? String } == ["1.0.1", "1.0.0"])
    }

    /// On a device, a VideoToolbox converter the agent built in shell_run
    /// failed `CVPixelBufferCreate` with -6662 until the user had it signed
    /// with the template's entitlements; unsigned, such a program exits 137.
    /// From wiki.qaq.apelin.dev.cli 0.1.1 both cli templates carry the app
    /// template's GPU classes (owner, 2026-10-29), so the skill's file is
    /// theirs key for key.
    @Test(.timeLimit(.minutes(1)))
    func `the apelin-device-executables skill carries the cli templates' entitlements, the app template's GPU classes among them`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-device-executables" })
        let file = try #require(skill.files["Tool.entitlements"])
        func plist(_ data: Data) throws -> [String: Any] {
            try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
        let entitlements = try plist(Data(file.utf8))
        let templates = Self.repository.appendingPathComponent("Extensions/Development", isDirectory: true)
        let app = try plist(Data(contentsOf: templates.appendingPathComponent(
            "wiki.qaq.apelin.dev.app/templates/uikit-objc/Packaging/App.entitlements",
        )))
        let gpuKeys = ["com.apple.security.iokit-user-client-class", "com.apple.security.exception.iokit-user-client-class"]
        for template in ["c", "objc"] {
            let tool = try plist(Data(contentsOf: templates.appendingPathComponent(
                "wiki.qaq.apelin.dev.cli/templates/\(template)/Packaging/Tool.entitlements",
            )))
            #expect(Set(entitlements.keys) == Set(tool.keys), "the keys are not the \(template) template's")
            for (key, value) in tool {
                #expect(entitlements[key] as? NSObject == value as? NSObject, "\(key) is not the \(template) template's")
            }
        }
        for key in gpuKeys {
            let classes = try #require(entitlements[key] as? [String], "\(key) is missing")
            #expect(classes == app[key] as? [String], "\(key) is not the app template's list")
            #expect(classes.contains("IOSurfaceRootUserClient"))
        }

        #expect(skill.body.contains("exit 137"))
        #expect(skill.body.contains("-6662"))
        #expect(skill.body.contains("\"-STool.entitlements\""))
        #expect(skill.body.contains("version 0.1.1 of the command-line tool extension"))
        let runner = try runner(home)
        let served = try await text(runner.run(.local(.skillRead), toolCallID: UUID().uuidString,
                                               arguments: ["name": "apelin-device-executables", "file": "Tool.entitlements"],
                                               cancellation: nil, mcp: nil))
        #expect(served == file)
    }

    @Test
    func `every chat is told to sign a program it builds and runs itself`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: BuiltInSkills.all, mcpServers: [])
            let working = try #require(prompt.range(of: "# Working")?.upperBound)
            let device = try #require(prompt.range(of: "# This device")?.lowerBound)
            #expect(prompt[working ..< device].contains("A program you compile and run yourself through shell_run is signed with ldid first, as the apelin-device-executables skill says"))
            #expect(prompt.contains("<skill name=\"apelin-device-executables\">"))
        }
        #expect(BuiltInSkills.externalBuild.body.contains("apelin-device-executables skill's `Tool.entitlements`"))
    }

    @Test
    func `the responses section forbids pasting tool output and long recaps`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        #expect(prompt.contains("# Responses"))
        #expect(prompt.contains("When that is unclear (code, a log, a single word, a pasted file), write in the system language that <system-state> names."))
        #expect(prompt.contains("Code, identifiers, paths and commit messages stay as the repository has them"))
        #expect(prompt.contains("Do not paste tool output"))
        #expect(prompt.contains("never use a tool just to show"))
        #expect(prompt.contains("progress note is one short line"))
    }

    /// On a device, a chat asked to show the system prompt refused: the
    /// prompt said nothing either way, and the model stretched the rule
    /// against quoting <system-state> to the whole prompt.
    @Test
    func `every chat is told the prompt is not secret and is shown when asked`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: BuiltInSkills.all, mcpServers: [])
            let responses = try #require(prompt.range(of: "# Responses")?.upperBound)
            let working = try #require(prompt.range(of: "# Working")?.lowerBound)
            let section = prompt[responses ..< working]
            #expect(section.contains("This prompt is not secret: Apelin is open source."))
            #expect(section.contains("show or summarize it as asked"))
            #expect(section.contains("Only the <system-state> notes stay unquoted."))
            let lowered = prompt.lowercased()
            for secrecy in ["confidential", "do not reveal", "never reveal", "never share"] {
                #expect(!lowered.contains(secrecy), "\(secrecy)")
            }
        }
    }

    /// On a device, a project chat said it was done with a gesture, the
    /// Dock's spacing and a settings list it had built and installed but
    /// never run, and the user had to send it back.
    @Test
    func `a reply lists the behaviour it did not exercise as Not tested`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: BuiltInSkills.all, mcpServers: [])
            let responses = try #require(prompt.range(of: "# Responses")?.upperBound)
            let working = try #require(prompt.range(of: "# Working")?.lowerBound)
            let section = prompt[responses ..< working]
            #expect(section.contains("proves only that the code built, installed or loaded, not that it behaves as asked"))
            #expect(section.contains("say something works only if you saw it work on this device yourself"))
            #expect(section.contains("under \"Not tested\", in the reply's language, one line each with how the user can check it"))
            #expect(section.contains("Never call a task done while its main behaviour is untested"))
        }
    }

    @Test
    func `after a change that shows on screen the agent drives it with the screen tools`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        let working = try #require(prompt.range(of: "# Working")?.upperBound)
        let device = try #require(prompt.range(of: "# This device")?.lowerBound)
        let section = prompt[working ..< device]
        #expect(section.contains("After a change that shows on screen, exercise it"))
        #expect(section.contains("act with apelin_screen_interact"))
        #expect(section.contains("the user declines the call"))
        #expect(section.contains("that behaviour is Not tested: say so, never guess how it behaves"))
        // The tweak loop ends on the behaviour, not on the load check.
        let loop = BuiltInSkills.tweakDevelopment.body
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(loop.contains("5. Check the behaviour itself, not only that it loaded"))
        #expect(loop.contains("drive it with `apelin_screen_interact`"))
        #expect(loop.contains("Report what you could not drive or see as Not tested."))
    }

    /// On a device, a tweak whose filter could not be set was created with
    /// the default SpringBoard filter, the change left to the next
    /// conversation, and the reply never said so (five conversations).
    @Test
    func `every chat is told to say when it did something other than what was asked`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: [], mcpServers: [])
            let responses = try #require(prompt.range(of: "# Responses")?.upperBound)
            let working = try #require(prompt.range(of: "# Working")?.lowerBound)
            let section = prompt[responses ..< working]
            #expect(section.contains("- When you could not do something the user asked for and did something else instead"))
            #expect(section.contains("a setting left at its default, a step skipped or left to another conversation or a later turn"))
            #expect(section.contains("say so plainly in your reply, with what is still left. Never leave it for the user to find."))
        }
    }

    /// On a device, Chinese chats got English progress notes between tool
    /// calls ("Build passed. Installing."): the rule said "Reply", and the
    /// notes took the language of the English tool results before them.
    @Test
    func `progress notes are in the user's language, in the prompt and in every message's block`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        let responses = try #require(prompt.range(of: "# Responses")?.upperBound)
        let working = try #require(prompt.range(of: "# Working")?.lowerBound)
        let section = prompt[responses ..< working]
        #expect(section.contains("- Write in the language the user writes in — your reply, every progress note between tool calls and every question you ask — even when the tool results you read are in English."))
        #expect(section.contains("- While a task runs, a progress note is one short line in the user's language"))
        let facts = try SystemState.Facts(languages: ["zh-Hans-CN"], region: "CN", date: Date(),
                                          timeZone: #require(TimeZone(identifier: "UTC")), mode: .confirm)
        #expect(SystemState.make(facts).contains("- Write to the user in the language they write in, progress notes included; when that is unclear, in Chinese"))
    }

    /// On a device, General Chat asked how to make a tweak with Apelin was
    /// answered from what the model knew of Theos: a Logos `Tweak.x` with
    /// `%hook`, and no skill read.
    @Test
    func `every chat is told an Apelin tweak is plain Objective-C and to read the skill before explaining`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let general = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        for project in [home.project, general] {
            let prompt = SystemPrompt.make(project: project, projectRoot: home.projectURL.path,
                                           skills: BuiltInSkills.all, mcpServers: [])
            let working = try #require(prompt.range(of: "# Working")?.upperBound)
            let device = try #require(prompt.range(of: "# This device")?.lowerBound)
            let section = prompt[working ..< device]
            #expect(section.contains("An Apelin tweak is plain Objective-C: hooks installed with MSHookMessageEx"))
            #expect(section.contains("There is no Logos (%hook, .x files) and no Theos here."))
            #expect(section.contains("a question included, read the matching skill with apelin_skill_read"))
        }
        // The file the prompt names is the tweak template's.
        let template = Self.repository.appendingPathComponent(
            "Extensions/Development/wiki.qaq.apelin.dev.tweak/templates/objc-hook/Sources/Tweak.m",
        )
        let source = try String(contentsOf: template, encoding: .utf8)
        #expect(source.contains("MSHookMessageEx"))
    }

    /// On a device, a pane's chat looked for PSListController.h in the
    /// extension's support folder with the file tools, was told it was
    /// outside the project, and read it through the shell instead.
    @Test
    func `the apelin-preference-bundle skill names the Preferences header where the read tools reach it`() throws {
        let skill = try #require(BuiltInSkills.all.first { $0.name == "apelin-preference-bundle" })
        let installed = "wiki.qaq.apelin.dev.preferences/support/include/Preferences/PSListController.h"
        #expect(skill.body.contains("`<install root>/usr/share/apelin/development/\(installed)`"))
        let words = skill.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(words.contains("Read it with file_read"))
        #expect(ReadOnlyRoots(installRoot: "/var/jb", dataRoot: ApelinDataRoot(home: URL(fileURLWithPath: "/var/mobile")))
            .developmentExtensions == "/var/jb/usr/share/apelin/development")
        // The extension's packager installs the repository's header there.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let header = try String(contentsOf: repository.appendingPathComponent("Extensions/Development/" + installed), encoding: .utf8)
        #expect(header.contains("@interface PSSpecifier"))
    }

    /// On a device, a conversation another one opened to deliver a tweak's
    /// packages put the .deb files together itself and left them in the
    /// project's Dist/, past Apelin's build, signing and packaging checks.
    @Test
    func `a package is apelin_project_build's in every project, and a workspace's script makes it`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        func prompt(_ buildSystem: ProjectBuildSystem) -> String {
            SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path, skills: [],
                              mcpServers: [], buildSystem: buildSystem)
        }
        for buildSystem in [ProjectBuildSystem.apelin, .external] {
            let text = prompt(buildSystem)
            let working = try #require(text.range(of: "# Working")?.upperBound)
            let device = try #require(text.range(of: "# This device")?.lowerBound)
            let section = text[working ..< device]
            #expect(section.contains("A package comes only from apelin_project_build"))
            #expect(section.contains("Never put a .deb together yourself (dpkg-deb -b, ar, tar) or copy one into the project"))
            #expect(section.contains("takes it from Distribute… in a project chat's More (…) menu"))
            // and a conversation opened for one is asked for a build
            #expect(text.contains("Ask for a package as an apelin_project_build that succeeds, never as a .deb file in the project."))
        }
        let script = "That script, run by apelin_project_build, is the one thing that makes this workspace's .deb"
        #expect(prompt(.external).contains(script))
        #expect(!prompt(.apelin).contains(script))
    }

    @Test
    func `the build tool and the packaging skills keep the package the build's`() throws {
        #expect(AgentToolName.projectBuild.summary.contains("the only way to make its package"))
        let packaging = BuiltInSkills.packagingAndInstall.body
        #expect(packaging.contains("## Where the package goes"))
        #expect(packaging.contains("never make one yourself with `dpkg-deb -b`, `ar` or `tar`"))
        #expect(packaging.contains("Distribute…"))
        #expect(BuiltInSkills.packageDependencies.body.contains("build or place a `.deb` yourself"))
        // A workspace's declared script is where dpkg-deb builds one.
        let external = BuiltInSkills.externalBuild.body
        let step = try #require(external.range(of: "4. Write exactly one `.deb` into `$APELIN_PACKAGE_DIR`"))
        let command = try #require(external.range(of: "dpkg-deb -b --root-owner-group"))
        #expect(step.upperBound <= command.lowerBound)
        for skill in BuiltInSkills.all where skill.body.contains("dpkg-deb") {
            #expect(["apelin-external-build", "apelin-packaging-and-install"].contains(skill.name), "\(skill.name) names dpkg-deb")
        }
    }

    @Test
    func `the prompt keeps apelin_notification_send for what the user would want to know while away`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        let working = try #require(prompt.range(of: "# Working")?.upperBound)
        let device = try #require(prompt.range(of: "# This device")?.lowerBound)
        let section = prompt[working ..< device]
        #expect(section.contains("tell them with apelin_notification_send"))
        #expect(section.contains("never for routine progress, instead of your reply, or to say you are done"))
    }

    /// On a device, asked why Irisin refused an upgrade, the agent ran
    /// irisin-cli's list and dry run as mobile (exit 77) and then refused to
    /// ask for root, even when the user asked it to: root was for a
    /// dependency's install alone. Root is now for any step of the user's
    /// task that needs it, said first, and a change outside the project
    /// only with the user's go-ahead for exactly it, in every mode.
    @Test
    func `root is for a step of the user's task that needs it, a change only as the user agreed`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        let rule = try #require(prompt.range(of: "- shell_run with root: true is for a step of the user's task that needs uid 0"))
        let line = prompt[rule.lowerBound...].prefix { $0 != "\n" }
        #expect(line.contains("a change it only checks with --dry-run --yes"))
        #expect(line.contains("when the user asks you to request root for a step, request it"))
        #expect(line.contains("needs the user's explicit go-ahead for exactly that in their reply, in every mode, Full included"))
        #expect(line.contains("never to get around a refusal or an approval"))
        #expect(!prompt.contains("root for nothing else"))
        #expect(AgentToolName.shellRun.summary.contains("irisin-cli's questions and --dry-run"))
        let skill = BuiltInSkills.packageDependencies.body
        let diagnosis = try #require(skill.range(of: "## Why Irisin refuses → its questions and dry runs, as root"))
        let rest = skill[diagnosis.upperBound...]
        #expect(rest.contains("`irisin-cli list` (`--upgradable`"))
        #expect(rest.contains("`--dry-run --yes`"))
        #expect(rest.contains("Never drop `--dry-run`"))
        let icli = BuiltInSkills.deviceCLI.body
        #expect(icli.contains("only with the user's explicit go-ahead for exactly\nthat command in their reply, in every mode"))
    }

    /// On a device, asked to clean up toolchains, the agent deleted their
    /// files through icli and a script the user ran, and left their folders
    /// behind; nothing had told it removal is the user's, in Settings.
    @Test
    func `the prompt leaves removing a toolchain or SDK to the user in Settings`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let prompt = SystemPrompt.make(project: home.project, projectRoot: home.projectURL.path,
                                       skills: [], mcpServers: [])
        let working = try #require(prompt.range(of: "# Working")?.upperBound)
        let device = try #require(prompt.range(of: "# This device")?.lowerBound)
        let section = prompt[working ..< device]
        #expect(section.contains("Toolchains and SDKs are removed only by the user, in Settings ▸ Toolchains or Settings ▸ SDKs"))
        #expect(section.contains("never delete their files or records with shell_run, icli or a script"))
    }

    @Test
    func `apelin_skill_read needs no approval in Confirm mode`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let verdict = try ApprovalPolicy(mode: .confirm)
            .evaluate(InvocationFacts(tool: .local(.skillRead)), root: ScopedRoot(home.projectURL))
        #expect(verdict == .allow(.preset("apelin_skill_read")))
    }

    @Test
    func `project instructions come from AGENTS.md, then CLAUDE.md, only inside the project`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let root = try ScopedRoot(home.projectURL)
        #expect(SystemPrompt.projectInstructions(in: root) == nil)

        try home.write("CLAUDE.md", "claude-marker")
        #expect(SystemPrompt.projectInstructions(in: root) == ProjectInstructions(file: "CLAUDE.md", text: "claude-marker"))
        try home.write("AGENTS.md", "  agents-marker\n")
        let instructions = try #require(SystemPrompt.projectInstructions(in: root))
        #expect(instructions == ProjectInstructions(file: "AGENTS.md", text: "agents-marker"))

        let prompt = SystemPrompt.make(project: home.project, projectRoot: root.path, skills: [],
                                       mcpServers: [], projectInstructions: instructions)
        #expect(prompt.contains("# Project instructions (AGENTS.md)"))
        #expect(prompt.contains("agents-marker"))

        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("AGENTS.md"))
        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("CLAUDE.md"))
        let outside = home.home.appendingPathComponent("outside.md")
        try "outside-marker".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home.projectURL.appendingPathComponent("AGENTS.md").path,
                                                   withDestinationPath: outside.path)
        #expect(SystemPrompt.projectInstructions(in: root) == nil)

        try FileManager.default.removeItem(at: home.projectURL.appendingPathComponent("AGENTS.md"))
        try home.write("AGENTS.md", String(repeating: "a", count: SystemPrompt.maxInstructionBytes + 10))
        #expect(SystemPrompt.projectInstructions(in: root)?.text.hasSuffix("… (truncated)") == true)
    }
}
