import Darwin
import Foundation

/// The reviewed host requirements of one Swift compiler release.
public struct SwiftToolchainSupport: Codable, Sendable, Equatable {
    public let version: String
    public let minimumHost: String
    public let cpuFeatures: [String]
    public let minimumHostBasis: String
    public let verifiedHosts: [String]

    private enum CodingKeys: String, CodingKey {
        case version, minimumHost, cpuFeatures, minimumHostBasis, verifiedHosts
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(String.self, forKey: .version)
        minimumHost = try values.decode(String.self, forKey: .minimumHost)
        cpuFeatures = try values.decode([String].self, forKey: .cpuFeatures)
        minimumHostBasis = try values.decodeIfPresent(String.self, forKey: .minimumHostBasis) ?? "verified-policy"
        verifiedHosts = try values.decodeIfPresent([String].self, forKey: .verifiedHosts) ?? []
    }

    public init(
        version: String,
        minimumHost: String,
        cpuFeatures: [String],
        minimumHostBasis: String = "verified-policy",
        verifiedHosts: [String] = [],
    ) {
        self.version = version
        self.minimumHost = minimumHost
        self.cpuFeatures = cpuFeatures
        self.minimumHostBasis = minimumHostBasis
        self.verifiedHosts = verifiedHosts
    }

    public func refusal(hostVersion: String, hasFeature: (String) -> Bool) -> String? {
        if hostVersion.compare(minimumHost, options: .numeric) == .orderedAscending {
            return minimumHostBasis == "verified-policy"
                ? "Swift \(version) is supported on iOS \(minimumHost) or later; earlier hosts have not been verified."
                : "Swift \(version) requires iOS \(minimumHost) or later on this device."
        }
        let missing = cpuFeatures.filter { !hasFeature($0) }
        return missing.isEmpty ? nil : "Swift \(version) requires CPU features this device lacks: " + missing
            .joined(separator: ", ") + "."
    }

    public var hostRefusal: String? {
        #if os(iOS)
            return refusal(hostVersion: hostOSVersion, hasFeature: hostHasCPUFeature)
        #else
            return nil
        #endif
    }
}

/// One package as it was reviewed: the bytes setup accepts and where Apple
/// serves them. Apple's catalog names only what it offers today (it replaced
/// 27.0 with 27.2 in 2026-11 and went on serving 27.0's file), so a reviewed
/// release takes its address from here when the catalog no longer lists it.
public struct CommandLineToolsPackage: Sendable, Equatable {
    public let productID: String
    /// SHA-256 of the whole package. Setup refuses any other bytes.
    public let sha256: String
    let url: String
    let size: Int64
    /// SHA-1 of the package's table of contents, which Apple's catalog
    /// calls its digest.
    let upstreamDigest: String

    /// The package as a catalog entry.
    func source(version: String) -> ToolchainSource? {
        URL(string: url).map {
            ToolchainSource(
                productID: productID,
                version: version,
                url: $0,
                size: size,
                upstreamDigest: upstreamDigest,
                upstreamDigestAlgorithm: "xar-toc-sha1",
            )
        }
    }
}

/// One Command Line Tools release the retarget was reviewed against: its package
/// layout, what its tools load, and the SDKs its linker reads. A release is listed
/// here only after its setup and the C, C++ and Objective-C self-test passed on a
/// device; every other version is refused with the reason `refusal(for:)` gives.
public struct CommandLineToolsRelease: Sendable, Equatable {
    /// The CLT version as Apple's catalog names it, `16.4`.
    public let version: String
    /// The iPhoneOS SDK the matching Xcode shipped with, `18.5`. The release's
    /// linker and headers read that SDK and older ones; a newer SDK can use a
    /// text-stub architecture (`arm64e.x1`) or headers its tools do not know.
    /// A major alone (`27`) takes that major's point releases too, once one
    /// passed the self-test.
    public let newestSDK: String
    /// macOS system libraries the tools load that iOS does not have, each
    /// loaded weakly. Only a path Apelin never takes calls into them; see
    /// `CommandLineToolsSupport.weakSystemLibraryReasons`.
    public let weakSystemLibraries: Set<String>
    /// Whether its Swift tools were reviewed and passed the Swift self-test.
    public let swiftSupport: SwiftToolchainSupport?
    /// Why a release that ships Swift does not offer it, in a sentence a
    /// user reads; nil when it offers Swift or nobody has looked yet.
    public let swiftUnavailable: String?
    public var swift: Bool {
        swiftSupport != nil
    }

