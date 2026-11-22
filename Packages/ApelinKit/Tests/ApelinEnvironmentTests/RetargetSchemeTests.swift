import ApelinProtocol
import ApelinToolchain
import XCTest

/// The app, the agent and the registry read a toolchain's retarget scheme
/// from ApelinProtocol, which cannot see ApelinToolchain: the two numbers
/// must be one.
final class RetargetSchemeTests: XCTestCase {
    func testTheRecordsCurrentSchemeIsTheOneSetupMakesTreesWith() {
        XCTAssertEqual(ToolchainRecord.currentRetargetScheme, ToolchainSetup.schemeVersion)
        XCTAssertTrue(ToolchainSetup.readableSchemes.contains(2), "scheme 2 trees are installed on devices")
    }
}
