// The ToolchainBackend over Packages/ApelinToolchain. Compiled only when that
// package is linked into ApelinEnvironment (it is written on its own branch);
// until then ToolchainBackends.linked is UnavailableToolchainBackend.
//
// Linking it is one line in Packages/ApelinKit/Package.swift — the package
// dependency `.package(path: "../ApelinToolchain")` and the product
// `ApelinToolchain` on the ApelinEnvironment target — and this file then
// builds as is. Both packages name a `ToolchainSource` and a
// `ToolchainComponent`, so ApelinToolchain's are always spelled qualified.

#if canImport(ApelinToolchain)
    import ApelinProtocol
    import ApelinToolchain
    import Foundation

    public struct RetargetToolchainBackend: ToolchainBackend {
        public init() {}

        public var isAvailable: Bool {
            true
        }

        public func catalog() async throws -> [ToolchainProduct] {
            try await ToolchainCatalog().list().map(Self.product)
        }

        /// One catalog source as a product, with what this Apelin's support
        /// table says of its release.
        static func product(_ source: ApelinToolchain.ToolchainSource) throws -> ToolchainProduct {
            let release = CommandLineToolsSupport.release(source.version)
            let swift = release?.swiftSupport.map {
                SwiftToolchainRequirements(
                    version: $0.version,
                    minimumHost: $0.minimumHost,
                    cpuFeatures: $0.cpuFeatures,
                    minimumHostBasis: $0.minimumHostBasis,
                    verifiedHosts: $0.verifiedHosts,
                )
            }
            let compatibility = try release.map { try Self.compatibility($0.compatibility) }
            return ToolchainProduct(
                productID: source.productID,
                version: source.version,
                url: source.url.absoluteString,
                size: source.size,
                upstreamDigest: source.upstreamDigest,
                upstreamDigestAlgorithm: source.upstreamDigestAlgorithm,
                unsupportedReason: CommandLineToolsSupport.refusal(for: source.version, productID: source.productID)
                    ?? compatibility?.unavailableReason,
                newestSDK: release?.newestSDK,
                supportsSwift: swift != nil && swift?.unavailableReason == nil,
                swiftRequirements: swift,
                swiftUnavailableReason: swift?.unavailableReason ?? (release != nil && swift == nil
                    ? release?.swiftUnavailable
                    ?? "Swift from Command Line Tools \(source.version) has not been adapted for Apelin; CPU instruction compatibility alone does not establish runtime compatibility."
                    : nil),
                clangModuleCPUFeatures: release?.clangModuleCPUFeatures,
                compatibility: compatibility,
                reviewed: release?.sourceProductIDs.contains(source.productID) == true,
            )
        }

        /// These are data-only Codable snapshots in independent packages. Keeping
        /// their wire shapes identical avoids a second table or a lossy field map.
        static func compatibility(_ value: ReleaseCompatibility) throws -> ToolchainCompatibility {
            try JSONDecoder().decode(ToolchainCompatibility.self, from: JSONEncoder().encode(value))
        }

        public func prepare(
            product: ToolchainProduct,
            components: [ToolchainComponentKind],
            staging: URL,
            output: URL,
            progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
        ) async throws -> PreparedToolchain {
            guard let url = URL(string: product.url) else {
                throw ApelinError(.badRequest, "bad package URL \(product.url)")
            }
            let source = ApelinToolchain.ToolchainSource(
                productID: product.productID,
                version: product.version,
                url: url,
                size: product.size,
                upstreamDigest: product.upstreamDigest,
                upstreamDigestAlgorithm: product.upstreamDigestAlgorithm,
            )
            let manifest = try await ToolchainSetup().run(
                source: source,
                components: Self.components(components),
                staging: staging,
                output: output,
                progress: { progress(Self.progress($0)) },
            )
            return try PreparedToolchain(
                id: manifest.id,
                product: product,
                components: components,
                tree: output,
                files: manifest.files,
                installRelativePath: manifest.installRelativePath,
                manifest: JSONEncoder().encode(manifest),
                retargetScheme: manifest.retargetSchemeVersion,
            )
        }

        public func installAndValidate(
            _ prepared: PreparedToolchain,
            installRoot: URL,
            sdk: URL,
            journal: URL,
            scratch: URL,
            install: @escaping ToolchainInstallStep,
            progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
        ) async throws -> [ToolchainSelfTestResult] {
            let manifest = try JSONDecoder().decode(ToolchainManifest.self, from: prepared.manifest)
            do {
                let ready = try await ToolchainSetup().installAndValidate(
                    manifest: manifest,
                    tree: prepared.tree,
                    installRoot: installRoot,
                    sdk: sdk,
                    journal: journal,
                    scratch: scratch,
                    install: { _, _, _ in try await install(prepared) },
                    progress: { progress(Self.progress($0)) },
                )
                return ready.selfTests.map(Self.result)
            } catch {
                // A failed self-test leaves its results in the journal; carry
                // them in the error so the task shows which case failed.
                let record = journal.appendingPathComponent(manifest.id + ".json")
                if let data = FileManager.default.contents(atPath: record.path),
                   let failed = try? JSONDecoder().decode(ToolchainManifest.self, from: data), !failed.selfTests.isEmpty
                {
                    let cases = failed.selfTests.filter { !$0.passed }
                        .map { "\($0.language)/\($0.architecture): \($0.detail)" }
                    throw ApelinError(.internal, "\(error); failed: \(cases.joined(separator: "; "))")
                }
                throw error
            }
        }

        // MARK: Transfer

        public func exportTree(installed: URL, into destination: URL) throws -> PreparedToolchain {
            do {
                return try Self.prepared(
                    ToolchainTransfer.exportCopy(installed: installed, to: destination),
                    tree: destination,
                )
            } catch let error as ApelinError {
                throw error
            } catch {
                throw ApelinError(.conflict, String(describing: error))
            }
        }

        public func importTree(_ tree: URL) throws -> PreparedToolchain {
            do {
                return try Self.prepared(ToolchainTransfer.verifyImported(tree), tree: tree)
            } catch let error as ApelinError {
                throw error
            } catch {
                throw ApelinError(.badRequest, String(describing: error))
            }
        }

        public func importRefusal(_ toolchain: TransferToolchain) -> String? {
            ToolchainTransfer.refusal(
                version: toolchain.record.version,
                productID: toolchain.productID,
                sourceSHA256: toolchain.sourceSHA256,
                scheme: toolchain.retargetScheme,
                swift: toolchain.record.components.contains { $0.kind == .swift },
            )
        }

        /// A tree and its manifest as setup's `prepare` answers them: the
        /// product as this Apelin's support table describes its release now.
        static func prepared(_ manifest: ToolchainManifest, tree: URL) throws -> PreparedToolchain {
            try PreparedToolchain(
                id: manifest.id,
                product: product(manifest.source),
                components: manifest.components.contains(.swift) ? [.c, .swift] : [.c],
                tree: tree,
                files: manifest.files,
                installRelativePath: manifest.installRelativePath,
                manifest: JSONEncoder().encode(manifest),
                retargetScheme: manifest.retargetSchemeVersion,
            )
        }

        public func selfTest(
            installed: URL,
            sdk: URL,
            scratch: URL,
            progress: @escaping @Sendable (ToolchainBackendProgress) -> Void,
        ) async throws -> [ToolchainSelfTestResult] {
            try await ToolchainSelfTest().run(
                toolchain: installed,
                sdk: sdk,
                scratch: scratch,
                progress: { progress(Self.progress($0)) },
            ).map(Self.result)
        }

        static func components(_ kinds: [ToolchainComponentKind]) -> Set<ApelinToolchain.ToolchainComponent> {
            var set: Set<ApelinToolchain.ToolchainComponent> = [.base]
            if kinds.contains(.swift) {
                set.insert(.swift)
            }
            return set
        }

        static func progress(_ progress: ToolchainProgress) -> ToolchainBackendProgress {
            ToolchainBackendProgress(
                stage: progress.stage.rawValue,
                completed: progress.completedBytes,
                total: progress.totalBytes,
                detail: progress.detail,
            )
        }

        static func result(_ test: ToolchainTestResult) -> ToolchainSelfTestResult {
            ToolchainSelfTestResult(
                language: test.language,
                architecture: test.architecture,
                passed: test.passed,
                detail: test.detail,
                seconds: test.seconds,
            )
        }
    }
#endif
