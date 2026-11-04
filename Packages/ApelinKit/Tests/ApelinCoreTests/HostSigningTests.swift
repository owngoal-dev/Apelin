@testable import ApelinCore
import Foundation
import XCTest

/// roothide Bootstrap is told from every other root by the mark it writes
/// into its own (issue #35: it runs no ad hoc signature, so Apelin's
/// toolchain was set up and then failed its self-test).
final class HostSigningTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: CanonicalPath.resolve(NSTemporaryDirectory())!, isDirectory: true)
            .appendingPathComponent("apelin-signing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// A root named as libroothide names one, holding `files`.
    private func root(_ name: String = ".jbroot-F1E6FD3C82204430", files: [String] = []) throws -> String {
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for file in files {
            FileManager.default.createFile(atPath: root.appendingPathComponent(file).path, contents: Data("1900".utf8))
        }
        return root.path
    }

    func testBootstrapsMarkMakesItBootstrap() throws {
        let marked = try root(files: [".thebootstrapped"])
        XCTAssertTrue(HostSigning.isRoothideBootstrap(installRoot: marked))
        XCTAssertEqual(HostSigning.toolchainRefusal(installRoot: marked), HostSigning.bootstrapRefusal)
        // the beta's mark, which Bootstrap renames when it starts
        let beta = try root(".jbroot-809D56B82B2E1CEA", files: [".bootstrapped"])
        XCTAssertTrue(HostSigning.isRoothideBootstrap(installRoot: beta))
    }

    func testOtherRootsAreNotBootstrap() throws {
        let others = try [
            // Dopamine-roothide's root
            root(files: [".installed_dopamine"]),
            // the mark under a root libroothide would not name one
            root("jb", files: [".thebootstrapped"]),
            root(".jbroot-F1E6FD3C82204431", files: [".thebootstrapped"]),
            // a root that is not there, and rootless's
            base.appendingPathComponent(".jbroot-809D56B82B2E1CEA").path,
            "/var/jb",
        ]
        for other in others {
            XCTAssertNil(HostSigning.toolchainRefusal(installRoot: other), other)
        }
    }

    /// Bootstrap writes its mark as a file; a folder or a link of that name
    /// is not it.
    func testOnlyAFileIsTheMark() throws {
        let folder = try root()
        try FileManager.default.createDirectory(atPath: folder + "/.thebootstrapped", withIntermediateDirectories: false)
        XCTAssertFalse(HostSigning.isRoothideBootstrap(installRoot: folder))

        let linked = try root(".jbroot-809D56B82B2E1CEA")
        let target = base.appendingPathComponent("elsewhere").path
        FileManager.default.createFile(atPath: target, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: linked + "/.thebootstrapped", withDestinationPath: target)
        XCTAssertFalse(HostSigning.isRoothideBootstrap(installRoot: linked))
    }

    /// The root is resolved first: a link to a Bootstrap root is that root.
    func testTheRootIsResolvedBeforeItsNameIsRead() throws {
        let marked = try root(files: [".thebootstrapped"])
        let link = base.appendingPathComponent("installroot").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: marked)
        XCTAssertTrue(HostSigning.isRoothideBootstrap(installRoot: link))
        XCTAssertTrue(HostSigning.isRoothideBootstrap(installRoot: marked + "/"))
    }
}
