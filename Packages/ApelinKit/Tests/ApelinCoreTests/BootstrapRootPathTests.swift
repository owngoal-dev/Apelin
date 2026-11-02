@testable import ApelinCore
import Foundation
import XCTest

/// A path recorded under one roothide root is read under the root there is
/// now (issue #34: a reboot renamed the root, and every build failed).
final class BootstrapRootPathTests: XCTestCase {
    let old = "/private/var/containers/Bundle/Application/.jbroot-F1E6FD3C82204430"
    let new = "/private/var/containers/Bundle/Application/.jbroot-809D56B82B2E1CEA"

    func testRootNamesFollowLibroothidesRule() {
        XCTAssertTrue(BootstrapRootPath.isRootName(".jbroot-F1E6FD3C82204430"))
        XCTAssertTrue(BootstrapRootPath.isRootName(".jbroot-809D56B82B2E1CEA"))
        XCTAssertFalse(BootstrapRootPath.isRootName(".jbroot-F1E6FD3C82204431"))
        XCTAssertFalse(BootstrapRootPath.isRootName(".jbroot"))
        XCTAssertFalse(BootstrapRootPath.isRootName(".jbroot-test"))
    }

    func testAPathMovesToTheCurrentRoot() {
        let recorded = old + "/usr/lib/apelin/toolchains/clt-27.0-abcdef01"
        XCTAssertEqual(
            BootstrapRootPath.rebased(recorded, onto: new + "/var/mobile/Documents/wiki.qaq.apelin"),
            new + "/usr/lib/apelin/toolchains/clt-27.0-abcdef01",
        )
        XCTAssertEqual(BootstrapRootPath.rebased(old, onto: new), new)
    }

    func testOnlyTheRootsNameChangesNotTheSpelling() {
        let recorded = "/var/containers/Bundle/Application/.jbroot-F1E6FD3C82204430/usr/lib"
        XCTAssertEqual(
            BootstrapRootPath.rebased(recorded, onto: new + "/var/mobile"),
            "/var/containers/Bundle/Application/.jbroot-809D56B82B2E1CEA/usr/lib",
        )
    }

    func testTheSameRootIsLeftAsSpelt() {
        let recorded = "/var/containers/Bundle/Application/.jbroot-F1E6FD3C82204430/usr/lib"
        XCTAssertEqual(BootstrapRootPath.rebased(recorded, onto: old + "/var/mobile"), recorded)
    }

    func testThePartBelowTheRootIgnoresItsName() {
        XCTAssertEqual(BootstrapRootPath.belowRoot(old + "/etc/hosts"), "etc/hosts")
        XCTAssertEqual(BootstrapRootPath.belowRoot(new + "/etc/hosts"), "etc/hosts")
        XCTAssertEqual(BootstrapRootPath.belowRoot(old), "")
        XCTAssertNil(BootstrapRootPath.belowRoot("/var/jb/etc/hosts"))
    }

    func testRootlessPathsAreLeftAlone() {
        let recorded = "/var/jb/usr/lib/apelin/toolchains/clt-27.0-abcdef01"
        XCTAssertEqual(BootstrapRootPath.rebased(recorded, onto: new + "/var/mobile"), recorded)
        XCTAssertEqual(BootstrapRootPath.rebased(old + "/usr/lib", onto: "/var/jb"), old + "/usr/lib")
    }
}