    /// Imports its Swift tools make that iOS does not export, each bound to the
    /// symbol that answers instead; empty for most releases.
    let swiftImportRenames: [String: String]
    public let clangModuleCPUFeatures: [String]
    public let recommendedSDK: String
    public let verifiedSDKs: [String]
    /// The SDKs its Swift self-test passed against; none without Swift.
    let verifiedSwiftSDKs: [String]
    public let packages: [CommandLineToolsPackage]
    /// Each reviewed package's SHA-256, by product.
    public var sources: [String: String] {
        Dictionary(uniqueKeysWithValues: packages.map { ($0.productID, $0.sha256) })
    }

    public var sourceProductIDs: [String] {
        sources.keys.sorted()
    }

    public let staticInstructionFeatures: [String]
    public let requiredLibcxxSymbols: [String]
    public var systemSymbolSDK: String?
    public var systemSymbolCount: Int?

    public init(
        version: String,
        newestSDK: String,
        weakSystemLibraries: Set<String> = [],
        swift: SwiftToolchainSupport? = nil,
        swiftUnavailable: String? = nil,
        swiftImportRenames: [String: String] = [:],
        clangModuleCPUFeatures: [String] = ["FEAT_SHA3"],
        recommendedSDK: String? = nil,
        verifiedSDKs: [String] = [],
        verifiedSwiftSDKs: [String]? = nil,
        packages: [CommandLineToolsPackage] = [],
        staticInstructionFeatures: [String] = [],
        requiredLibcxxSymbols: [String] = [],
        systemSymbolSDK: String? = nil,
        systemSymbolCount: Int? = nil,
    ) {
        self.version = version
        self.newestSDK = newestSDK
        self.weakSystemLibraries = weakSystemLibraries
        swiftSupport = swift
        self.swiftUnavailable = swiftUnavailable
        self.swiftImportRenames = swiftImportRenames
        self.clangModuleCPUFeatures = clangModuleCPUFeatures
        self.recommendedSDK = recommendedSDK ?? newestSDK
        self.verifiedSDKs = verifiedSDKs
        self.verifiedSwiftSDKs = swift == nil ? [] : verifiedSwiftSDKs ?? [self.recommendedSDK]
        self.packages = packages
        self.staticInstructionFeatures = staticInstructionFeatures
        self.requiredLibcxxSymbols = requiredLibcxxSymbols
        self.systemSymbolSDK = systemSymbolSDK
        self.systemSymbolCount = systemSymbolCount
    }

    /// Whether the release's tools read an SDK of this version: its major.minor
    /// is no newer than `newestSDK`'s, or its major no newer than a major
    /// alone.
    public func reads(sdkVersion: String) -> Bool {
        let sdk = CommandLineToolsSupport.majorMinor(sdkVersion)
        guard newestSDK.contains(".") else { return sdk[0] <= CommandLineToolsSupport.majorMinor(newestSDK)[0] }
        let newest = CommandLineToolsSupport.majorMinor(newestSDK)
        return sdk == newest || sdk.lexicographicallyPrecedes(newest)
    }
}

public enum CommandLineToolsSupport {
    static let libxar = "/usr/lib/libxar.1.dylib"
    static let libcodedirectory = "/usr/lib/libcodedirectory.dylib"

    /// Why a library may be loaded weakly: what in the tools calls it, and why
    /// Apelin never asks for that.
    public static let weakSystemLibraryReasons: [String: String] = [
        libxar: "ld64 reads and writes bitcode bundles with libxar; Apelin never embeds or links bitcode",
        libcodedirectory: "ld writes a linker ad-hoc signature with libcodedirectory, which it does for macOS "
            + "and simulator outputs or when asked with -adhoc_codesign; Apelin links for iOS devices, never asks, "
            + "and signs with ApelinCodeSign",
    ]

    /// Imports the Swift tools make that iOS's Swift runtime does not export,
    /// each bound instead to the iOS symbol that answers the same question.
    ///
    /// `_stdlib_isOSVersionAtLeastOrVariantVersion(major, minor, patch, variant…)`
    /// is macOS's zippered `#available` check: a macOS process compares the
    /// first triple, a macOS version, against the running system. iOS exports
    /// `_stdlib_isOSVersionAtLeast(major, minor, patch)`; called with the same
    /// registers it reads the first three and compares that triple against
    /// the running iOS. From iOS 26 the numbering is shared (macOS 26.x is
    /// iOS 26.x), and every macOS version before 26 is older than any iOS 26
    /// on both scales, so the answer is the same for every argument on an
    /// iOS 26 or later host. Only CLT 27.0 and 27.2 use this rename.
    public static let swiftImportRenames: [String: String] = [
        "_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF":
            "_$ss26_stdlib_isOSVersionAtLeastyBi1_Bw_BwBwtF",
    ]

