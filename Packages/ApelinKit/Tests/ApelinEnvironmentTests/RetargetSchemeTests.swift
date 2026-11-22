import ApelinProtocol
import ApelinToolchain
import XCTest

/// The app, the agent and the registry read a toolchain's retarget scheme,
/// and the releases that cannot be set up again, from ApelinProtocol, which
/// cannot see ApelinToolchain: the two must say the same.
final class RetargetSchemeTests: XCTestCase {
    func testTheRecordsCurrentSchemeIsTheOneSetupMakesTreesWith() {
        XCTAssertEqual(ToolchainRecord.currentRetargetScheme, ToolchainSetup.schemeVersion)
        XCTAssertTrue(ToolchainSetup.readableSchemes.contains(2), "scheme 2 trees are installed on devices")
    }

    /// A release whose every package Apple stopped serving is replaced by
    /// one it still serves, and only such a release is.
    func testTheReplacedReleasesAreTheWithdrawnOnes() {
        let offered = Set(CommandLineToolsSupport.releases.filter { $0.packages.contains { !$0.withdrawn } }.map(\.version))
        let withdrawn = Set(CommandLineToolsSupport.releases.map(\.version)).subtracting(offered)
        XCTAssertEqual(Set(ToolchainRecord.replacedReleases.keys), withdrawn)
        for replacement in ToolchainRecord.replacedReleases.values {
            XCTAssertTrue(offered.contains(replacement), "\(replacement) can be set up")
        }
    }
}
