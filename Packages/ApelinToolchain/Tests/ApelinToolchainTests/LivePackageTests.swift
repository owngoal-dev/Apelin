@testable import ApelinToolchain
import Foundation
import Testing

/// Opt-in local smoke test. Apple payloads are never committed as test fixtures.
struct LivePackageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"] != nil))
    func `extracts real apple package`() throws {
        let input = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"]))
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try PackageArchive(limits: .init()).extract(input, to: root)
        let clt = try canonical(root.appendingPathComponent("Library/Developer/CommandLineTools"))
        var closure = DependencyClosure(root: clt, components: [.base])
        let selected = try closure.select()
        #expect(selected["usr/bin/llvm-otool"] != nil)
        // What otool and `ar rcs` exec beside themselves (scheme 3).
        #expect(selected["usr/bin/otool-classic"]?.lastPathComponent == "otool-classic")
        #expect(selected["usr/bin/ranlib"]?.lastPathComponent == "libtool")
        for (relative, source) in selected where !relative.hasPrefix("usr/lib/clang/") {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            if data.count >= 4, try data.number(0, as: UInt32.self) == 0xFEED_FACF {
                print("Retargeting \(relative)")
                var image = try MachOImage(data)
                try image.retarget(minimumOS: 0x100000) { name, _ in MachOImage.flattened(name) }
                _ = try image.signed(identifier: source.lastPathComponent)
            }
        }
    }

    /// Setup, offline, from a reviewed package staged as a finished download
    /// by a setup an earlier scheme ran: its request moves to this scheme,
    /// the tree that scheme left is made again, and the new one has the
    /// siblings `otool` and `ar rcs` exec. Extracts and retargets the whole
    /// package under /private/tmp; nothing is installed or run.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"] != nil))
    func `an earlier schemes staging sets up this schemes tree`() async throws {
        let input = try URL(fileURLWithPath: #require(ProcessInfo.processInfo.environment["APELIN_TEST_PACKAGE"]))
        let digest = try digestFile(input)
        let release = try #require(CommandLineToolsSupport.releases.first { $0.sources.values.contains(digest) })
        let package = try #require(release.packages.first { $0.sha256 == digest })
        let source = try #require(package.source(version: release.version))
        let root = URL(fileURLWithPath: "/private/tmp/apelin-toolchain-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging"), output = root.appendingPathComponent("output")
        try directory(staging)
        try FileManager.default.copyItem(at: input, to: staging.appendingPathComponent("source.pkg"))
        try writeJSON(
            ResumableDownload.Receipt(source: source, validator: nil, bytes: source.size, prefixSHA256: digest),
            to: staging.appendingPathComponent("download.json"),
        )
        let earlier = ToolchainSetup.Request(source: source, components: [.base], minimumOS: "16.0", scheme: 2)
        try writeJSON(earlier, to: staging.appendingPathComponent("request.json"))
        try directory(output)
        try writeJSON(
            ToolchainManifest(
                id: ToolchainSetup.identity(sourceSHA256: digest, scheme: 2, minimumOS: "16.0", components: [.base]),
                source: source,
                sourceSHA256: digest,
                retargetSchemeVersion: 2,
                minimumOS: "16.0",
                components: [.base],
                files: ["usr/bin/clang": String(repeating: "0", count: 64)],
                stage: .packaging,
                selfTests: [],
            ),
            to: output.appendingPathComponent("manifest.json"),
        )

        let manifest = try await ToolchainSetup().run(source: source, components: [.base], staging: staging, output: output)
        #expect(manifest.retargetSchemeVersion == ToolchainSetup.schemeVersion)
        #expect(manifest.id == ToolchainSetup.identity(sourceSHA256: digest, minimumOS: "16.0", components: [.base]))
        #expect(manifest.files["usr/bin/otool-classic"] != nil)
        #expect(manifest.files["usr/bin/ranlib"] != nil)
        #expect(manifest.files["usr/bin/ranlib"] != manifest.files["usr/bin/libtool"], "each copy signed under its own name")
        #expect(try JSONDecoder().decode(
            ToolchainSetup.Request.self,
            from: Data(contentsOf: staging.appendingPathComponent("request.json")),
        ) == earlier.retargeted(ToolchainSetup.schemeVersion))
        try ToolchainSetup.verify(manifest, at: output)
    }
}
