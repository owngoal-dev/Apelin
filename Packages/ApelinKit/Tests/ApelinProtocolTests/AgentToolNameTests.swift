@testable import ApelinProtocol
import XCTest

/// The names every provider takes, and the names earlier releases recorded.
final class AgentToolNameTests: XCTestCase {
    /// OpenAI, Bedrock and Kiro take `[a-zA-Z0-9_-]{1,64}`, Anthropic and
    /// Gemini 128; `__` is how kwwk spells an MCP tool, `mcp__<server>__…`.
    func testEveryNameIsOneEveryProviderTakes() throws {
        let rule = try NSRegularExpression(pattern: "^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
        for tool in AgentToolName.allCases {
            let name = tool.rawValue
            XCTAssertLessThanOrEqual(name.count, 64, name)
            XCTAssertNotNil(rule.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), name)
            XCTAssertFalse(name.hasPrefix("mcp"), name)
        }
        XCTAssertEqual(Set(AgentToolName.allCases.map(\.rawValue)).count, AgentToolName.allCases.count)
    }

    func testAnEarlierNameMeansTheToolItNamedAndNeverATodayOne() {
        for (legacy, tool) in AgentToolName.legacyNames {
            XCTAssertNil(AgentToolName(rawValue: legacy), "\(legacy) is a current name too")
            XCTAssertEqual(AgentToolName.canonical(legacy), tool)
        }
        for tool in AgentToolName.allCases {
            XCTAssertEqual(AgentToolName.canonical(tool.rawValue), tool)
        }
        XCTAssertNil(AgentToolName.canonical("mcp__server__tool"), "an MCP tool is no tool of Apelin's")
    }

    /// The agent compacts its own conversation by this name (owner,
    /// 2026-11-21), which the context notes and the prompt spell.
    func testTheCompactionToolIsAConversationTool() {
        XCTAssertEqual(AgentToolName(rawValue: "apelin_conversation_compact"), .conversationCompact)
        XCTAssertNil(AgentToolName.legacyNames.first { $0.value == .conversationCompact }, "a new tool has no earlier name")
    }
}
