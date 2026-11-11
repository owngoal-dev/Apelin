@testable import ApelinToolchain
import Foundation
import Testing

struct SupportTests {
    func fixture(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + path)
    }

    @Test func `compatibility covers oldest CP us without conflating OS and CPU`() throws {
        let old = try #require(CommandLineToolsSupport.release("14.2"))
        for profile in CommandLineToolsSupport.cpuProfiles {
            let fits = old.compatibility.refusal(hostVersion: "16.0", hasFeature: profile.cpuFeatures.contains) == nil
            #expect(fits == profile.cpuFeatures.contains("FEAT_LRCPC"))
        }
        // iOS 26 cannot supply an A12 with instructions it does not implement.
        let swift = try #require(CommandLineToolsSupport.release("27.0")?.swiftSupport)
        #expect(swift.refusal(hostVersion: "26.0", hasFeature: ["FEAT_LRCPC"].contains) != nil)
        #expect(old.swiftSupport?.refusal(hostVersion: "16.0", hasFeature: { _ in true })?.contains("not been verified") == true)
    }

    @Test func `recommendations are reviewed inputs and product I ds are explicit`() throws {
        var products = Set<String>()
        for release in CommandLineToolsSupport.releases {
            #expect(release.reads(sdkVersion: release.recommendedSDK))
            #expect(release.verifiedSDKs.contains(release.recommendedSDK))
            #expect(!release.sourceProductIDs.isEmpty)
            for id in release.sourceProductIDs {
                #expect(products.insert(id).inserted)
                #expect(release.sources[id]?.count == 64)
                #expect(CommandLineToolsSupport.refusal(for: release.version, productID: id) == nil)
            }
            #expect(CommandLineToolsSupport.refusal(for: release.version, productID: "new-product") != nil)
            let encoded = try JSONEncoder().encode(release.compatibility)
            #expect(try JSONDecoder().decode(ReleaseCompatibility.self, from: encoded) == release.compatibility)
        }
    }

    @Test func `release requirements match the reviewed static inventories`() throws {
        struct Audit: Decodable {
            struct Product: Decodable {
                let version: String
                let sourceSHA256: String
                let selectedFeatureInstructions: [String: Int]
                let baseLibcxxSymbols: [String]
                let unsupportedInstructions: [String: [String: Int]]
            }

            let products: [String: Product]
        }
        let audit = try JSONDecoder().decode(Audit.self, from: Data(contentsOf: fixture("compatibility-audit.json")))
        for release in CommandLineToolsSupport.releases {
            var features = Set<String>()
            for (id, digest) in release.sources {
                let product = try #require(audit.products[id])
                #expect(product.version == release.version)
                #expect(product.sourceSHA256 == digest)
                #expect(Set(product.baseLibcxxSymbols) == Set(release.requiredLibcxxSymbols))
                #expect(product.unsupportedInstructions["apple-a13"]?.isEmpty == true)
                features.formUnion(product.selectedFeatureInstructions.keys.map { "FEAT_" + $0.split(separator: ":")[0] })
            }
            #expect(features == Set(release.staticInstructionFeatures))
            // A missing SHA3 requirement is justified only by the inventory
            // containing no such instruction anywhere in the host closure.
            if release.clangModuleCPUFeatures.isEmpty {
                #expect(!features.contains("FEAT_SHA3"))
            }
        }
    }

    @Test func `old swift manifests still decode`() throws {
        let data = Data(#"{"version":"5.7.2","minimumHost":"17.3.1","cpuFeatures":["FEAT_LRCPC"]}"#.utf8)
        let requirements = try JSONDecoder().decode(SwiftToolchainSupport.self, from: data)
        #expect(requirements.minimumHostBasis == "verified-policy")
        #expect(requirements.verifiedHosts.isEmpty)
    }

    @Test func `newer base tools check the actual runtime instead of guessing an OS version`() throws {
        for version in ["16.4", "27.0", "27.2"] {
            let compatibility = try #require(CommandLineToolsSupport.release(version)?.compatibility)
            #expect(compatibility.refusal(hostVersion: "16.2", hasFeature: { _ in true }, hasLibcxxSymbol: { _ in false })?.contains("C++ runtime") == true)
            #expect(compatibility.refusal(hostVersion: "16.2", hasFeature: { _ in true }, hasLibcxxSymbol: { _ in true }) == nil)
        }
        let older = try #require(CommandLineToolsSupport.release("15.3")?.compatibility)
        #expect(older.refusal(hostVersion: "16.2", hasFeature: { _ in true }, hasLibcxxSymbol: { _ in false }) == nil)
    }

    /// The owner's set (2026-10-21, 27.2 since 2026-11-06): 27.2, 27.0, 16.4, 15.3, 15.0 and 14.2. The
    /// dropped releases are still in Apple's catalog and are refused by name,
    /// with the reason, before anything downloads.
    @Test func `only the kept releases are set up`() throws {
        #expect(CommandLineToolsSupport.releases.map(\.version) == ["27.2", "27.0", "16.4", "15.3", "15.0", "14.2"])
        for version in ["16.2", "14.3", "13.4", "13.2", "12.5", "12.4"] {
            #expect(CommandLineToolsSupport.release(version) == nil)
            let message = try #require(CommandLineToolsSupport.refusal(for: version, productID: "072-44426"))
            #expect(message.contains("Command Line Tools \(version) cannot be set up"))
            #expect(message.contains("Pick one of 27.2, 27.0, 16.4, 15.3, 15.0, 14.2."))
        }
    }

    @Test func `reviewed releases have no refusal`() {
        for release in CommandLineToolsSupport.releases {
            #expect(CommandLineToolsSupport.refusal(for: release.version) == nil)
            #expect(CommandLineToolsSupport.release(release.version) == release)
            for library in release.weakSystemLibraries {
                #expect(CommandLineToolsSupport.weakSystemLibraryReasons[library] != nil)
            }
        }
    }

    @Test(arguments: [
        ("14.2", "17.3.1", ["FEAT_LRCPC"], true),
        ("14.2", "17.3.0", ["FEAT_LRCPC"], false),
        ("15.0", "17.3.1", ["FEAT_LRCPC"], true),
        ("15.3", "17.3.1", ["FEAT_LRCPC"], true),
        ("15.3", "17.3.0", ["FEAT_LRCPC"], false),
        ("15.0", "26.0.1", [], false),
        ("15.0", "17.3.1", ["FEAT_LRCPC", "FEAT_SHA3"], true),
        ("27.0", "17.3.1", ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], false),
        ("27.0", "26.0.1", ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], true),
        ("27.2", "17.3.1", ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], false),
        ("27.2", "26.0.1", ["FEAT_LRCPC", "FEAT_SHA3"], false),
        ("27.2", "26.0.1", ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"], true),
    ])
    func `swift requirements follow the release`(version: String, host: String, features: [String], allowed: Bool) throws {
        let support = try #require(CommandLineToolsSupport.release(version)?.swiftSupport)
        #expect((support.refusal(hostVersion: host, hasFeature: features.contains) == nil) == allowed)
    }

    @Test func `unreviewed versions are refused by name`() throws {
        let message = try #require(CommandLineToolsSupport.refusal(for: "9.9"))
        #expect(message.contains("Command Line Tools 9.9"))
        #expect(message.contains("27.0"))
        let unknown = try #require(CommandLineToolsSupport.refusal(for: "unknown"))
        #expect(unknown.contains("does not say which version"))
    }

    @Test func `refused versions say why`() throws {
        for (version, reason) in CommandLineToolsSupport.refused {
            let message = try #require(CommandLineToolsSupport.refusal(for: version))
            #expect(message.contains(version))
            #expect(message.contains(reason))
        }
    }

    @Test func `sdk reading follows major minor`() {
        let release = CommandLineToolsRelease(version: "99.0", newestSDK: "18.2", weakSystemLibraries: [])
        #expect(release.reads(sdkVersion: "18.2"))
        #expect(release.reads(sdkVersion: "18.2.1"))
        #expect(release.reads(sdkVersion: "17.4"))
        #expect(release.reads(sdkVersion: "18"))
        #expect(!release.reads(sdkVersion: "18.5"))
        #expect(!release.reads(sdkVersion: "27.0"))
    }

    /// CLT 13–15's dsymutil copies __eh_frame into the dSYM: its __TEXT then has
    /// file bytes, and the segment's other sections stay virtual at offset 0.
    @Test func `dsym with copied eh frame keeps virtual sections`() throws {
        let command = 72 + 2 * 80
        var data = Data(count: 32 + command + 8)
        data.put(UInt32(0xFEED_FACF), at: 0)
        data.put(UInt32(0x100000C), at: 4)
        data.put(UInt32(10), at: 12)
        data.put(UInt32(1), at: 16)
        data.put(UInt32(command), at: 20)
        data.put(UInt32(0x19), at: 32)
        data.put(UInt32(command), at: 36)
        data.put(UInt64(32 + command), at: 32 + 40)
        data.put(UInt64(8), at: 32 + 48)
        data.put(UInt32(2), at: 32 + 64)
        data.put(UInt64(0x25E8), at: 32 + 72 + 40) // __text: virtual
        data.put(UInt64(8), at: 32 + 152 + 40) // __eh_frame: copied
        data.put(UInt32(32 + command), at: 32 + 152 + 48)
        _ = try MachOImage(data, allowDSYM: true)
        data.put(UInt32(2), at: 12)
        #expect(throws: (any Error).self) { try MachOImage(data) }
    }

    /// A dylib image with two loads and one LC_DYLD_CHAINED_FIXUPS whose imports
    /// (format 1) name `names` from library ordinals `ordinals`.
    func chainedImage(_ names: [String], ordinals: [UInt32], shareSuffix: Bool = false) -> Data {
        var pool = Data([0])
        var offsets: [UInt32] = []
        for name in names {
            offsets.append(UInt32(pool.count)); pool.append(contentsOf: name.utf8); pool.append(0)
        }
        if shareSuffix, let last = offsets.last {
            offsets.append(last + 1)
        } // "<name minus first byte>"
        var blob = Data(count: 28)
        blob.put(UInt32(28), at: 8) // imports
        blob.put(UInt32(28 + 4 * offsets.count), at: 12) // symbols
        blob.put(UInt32(offsets.count), at: 16)
        blob.put(UInt32(1), at: 20)
        for (index, offset) in offsets.enumerated() {
            var entry = Data(count: 4)
            entry.put((offset << 9) | (ordinals[min(index, ordinals.count - 1)] & 0xFF), at: 0)
            blob.append(entry)
        }
        blob.append(pool)
        blob.append(Data(count: (8 - blob.count % 8) % 8))
        func load(_ name: String) -> Data {
            var command = Data(count: 24); command.put(UInt32(0xC), at: 0); command.put(UInt32(24), at: 8)
            command.append(contentsOf: name.utf8); command.append(0)
            command.append(Data(count: (8 - command.count % 8) % 8)); command.put(UInt32(command.count), at: 4)
            return command
        }
        let loads = load("/usr/lib/libone.dylib") + load("/usr/lib/libtwo.dylib")
        let commandsSize = loads.count + 16
        var data = Data(count: 32)
        data.put(UInt32(0xFEED_FACF), at: 0); data.put(UInt32(0x100000C), at: 4); data.put(UInt32(6), at: 12)
        data.put(UInt32(3), at: 16); data.put(UInt32(commandsSize), at: 20)
        var fixups = Data(count: 16)
        fixups.put(UInt32(0x8000_0034), at: 0); fixups.put(UInt32(16), at: 4)
        fixups.put(UInt32(32 + commandsSize), at: 8); fixups.put(UInt32(blob.count), at: 12)
        return data + loads + fixups + blob
    }

    func importNames(_ image: MachOImage) throws -> [(name: String, ordinal: UInt32, weak: Bool)] {
        let command = try #require(image.commands.first { $0.kind == 0x8000_0034 })
        let offset = try Int(command.bytes.number(8, as: UInt32.self))
        let count = try Int(image.bytes.number(offset + 16, as: UInt32.self))
        let pool = try offset + Int(image.bytes.number(offset + 12, as: UInt32.self))
        return try (0 ..< count).map { index in
            let value = try image.bytes.number(offset + 28 + 4 * index, as: UInt32.self)
            let name = try image.bytes.cString(pool + Int(value >> 9) ..< image.bytes.count)
            return (name, value & 0xFF, value & 0x100 != 0)
        }
    }

    @Test func `renamed import keeps its ordinal and pool`() throws {
        var image = try MachOImage(chainedImage(["_long_old_name", "_other"], ordinals: [1, 2]))
        #expect(try image.renameImports(["_long_old_name": "_short"]) == ["_long_old_name"])
        let names = try importNames(image)
        #expect(names.map(\.name) == ["_short", "_other"])
        #expect(names.map(\.ordinal) == [1, 2])
        #expect(try image.renameImports(["_absent": "_x"]).isEmpty)
    }

    @Test func `renaming refuses longer or shared names`() throws {
        var longer = try MachOImage(chainedImage(["_a"], ordinals: [1]))
        #expect(throws: (any Error).self) { try longer.renameImports(["_a": "_longer"]) }
        var shared = try MachOImage(chainedImage(["_name"], ordinals: [1], shareSuffix: true))
        #expect(throws: (any Error).self) { try shared.renameImports(["_name": "_n"]) }
        // The shorter name is the longer one's tail: rewriting it would rewrite both.
        var tail = try MachOImage(chainedImage(["_name"], ordinals: [1], shareSuffix: true))
        #expect(throws: (any Error).self) { try tail.renameImports(["name": "nam"]) }
    }

    /// An arm64 dylib image with only these loads and run paths.
    func image(loading loads: [String] = [], rpaths: [String] = []) -> Data {
        func command(_ kind: UInt32, header: Int, _ name: String) -> Data {
            var command = Data(count: header); command.put(kind, at: 0); command.put(UInt32(header), at: 8)
            command.append(contentsOf: name.utf8); command.append(0)
            command.append(Data(count: (8 - command.count % 8) % 8)); command.put(UInt32(command.count), at: 4)
            return command
        }
        let commands = loads.map { command(0xC, header: 24, $0) } + rpaths.map { command(0x8000_001C, header: 12, $0) }
        let all = commands.reduce(Data(), +)
        var data = Data(count: 32)
        data.put(UInt32(0xFEED_FACF), at: 0); data.put(UInt32(0x100000C), at: 4); data.put(UInt32(6), at: 12)
        data.put(UInt32(commands.count), at: 16); data.put(UInt32(all.count), at: 20)
        return data + all
    }

    /// libL is loaded by two tools with different run paths, and its libM is
    /// found through the second tool's only after the first's pass went by:
    /// the retarget resolves libM there, so select must have taken that file.
    @Test func `run paths a later loader passes on reach libraries already selected`() throws {
        let scratch = URL(fileURLWithPath: "/private/tmp/apelin-closure-test-" + UUID().uuidString)
        try directory(scratch); defer { try? FileManager.default.removeItem(at: scratch) }
        let root = try canonical(scratch)
        let files: [String: Data] = Dictionary(uniqueKeysWithValues: DependencyClosure.entryTools.map {
            ("usr/bin/" + $0, image())
        }).merging([
            // ld goes through its dependencies before clang does (the stack's last entry first).
            "usr/bin/ld": image(loading: ["@rpath/libL.dylib"], rpaths: ["@loader_path/../a"]),
            "usr/bin/clang": image(loading: ["@rpath/libL.dylib"], rpaths: ["@loader_path/../b"]),
            "usr/lib/libL.dylib": image(loading: ["@rpath/libM.dylib"]),
            "usr/lib/libM.dylib": image(),
            "usr/b/libM.dylib": image(),
        ]) { _, new in new }
        for (relative, data) in files {
            let url = root.appendingPathComponent(relative)
            try directory(url.deletingLastPathComponent())
            try data.write(to: url)
        }
        var closure = DependencyClosure(root: root, components: [.base])
        let selected = try closure.select()
        let resolved = try closure.resolve("@rpath/libM.dylib", loader: "usr/lib/libL.dylib", rpaths: [])
        #expect(resolved == "usr/b/libM.dylib")
        #expect(selected["usr/b/libM.dylib"] != nil)
    }

    @Test func `weakened load marks its chained imports weak`() throws {
        var image = try MachOImage(chainedImage(["_from_one", "_from_two"], ordinals: [1, 2]))
        #expect(try image.weakenLoads(of: ["/usr/lib/libtwo.dylib"]) == ["/usr/lib/libtwo.dylib"])
        let names = try importNames(image)
        #expect(names.map(\.weak) == [false, true])
        #expect(image.commands.filter { $0.kind == 0x8000_0018 }.count == 1)
    }

    @Test func `swift links resolve inside the tree`() {
        #expect(DependencyClosure.lexicallyResolved("swift-frontend", from: "usr/bin/swiftc") == "usr/bin/swift-frontend")
        #expect(DependencyClosure.lexicallyResolved("../clang/21", from: "usr/lib/swift/clang") == "usr/lib/clang/21")
        #expect(DependencyClosure.lexicallyResolved("/usr/bin/swift-frontend", from: "usr/bin/swiftc") == nil)
        #expect(DependencyClosure.lexicallyResolved("../../../../x", from: "usr/bin/swiftc") == nil)
    }

    @Test func `swift is reviewed for known releases`() {
        #expect(CommandLineToolsSupport.releases.filter(\.swift).map(\.version) == ["27.2", "27.0", "15.3", "15.0", "14.2"])
        // 16.4 ships Swift 6.1.2 and says why it does not offer it.
        #expect(CommandLineToolsSupport.release("16.4")?.swiftUnavailable?.contains("iOS 26") == true)
        for (old, new) in CommandLineToolsSupport.swiftImportRenames {
            #expect(new.utf8.count <= old.utf8.count)
        }
    }

    @Test func `weakened load survives signing`() throws {
        var image = try MachOImage(Data(contentsOf: fixture("input/FixtureBundle")))
        #expect(try image.weakenLoads(of: ["/usr/lib/libmissing.dylib"]).isEmpty)
        #expect(try image.weakenLoads(of: ["/var/jb/usr/lib/libfixturedep.dylib"]) == ["/var/jb/usr/lib/libfixturedep.dylib"])
        try image.retarget(minimumOS: 0x100000) { name, _ in name }
        let reread = try MachOImage(image.signed(identifier: "FixtureBundle"))
        let kinds = try Dictionary(uniqueKeysWithValues: reread.commands
            .filter { [0xC, 0x8000_0018].contains($0.kind) }
            .map { try (MachOImage.name($0), $0.kind) })
        #expect(kinds["/var/jb/usr/lib/libfixturedep.dylib"] == 0x8000_0018)
        #expect(kinds["/usr/lib/libSystem.B.dylib"] == 0xC)
    }
}

