// swift-tools-version: 6.1
// kwwk's manifest declares tools 6.1, so a package that depends on it cannot
// declare less.

import PackageDescription

let package = Package(
    name: "ApelinAgent",
    platforms: [
        .iOS(.v16),
        // kwwk declares macOS 14, and SwiftPM refuses a product whose floor
        // is below a dependency's. macOS is only the test host here; the
        // product ships on iOS.
        .macOS(.v14),
    ],
    products: [
        .library(name: "ApelinAgent", targets: ["ApelinAgent"]),
        // What Workers/Agent/main.swift calls: the session over the worker
        // channel, the host backend and the credential inbox.
        .library(name: "ApelinAgentWorker", targets: ["ApelinAgentWorker"]),
    ],
    dependencies: [
        // EYHN/kwwk v0.1.109, pinned to the commit the tag names so a moved
        // tag cannot change what is built. Bump deliberately.
        .package(
            url: "https://github.com/EYHN/kwwk.git",
            revision: "997d9b3dde24cd26d7abc3d9e15abeb7146b3017",
        ),
        // kwwk's swift-nio, held below 2.104.0. That release made
        // ByteToMessageHandler's decoder `~Copyable`, and an iOS runtime
        // before 18 cannot find a conformance that carries such a condition:
        // configureHTTPServerPipeline's handler cast fails and the sign-in
        // loopback aborts apelin-agent on iOS 17 when Safari connects. kwwk
        // asks for 2.65.0, swift-nio-ssl for 2.98.0. Raise the ceiling only
        // once NIO's noncopyable conformances work on the deployment floor.
        .package(url: "https://github.com/apple/swift-nio.git", "2.98.0" ..< "2.104.0"),
        // Apelin's own wire and worker channel. System code only.
        .package(path: "../ApelinKit"),
        // The agent tool extensions' manifests and their validation, read
        // to offer their tools. System code only.
        .package(path: "../ApelinToolHost"),
    ],
    targets: [
        .target(
            name: "ApelinAgent",
            dependencies: [
                .product(name: "KWWKAgent", package: "kwwk"),
                .product(name: "KWWKMCP", package: "kwwk"),
                .product(name: "KWWKAI", package: "kwwk"),
                // Not imported: it binds the swift-nio ceiling above to
                // every build of apelin-agent. kwwk links NIOCore already.
                .product(name: "NIOCore", package: "swift-nio"),
                // RunCodePresetRule: the words of a preset, as the host reads them;
                // TokenEstimate: the output a run receives, as the app counts a reply.
                .product(name: "ApelinProtocol", package: "ApelinKit"),
                // CanonicalPath: the path rules the rest of Apelin decides by.
                .product(name: "ApelinCore", package: "ApelinKit"),
                // The apelin-project.json schema the apelin-project-description skill serves.
                .product(name: "ApelinProject", package: "ApelinKit"),
                // ToolManifestValidator: the installed agent tool extensions
                // whose tools a session offers.
                .product(name: "ApelinToolCore", package: "ApelinToolHost"),
            ],
            path: "Sources/ApelinAgent",
        ),
        // apelin-agent's worker: AgentHostBackend over ApelinService (the
        // worker channel to the session host), keychain credentials and the
        // console's credential inbox.
        .target(
            name: "ApelinAgentWorker",
            dependencies: [
                "ApelinAgent",
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "ApelinCore", package: "ApelinKit"),
                .product(name: "ApelinProtocol", package: "ApelinKit"),
            ],
            path: "Sources/ApelinAgentWorker",
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),
        .testTarget(
            name: "ApelinAgentWorkerTests",
            dependencies: [
                "ApelinAgentWorker",
                "ApelinAgent",
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "ApelinCore", package: "ApelinKit"),
                .product(name: "ApelinProtocol", package: "ApelinKit"),
            ],
            path: "Tests/ApelinAgentWorkerTests",
        ),
        .testTarget(
            name: "ApelinAgentTests",
            dependencies: [
                "ApelinAgent",
                .product(name: "KWWKAgent", package: "kwwk"),
                .product(name: "KWWKAI", package: "kwwk"),
                .product(name: "ApelinToolCore", package: "ApelinToolHost"),
            ],
            path: "Tests/ApelinAgentTests",
        ),
        // Talks to a real provider. Every test here is skipped unless
        // APELIN_LIVE_OAUTH_PATH names a kwwk-format credential file.
        .testTarget(
            name: "ApelinAgentLiveTests",
            dependencies: [
                "ApelinAgent",
                .product(name: "KWWKAI", package: "kwwk"),
            ],
            path: "Tests/ApelinAgentLiveTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
