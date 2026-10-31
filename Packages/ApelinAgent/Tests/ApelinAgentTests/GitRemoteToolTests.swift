@testable import ApelinAgent
import enum ApelinProtocol.AgentToolName
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// The mock host's remotes: what it was asked, recorded as `other`.
extension MockBackend {
    func gitRemoteList(_: GitRemoteListToolRequest) -> GitRemoteListToolResponse {
        calls.append(.other("gitRemoteList"))
        return GitRemoteListToolResponse(remotes: [GitRemoteToolEntry(name: "origin", url: "https://github.com/owngoal-dev/Pineora.git")])
    }

    func gitRemoteSet(_ request: GitRemoteSetToolRequest) -> GitRemoteSetToolResponse {
        calls.append(.other("gitRemoteSet \(request.name) \(request.url)"))
        return GitRemoteSetToolResponse(remote: GitRemoteToolEntry(name: request.name, url: request.url))
    }

    func gitRemoteRemove(_ request: GitRemoteRemoveToolRequest) -> GitRemoteListToolResponse {
        calls.append(.other("gitRemoteRemove \(request.name)"))
        return GitRemoteListToolResponse(remotes: [])
    }
}

@Suite("git remotes")
struct GitRemoteToolTests {
    static let tools: [AgentToolName] = [.gitRemoteList, .gitRemoteSet, .gitRemoteRemove]

    @Test
    func `the remote tools are the project's, list is a read and the others change the project`() {
        #expect(Self.tools.map(\.rawValue) == ["git_remote_list", "git_remote_set", "git_remote_remove"])
        #expect(AgentToolName.gitRemoteList.risk == .readOnly)
        #expect(AgentToolName.gitRemoteSet.risk == .writeProject)
        #expect(AgentToolName.gitRemoteRemove.risk == .writeProject)
        for tool in Self.tools {
            #expect(tool.isProjectOnly, "\(tool.rawValue)")
        }
        #expect(ApprovalPresets.default.readTools.contains(.gitRemoteList))
        #expect(AgentToolName.gitRemoteSet.summary.contains("Never repoint a remote to get around a refusal"))
    }

    @Test
    func `Strict lists, sets and removes remotes without asking`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        var asked: [ApprovalRequest] = []
        asked += try await harness.run(.gitRemoteList, [:]).1
        asked += try await harness.run(.gitRemoteSet, ["name": "origin", "url": "https://github.com/owngoal-dev/Pineora.git"]).1
        asked += try await harness.run(.gitRemoteRemove, ["name": "upstream"]).1
        #expect(asked.isEmpty)
        #expect(await harness.backend.calls == [
            .other("gitRemoteList"),
            .other("gitRemoteSet origin https://github.com/owngoal-dev/Pineora.git"),
            .other("gitRemoteRemove upstream"),
        ])
    }

    @Test
    func `an address given as a remote is told how to add it, before the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let address = "https://github.com/owngoal-dev/Pineora.git"
        for tool in [AgentToolName.gitFetch, .gitPull, .gitPush] {
            do {
                _ = try await harness.run(tool, ["remote": .string(address)])
                Issue.record("\(tool.rawValue) took an address as a remote")
            } catch let error as ToolArgumentError {
                #expect(error.message.contains("is an address, not a remote's name"), "\(tool.rawValue)")
                #expect(error.message.contains("git_remote_set"), "\(tool.rawValue)")
                #expect(!error.message.contains("no such remote"))
            }
        }
        #expect(await harness.backend.calls.isEmpty)
        #expect(await harness.events.events.isEmpty, "nothing is asked")
    }

    @Test
    func `a bad name or an address with a credential is refused before the host`() async throws {
        let harness = try DigestApprovalTests.Harness()
        defer { harness.home.remove() }
        let refused: [JSONValue] = [
            ["name": "origin", "url": "https://ada:ghp_secret@github.com/a/b.git"],
            ["name": "origin", "url": "https://github.com/a/b.git?token=ghp_secret"],
            ["name": "origin", "url": "http://github.com/a/b.git"],
            ["name": "origin", "url": "git@github.com:a/b.git"],
            ["name": "-x", "url": "https://github.com/a/b.git"],
            ["name": "../x", "url": "https://github.com/a/b.git"],
            ["name": "https://github.com/a/b.git", "url": "https://github.com/a/b.git"],
        ]
        for arguments in refused {
            await #expect(throws: ToolArgumentError.self, "\(arguments)") {
                _ = try await harness.run(.gitRemoteSet, arguments)
            }
        }
        do {
            _ = try await harness.run(.gitRemoteSet, ["name": "origin", "url": "https://ada:ghp_secret@github.com/a/b.git"])
        } catch let error as ToolArgumentError {
            #expect(!error.message.contains("ghp_secret"), "the refusal never repeats the token")
        }
        await #expect(throws: ToolArgumentError.self) { _ = try await harness.run(.gitRemoteRemove, ["name": "--all"]) }
        #expect(await harness.backend.calls.isEmpty)
    }
}