/// A reviewed release stays reachable when Apple's catalog stops naming it,
/// as 27.0 did once 27.2 came out, while the file was still being served.
struct ReviewedPackageTests {
    private func listed(_ productID: String, _ version: String) throws -> ToolchainSource {
        try ToolchainSource(
            productID: productID,
            version: version,
            url: #require(URL(string: "https://swcdn.apple.com/catalog/\(productID)/CLTools_Executables.pkg")),
            size: 1,
        )
    }

    @Test func `every reviewed release knows where its package is`() throws {
        for release in CommandLineToolsSupport.releases {
            #expect(!release.packages.isEmpty, "\(release.version) has no package")
            for package in release.packages {
                let source = try #require(package.source(version: release.version))
                #expect(source.url.scheme == "https")
                #expect(source.url.host?.hasSuffix(".apple.com") == true)
                #expect(source.url.path.hasSuffix("/CLTools_Executables.pkg"))
                #expect(source.url.path.contains(package.productID))
                #expect(source.size > 0)
                #expect(package.sha256.count == 64)
                #expect(package.upstreamDigest.count == 40)
                #expect(source.upstreamDigestAlgorithm == "xar-toc-sha1")
                #expect(release.sources[package.productID] == package.sha256)
            }
        }
    }

    @Test func `a release Apple stopped listing is still offered`() throws {
        let newer = try listed("199-00000", "27.3")
        let catalog = try CommandLineToolsSupport.catalog(adding: [listed("082-41241", "16.4"), newer])
        #expect(catalog.map(\.version) == ["27.3", "27.2", "27.0", "16.4", "15.3", "15.0", "14.2"])
        let kept = try #require(catalog.first { $0.productID == "082-83364" })
        #expect(kept.url.absoluteString.hasPrefix("https://swcdn.apple.com/content/downloads/58/48/082-83364-"))
        #expect(CommandLineToolsSupport.refusal(for: kept.version, productID: kept.productID) == nil)
        #expect(CommandLineToolsSupport.refusal(for: newer.version, productID: newer.productID) != nil)
    }

    @Test func `the catalog's own address wins`() throws {
        let moved = try listed("082-83364", "27.0")
        let catalog = CommandLineToolsSupport.catalog(adding: [moved])
        #expect(catalog.count(where: { $0.productID == moved.productID }) == 1)
        #expect(catalog.first { $0.productID == moved.productID } == moved)
    }

    @Test func `a package that names no version sorts last`() throws {
        let unknown = try listed("001-00000", CommandLineToolsSupport.unknownVersion)
        #expect(CommandLineToolsSupport.catalog(adding: [unknown]).last == unknown)
    }
}