    /// The reviewed releases, newest first.
    /// See `Documents/Research/2026-10-17-Toolchain-Retarget.md` ▸ Other releases.
    public static let releases: [CommandLineToolsRelease] = [
        .init(
            version: "27.2",
            newestSDK: "27",
            swift: .init(
                version: "6.4.2",
                minimumHost: "26.0",
                cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
                minimumHostBasis: "runtime-semantics",
                verifiedHosts: ["26.4", "27.0.1"],
            ),
            swiftImportRenames: swiftImportRenames,
            recommendedSDK: "27.0",
            verifiedSDKs: ["26.4", "27.0", "27.1"],
            verifiedSwiftSDKs: ["27.0", "27.1"],
            packages: [.init(
                productID: "142-50405",
                sha256: "fd76ca5e74717a4640c38422199216a1b6c60f7bf740c19254afdf793d3f4a47",
                url: "https://swcdn.apple.com/content/downloads/53/49/142-50405-A_WOBLDDXP4W/wk3d2yw94ir1jieuddcu9b9tffxrb09bq8/CLTools_Executables.pkg",
                size: 351_228_115,
                upstreamDigest: "3c54411a49b25492e548c7778deaf32846ebac47",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
            requiredLibcxxSymbols: ["_ZNSt3__122__libcpp_verbose_abortEPKcz"],
        ),
        .init(
            version: "27.0",
            newestSDK: "27",
            swift: .init(
                version: "6.4",
                minimumHost: "26.0",
                cpuFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
                minimumHostBasis: "runtime-semantics",
                verifiedHosts: ["26.6.2", "27.0.1"],
            ),
            swiftImportRenames: swiftImportRenames,
            recommendedSDK: "27.0",
            verifiedSDKs: ["18.6", "26.0", "26.1", "26.2", "26.4", "26.5", "27.0", "27.1"],
            verifiedSwiftSDKs: ["27.0", "27.1"],
            packages: [.init(
                productID: "082-83364",
                sha256: "d1a517e663d7ba169296683255bcf5b498802b843603cee40ec4b6fb7c991bea",
                url: "https://swcdn.apple.com/content/downloads/58/48/082-83364-A_KCEBOO2NJS/0d2rj4y5ucjlkgcvqt6f6a4pergug5tu2b/CLTools_Executables.pkg",
                size: 350_457_031,
                upstreamDigest: "910fb71482f4d044112c226b03e33122c17920ce",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
            requiredLibcxxSymbols: ["_ZNSt3__122__libcpp_verbose_abortEPKcz"],
        ),
        .init(
            version: "16.4",
            newestSDK: "18.5",
            // Its swift-driver (Swift 6.1.2) and two SwiftSyntax libraries import macOS's
            // zippered availability check; iOS's runtime has no such symbol, so dyld stops
            // swiftc on iOS 17.3.1 (iPhone 15 Pro, 2026-10-21). The rename 27.0 uses is right
            // only from iOS 26, and swift-frontend carries 3,754 udot (DotProd) and 5 eor3.
            swiftUnavailable: "Swift 6.1.2 from Command Line Tools 16.4 is not offered: it would need iOS 26 or later "
                + "and an A13 or later CPU, where Command Line Tools 27.0's Swift 6.4 already runs, and it has not been "
                + "verified on such a device.",
            verifiedSDKs: ["18.4", "18.5"],
            packages: [.init(
                productID: "082-41241",
                sha256: "43c15c1f952c7a4c1a8f67c6b46350b83e217c610d7d3c14aa09e88bb251a4b6",
                url: "https://swcdn.apple.com/content/downloads/52/01/082-41241-A_0747ZN8FHV/dectd075r63pppkkzsb75qk61s0lfee22j/CLTools_Executables.pkg",
                size: 715_692_551,
                upstreamDigest: "d1d5bf166a88ba1b59d982fa27f96d6b16601a94",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3", "FEAT_DotProd"],
            requiredLibcxxSymbols: ["_ZNSt3__122__libcpp_verbose_abortEPKcz"],
        ),
        .init(
            version: "15.3",
            newestSDK: "17.4",
            weakSystemLibraries: [libcodedirectory],
            // swift-frontend's only SHA3 code is BLAKE3's hash_many (compile caching) and the
            // symbol-graph edge set (-emit-symbol-graph), neither on Apelin's build path; on an
            // A12Z (no SHA3) every Swift case, macros included, passed (2026-10-21).
            swift: .init(
                version: "5.10",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1"],
            ),
            verifiedSDKs: ["17.2", "17.4"],
            packages: [.init(
                productID: "052-59890",
                sha256: "3812e6cce85d90f2a142440628a56ececd90d7fcb2ebfb35cc2faee3d81bd6ab",
                url: "https://swcdn.apple.com/content/downloads/14/48/052-59890-A_I0F5YGAY0Y/p9n40hio7892gou31o1v031ng6fnm9sb3c/CLTools_Executables.pkg",
                size: 565_536_039,
                upstreamDigest: "92e85a0f035a02000847ad273eca90f2e056789c",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 1667,
        ),
        .init(
            version: "15.0",
            newestSDK: "17.0",
            weakSystemLibraries: [libcodedirectory],
            // swift-frontend's only SHA3 code is BLAKE3's hash_many (compile caching) and the
            // symbol-graph edge set (-emit-symbol-graph), neither on Apelin's build path; on an
            // A12Z (no SHA3) every Swift case, macros included, passed (2026-10-21).
            swift: .init(
                version: "5.9",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1", "26.6.2", "27.0.1"],
            ),
            verifiedSDKs: ["17.0"],
            packages: [.init(
                productID: "042-32697",
                sha256: "a5ec585bf89ce2e43aca1583b8a315b88725d53bc66dd0f2ba3fcf4580ec7b8f",
                url: "https://swcdn.apple.com/content/downloads/11/17/042-32697-A_1GOTVNQE4A/hy88qtn1sygbgxswlmbfdepd4pcg52xyrx/CLTools_Executables.pkg",
                size: 574_900_109,
                upstreamDigest: "696ef34df0df4329f107e8dbd1c3a9fff57784e0",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC", "FEAT_SHA3"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 1682,
        ),
        .init(
            version: "14.2",
            newestSDK: "16.2",
            weakSystemLibraries: [libxar],
            swift: .init(
                version: "5.7.2",
                minimumHost: "17.3.1",
                cpuFeatures: ["FEAT_LRCPC"],
                verifiedHosts: ["17.3.1", "26.0.1", "26.6.2", "27.0.1"],
            ),
            clangModuleCPUFeatures: [],
            verifiedSDKs: ["16.1", "16.2"],
            packages: [.init(
                productID: "012-92431",
                sha256: "81c4ed35ac9a2dcce106c9d26696653ceb9337b949206802886e25d13f9b3f1a",
                url: "https://swcdn.apple.com/content/downloads/03/28/012-92431-A_FKICGWU4EK/eflw1v4c64sgmvux4ljc083cfjj663wu9g/CLTools_Executables.pkg",
                size: 507_485_226,
                upstreamDigest: "8eeed85b32e5b72f137e5d0e23e6f9ac2f1bb4f9",
            )],
            staticInstructionFeatures: ["FEAT_LRCPC"],
            systemSymbolSDK: "16.1",
            systemSymbolCount: 949,
        ),
    ]

    /// Releases looked at and refused, with the reason a user reads.
    static let refused: [String: String] = [
        "12.4": "C++ programs it builds for arm64e stop on iOS as soon as they print output",
    ].merging(retired.map { ($0, retiredReason) }) { first, _ in first }

    /// Releases that passed on a device and were dropped (owner, 2026-10-21):
    /// every SDK each one reads, a kept release reads too, and 14.2 keeps
    /// Swift for A12 CPUs. Apple's catalog still lists them.
    static let retired = ["16.2", "14.3", "13.4", "13.2", "12.5"]
    static let retiredReason = "it is retired because a newer supported release works with all of its SDKs"

    /// The version a catalog package gets when its metadata names none.
    static let unknownVersion = "unknown"

    public static func release(_ version: String) -> CommandLineToolsRelease? {
        releases.first { $0.version == version }
    }

    /// `listed`, Apple's catalog as read, with every reviewed package it no
    /// longer names added under the address recorded here, newest first and
    /// a package that names no version last.
    static func catalog(adding listed: [ToolchainSource]) -> [ToolchainSource] {
        let names = Set(listed.map(\.productID))
        let kept = releases.flatMap { release in
            release.packages
                .filter { !names.contains($0.productID) }
                .compactMap { $0.source(version: release.version) }
        }
        return (listed + kept).sorted {
            if ($0.version == unknownVersion) != ($1.version == unknownVersion) {
                return $1.version == unknownVersion
            }
            return $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
    }

    /// Nil for a reviewed release; otherwise one sentence a user reads, naming
    /// the version and why setup does not take it.
    public static func refusal(for version: String, productID: String? = nil) -> String? {
        if let release = release(version) {
            if let productID, !release.sourceProductIDs.contains(productID) {
                return "Command Line Tools \(version) product \(productID) has not been reviewed; its binaries may differ from the supported release."
            }
            return nil
        }
        let supported = releases.map(\.version).joined(separator: ", ")
        if let reason = refused[version] {
            return "Command Line Tools \(version) cannot be set up: \(reason). Pick one of \(supported)."
        }
        if version == unknownVersion {
            return "This Command Line Tools package does not say which version it is, so Apelin cannot set it up. "
                + "Pick one of \(supported)."
        }
        return "Command Line Tools \(version) has not been tested on iOS, so Apelin does not set it up yet. "
            + "Pick one of \(supported)."
    }

    static func majorMinor(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        return [parts.first ?? 0, parts.count > 1 ? parts[1] : 0]
    }
}
