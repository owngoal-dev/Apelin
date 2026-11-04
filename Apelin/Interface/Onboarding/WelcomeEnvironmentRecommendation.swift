// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
import ApelinProtocol
import Foundation

/// Picks a pair, not two independent newest releases. The service's host
/// checks and reviewed SDK pairing remain authoritative.
struct WelcomeEnvironmentRecommendation {
    struct SDK {
        let version: String
        let installed: Bool
        let source: SDKSource?
    }

    let toolchain: ToolchainCatalogProduct
    let installedToolchain: ToolchainRecord?
    let sdk: SDK

    var includesSwift: Bool {
        toolchain.supportsSwift == true
    }

    var isInstalled: Bool {
        installedToolchain != nil && sdk.installed
    }

    static func resolve(
        catalog: [ToolchainCatalogProduct],
        status: ToolchainStatusResponse,
        sdks: SDKListResponse,
    ) -> Self? {
        var choices = sdks.sdks.map { SDK(version: $0.version, installed: true, source: nil) }
        for source in sdks.sources ?? [] where source.enabled && source.problem == nil {
            for branch in source.branches ?? [] where branch.hasPrefix(source.branchPrefix) {
                let name = String(branch.dropFirst(source.branchPrefix.count))
                guard name.lowercased().hasPrefix("iphoneos") else { continue }
                let version = String(name.dropFirst(8))
                guard isVersion(version), !choices.contains(where: { $0.version == version }) else { continue }
                choices.append(SDK(
                    version: version,
                    installed: false,
                    source: .repository(url: source.url, branch: branch),
                ))
            }
        }
        let products = catalog.filter { $0.unsupportedReason == nil && isVersion($0.version) }.sorted {
            if ($0.supportsSwift == true) != ($1.supportsSwift == true) {
                return $0.supportsSwift == true
            }
            return $0.version.compare($1.version, options: .numeric) == .orderedDescending
        }
        for product in products {
            let swift = product.supportsSwift == true
            let swiftSDKMajor = swift ? product.newestSDK.map { major($0) } : nil
            let compatible = choices.filter {
                SDKVersionLimit.allows(sdkVersion: $0.version, newestSDK: product.newestSDK)
                    && (swiftSDKMajor == nil || major($0.version) == swiftSDKMajor)
            }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
            let preferred = swift ? product.compatibility?.recommendedSwiftSDK : product.compatibility?.recommendedSDK
            guard let sdk = compatible.first(where: { $0.version == preferred }) ?? compatible.first else { continue }
            let installed = status.toolchains.first { record in
                let sameProduct = record.origin?.split(separator: " ").first.map(String.init) == product.productID
                let cReady = record.components.contains { $0.kind == .c && $0.selfCheckPassed == true }
                let swiftReady = !swift
                    || record.components.contains { $0.kind == .swift && $0.selfCheckPassed == true }
                return sameProduct && cReady && swiftReady
            }
            return Self(toolchain: product, installedToolchain: installed, sdk: sdk)
        }
        return nil
    }

    /// The one reason every release is refused for, when there is one: a
    /// device-wide reason (roothide Bootstrap, a CPU the compilers cannot
    /// run on), which Settings would give for every release too.
    static func commonRefusal(in catalog: [ToolchainCatalogProduct]) -> String? {
        guard let reason = catalog.first?.unsupportedReason,
              catalog.allSatisfy({ $0.unsupportedReason == reason })
        else { return nil }
        return reason
    }

    private static func major(_ version: String) -> Substring {
        version.split(separator: ".").first ?? ""
    }

    private static func isVersion(_ value: String) -> Bool {
        !value.isEmpty && value.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

/// What the Build Tools page says above its rows. Its introduction offers a
/// pair chosen for this device and promises Settings can install them
/// later; when every release is refused for one reason, neither is true, so
/// the page gives that reason in its place and lists no pair (issue #35:
/// on roothide Bootstrap it promised Settings, where every release is
/// refused too).
enum WelcomeEnvironmentIntroduction: Equatable {
    case recommendation
    case refusal(String)

    init(catalog: [ToolchainCatalogProduct]) {
        self = WelcomeEnvironmentRecommendation.commonRefusal(in: catalog).map(Self.refusal) ?? .recommendation
    }
}
