@testable import ApelinToolchain
import Foundation
import Testing

/// A toolchain tree as setup leaves it, carried out of an installed copy and
/// checked again where it lands.
struct ToolchainTransferTests {
    /// A tree of a reviewed release and source, so only the files can be wrong.
    private static func installedTree(at root: URL, scheme: Int = ToolchainSetup.schemeVersion) throws -> ToolchainManifest {
        let release = try #require(CommandLineToolsSupport.releases.first { !$0.sources.isEmpty })
        let (productID, digest) = try #require(release.sources.sorted { $0.key < $1.key }.first)
        let id = String(sha256(Data("\(digest):\(scheme):16.0:base".utf8)).prefix(24))
        let tool = Data("#!/bin/sh\necho ok\n".utf8)
        try directory(root.appendingPathComponent("usr/bin"))
        try directory(root.appendingPathComponent("usr/lib/swift/iphoneos"))
        try tool.write(to: root.appendingPathComponent("usr/bin/tool"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("usr/bin/tool").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("usr/bin/alias").path, withDestinationPath: "tool")
        let manifest = ToolchainManifest(
            id: id,
            source: ToolchainSource(productID: productID, version: release.version, url: URL(string: "https://example.invalid/clt.pkg")!, size: 1),
            sourceSHA256: digest,
            retargetSchemeVersion: scheme,
            minimumOS: "16.0",
            components: [.base],
            files: ["usr/bin/tool": sha256(tool)],
            links: ["usr/bin/alias": "tool"],
            stage: .packaging,
            selfTests: [],
        )
        try writeJSON(manifest, to: root.appendingPathComponent("manifest.json"))
        return manifest
    }

    private static func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-transfer-" + UUID().uuidString)
        try directory(root)
        return root
    }

    @Test func `an installed tree is copied out and accepted where it lands`() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let manifest = try Self.installedTree(at: installed)
        let copy = root.appendingPathComponent("copy")
        let exported = try ToolchainTransfer.exportCopy(installed: installed, to: copy)
        #expect(exported.id == manifest.id)
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("usr/lib/swift/iphoneos").path), "empty folders travel")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("usr/bin/alias").path) == "tool")
        let mode = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent("usr/bin/tool").path)[.posixPermissions] as? Int
        #expect(mode == 0o755)
        #expect(try ToolchainTransfer.verifyImported(copy).id == manifest.id)

        // Anything beside the manifest's files is refused.
        try Data("extra".utf8).write(to: copy.appendingPathComponent("usr/bin/extra"))
        #expect(throws: (any Error).self) { try ToolchainTransfer.verifyImported(copy) }
        try FileManager.default.removeItem(at: copy.appendingPathComponent("usr/bin/extra"))
        // And so is a file that changed.
        try Data("#!/bin/sh\nrm -rf /\n".utf8).write(to: copy.appendingPathComponent("usr/bin/tool"))
        #expect(throws: (any Error).self) { try ToolchainTransfer.verifyImported(copy) }
    }

    /// A folder the check cannot list could hold anything: the import is refused.
    @Test func `an unreadable folder is refused`() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree")
        _ = try Self.installedTree(at: tree)
        let hidden = tree.appendingPathComponent("usr/hidden")
        try directory(hidden)
        try Data("extra".utf8).write(to: hidden.appendingPathComponent("extra"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hidden.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hidden.path) }
        #expect(throws: (any Error).self) { try ToolchainTransfer.verifyImported(tree) }
    }

    @Test func `a modified installed toolchain is not exported`() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        _ = try Self.installedTree(at: installed)
        try Data("changed".utf8).write(to: installed.appendingPathComponent("usr/bin/tool"))
        #expect(throws: (any Error).self) {
            try ToolchainTransfer.exportCopy(installed: installed, to: root.appendingPathComponent("copy"))
        }
    }

    @Test func `an identity that is not setups is refused`() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let tree = root.appendingPathComponent("tree")
        let manifest = try Self.installedTree(at: tree)
        // Same files, an ID setup would never give them.
        let forged = ToolchainManifest(
            id: String(repeating: "0", count: 24), source: manifest.source, sourceSHA256: manifest.sourceSHA256,
            retargetSchemeVersion: manifest.retargetSchemeVersion, minimumOS: manifest.minimumOS,
            components: manifest.components, files: manifest.files, links: manifest.links, stage: .packaging, selfTests: [],
        )
        try writeJSON(forged, to: tree.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try ToolchainTransfer.verifyImported(tree) }
    }

    /// A tree scheme 2 made, before otool-classic and ranlib: still installed
    /// on devices, exported from them, and taken under its own ID, which is
    /// what setup gave it then.
    @Test func `an earlier schemes tree travels under its own id`() throws {
        let root = try Self.scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed")
        let manifest = try Self.installedTree(at: installed, scheme: 2)
        #expect(manifest.id != ToolchainSetup.identity(sourceSHA256: manifest.sourceSHA256, minimumOS: "16.0", components: [.base]))
        try ToolchainSetup.verify(manifest, at: installed)
        let copy = root.appendingPathComponent("copy")
        #expect(try ToolchainTransfer.exportCopy(installed: installed, to: copy).id == manifest.id)
        #expect(try ToolchainTransfer.verifyImported(copy).retargetSchemeVersion == 2)
    }

    @Test func `releases sources and schemes this apelin does not take are refused`() throws {
        let release = try #require(CommandLineToolsSupport.releases.first { !$0.sources.isEmpty })
        let (productID, digest) = try #require(release.sources.first)
        #expect(ToolchainTransfer.refusal(version: release.version, productID: productID, sourceSHA256: digest, scheme: ToolchainSetup.schemeVersion, swift: false) == nil)
        #expect(ToolchainTransfer.refusal(version: release.version, productID: productID, sourceSHA256: digest, scheme: 2, swift: false) == nil)
        #expect(ToolchainTransfer.refusal(version: release.version, productID: productID, sourceSHA256: digest, scheme: 1, swift: false) != nil)
        #expect(ToolchainTransfer.refusal(version: release.version, productID: productID, sourceSHA256: digest, scheme: ToolchainSetup.schemeVersion + 1, swift: false) != nil)
        #expect(ToolchainTransfer.refusal(version: release.version, productID: productID, sourceSHA256: String(repeating: "0", count: 64), scheme: 2, swift: false) != nil)
        #expect(ToolchainTransfer.refusal(version: "1.0", productID: productID, sourceSHA256: digest, scheme: 2, swift: false) != nil)
    }
}
