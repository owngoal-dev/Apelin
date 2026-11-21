@testable import ApelinProtocol
import XCTest

/// The limits the user sets for a model (#68): what can be saved, what is
/// saved after a warning, what a session takes from the wire, and that a
/// caller that sends none changes nothing.
final class AgentModelLimitsTests: XCTestCase {
    func testWholeNumbersInsideTheRangesWithTheOutputBelowTheWindowAreSaved() {
        XCTAssertEqual(AgentModelLimits(contextWindow: 131_072, maxOutputTokens: 32000).problems(), [])
        XCTAssertEqual(AgentModelLimits(contextWindow: 1024).problems(), [])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 1).problems(), [])
        XCTAssertEqual(AgentModelLimits().problems(), [])
        XCTAssertTrue(AgentModelLimits().isAutomatic)
    }

    func testOutOfRangeValuesAndAnOutputThatFillsTheWindowAreRefused() {
        XCTAssertEqual(AgentModelLimits(contextWindow: 1023).problems(), [.contextWindowOutOfRange])
        XCTAssertEqual(AgentModelLimits(contextWindow: 10_000_001).problems(), [.contextWindowOutOfRange])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 0).problems(), [.maxOutputOutOfRange])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 1_000_001).problems(), [.maxOutputOutOfRange])
        XCTAssertEqual(AgentModelLimits(contextWindow: 20000, maxOutputTokens: 20000).problems(), [.outputNotBelowWindow])
        // against the automatic window when the user left it empty
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 140_000).problems(automaticWindow: 131_072), [.outputNotBelowWindow])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 140_000).problems(), [])
    }

    func testUnreasonableButPossibleCombinationsWarn() {
        XCTAssertEqual(AgentModelLimits(contextWindow: 20000).warnings(), [.smallContextWindow])
        XCTAssertEqual(AgentModelLimits(contextWindow: 64000, maxOutputTokens: 40000).warnings(), [.outputTakesMostOfWindow])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 100_000).warnings(automaticWindow: 131_072), [.outputTakesMostOfWindow])
        XCTAssertEqual(AgentModelLimits(maxOutputTokens: 512).warnings(), [.smallMaxOutput])
        XCTAssertEqual(AgentModelLimits(contextWindow: 131_072, maxOutputTokens: 32000).warnings(), [])
        // a refused output is no warning as well
        XCTAssertEqual(AgentModelLimits(contextWindow: 64000, maxOutputTokens: 64000).warnings(), [])
    }

    func testASessionTakesOnlyWhatCouldHaveBeenSaved() {
        XCTAssertEqual(
            AgentModelLimits(contextWindow: 20000, maxOutputTokens: 4096).sanitized,
            AgentModelLimits(contextWindow: 20000, maxOutputTokens: 4096),
        )
        XCTAssertEqual(AgentModelLimits(contextWindow: 12, maxOutputTokens: 4096).sanitized, AgentModelLimits(maxOutputTokens: 4096))
        XCTAssertEqual(AgentModelLimits(contextWindow: 20000, maxOutputTokens: 20000).sanitized, AgentModelLimits(contextWindow: 20000))
        XCTAssertNil(AgentModelLimits(maxOutputTokens: -5).sanitized)
        XCTAssertNil(AgentModelLimits().sanitized)
    }

    func testAnOpenOrAPromptWithoutLimitsIsAutomaticAndOneWithThemCarriesThem() throws {
        let open = try JSONDecoder().decode(AgentOpenRequest.self, from: Data(#"{"approvalMode":"relaxed"}"#.utf8))
        XCTAssertNil(open.modelLimits)
        let prompt = try JSONDecoder().decode(AgentPromptRequest.self, from: Data(#"{"sessionID":"s","text":"hi"}"#.utf8))
        XCTAssertNil(prompt.modelLimits)
        let limited = AgentPromptRequest(
            sessionID: "s",
            text: "hi",
            modelLimits: AgentModelLimits(contextWindow: 20000),
        )
        let encoded = try JSONEncoder().encode(limited)
        XCTAssertEqual(try JSONDecoder().decode(AgentPromptRequest.self, from: encoded).modelLimits, AgentModelLimits(contextWindow: 20000))
        let list = try JSONDecoder().decode(AgentModelListResponse.self, from: Data(#"{"models":["a"]}"#.utf8))
        XCTAssertNil(list.limits)
    }

    func testTheBudgetIsTheOwners() {
        XCTAssertEqual(AgentContextBudget.automaticCompaction, 0.75)
        XCTAssertEqual(AgentContextBudget.suggestions, [50, 60, 70])
        XCTAssertLessThan(AgentContextBudget.compactionFloor, AgentContextBudget.suggestions[0])
    }
}
