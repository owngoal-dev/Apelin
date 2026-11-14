// swift-tools-version: 5.9
//
// Apelin's own shared code, linked into the app, apelind and the workers by
// Apelin.xcodeproj and tested on the Mac with `swift test` (`make harness`).
//
// Which binary links what is decided in the xcodeproj and written down in
// AGENTS.md ▸ Decisions ▸ Process layout. The rule this manifest carries:
// ApelinCore and ApelinProtocol link into the root processes (apelind, its
// session host and apelin-log-reader), so they depend on nothing but the
// system — no package dependency, ever. `make harness` checks it. A
// third-party library is added to the one target that needs it, which links
// only into a mobile worker.
//
// The third-party code here is reached only by apelin-environment: libgit2
// (GitKit) for the git service and SDK fetching, libarchive (ArchiveKit, the
// pin ApelinFormats uses) for SDK archives, and ApelinFormats for Mach-O type
// checks and the local toolchain deb. Licenses/review.json records each one.

import PackageDescription

/// `#file` is `Module/File.swift`, never the build machine's path: the
/// packager greps every shipped binary for the repository root. Package
/// targets do not inherit Configuration/Base.xcconfig, so it is set here.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ConciseMagicFile"),
]

let package = Package(
    name: "ApelinKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ApelinCore", targets: ["ApelinCore"]),
        .library(name: "ApelinProtocol", targets: ["ApelinProtocol"]),
        .library(name: "ApelinEnvironment", targets: ["ApelinEnvironment"]),
        .library(name: "ApelinBuild", targets: ["ApelinBuild"]),
        .library(name: "ApelinProject", targets: ["ApelinProject"]),
        .library(name: "ApelinGit", targets: ["ApelinGit"]),
        .library(name: "ApelinConsole", targets: ["ApelinConsole"]),
        .library(name: "ApelinReplay", targets: ["ApelinReplay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libgit2.xcframework.git", from: "1.0.0"),
        .package(url: "https://github.com/Lakr233/libarchive.xcframework.git", from: "1.0.0"),
        // Mach-O reading, signing and the .deb writer (apelin-build), the
        // .deb reader and writer (apelin-environment).
        .package(path: "../ApelinFormats"),
        // The device-side Command Line Tools download, retarget and
        // self-test (apelin-environment's RetargetToolchainBackend).
        .package(path: "../ApelinToolchain"),
    ],
    targets: [
        // System only: paths, the data folder, project naming, JSON.
        .target(name: "ApelinCore", swiftSettings: swiftSettings),
        // System only: the wire, the task model, the worker channel and the
        // typed ApelinService facade.
        .target(name: "ApelinProtocol", dependencies: ["ApelinCore"], swiftSettings: swiftSettings),
        // apelin-environment: the toolchain registry and setup, the SDK
        // manager, the project-scoped git service, transfer files, and the
        // worker's handler.
        .target(
            name: "ApelinEnvironment",
            dependencies: [
                // ApelinProject: a project transfer file's description,
                // read strictly and given a new project ID on import.
                "ApelinCore", "ApelinProtocol", "ApelinGit", "ApelinProject",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                .product(name: "ApelinMachO", package: "ApelinFormats"),
                .product(name: "ApelinDebian", package: "ApelinFormats"),
                .product(name: "ApelinDebArchive", package: "ApelinFormats"),
                .product(name: "ApelinToolchain", package: "ApelinToolchain"),
            ],
            swiftSettings: swiftSettings,
        ),
        // apelin-build: compile, link, lipo, dSYM, strip, sign, package.
        .target(
            name: "ApelinBuild",
            dependencies: [
                "ApelinCore", "ApelinProtocol", "ApelinProject",
                .product(name: "ApelinMachO", package: "ApelinFormats"),
                .product(name: "ApelinCodeSign", package: "ApelinFormats"),
                .product(name: "ApelinDebian", package: "ApelinFormats"),
                .product(name: "ApelinDebArchive", package: "ApelinFormats"),
            ],
            swiftSettings: swiftSettings,
        ),
        // apelin-project.json, extension manifests, templates, project checks.
        .target(name: "ApelinProject", dependencies: ["ApelinCore", "ApelinProtocol"], swiftSettings: swiftSettings),
        // libgit2 behind typed calls: a shallow clone of one branch, status,
        // diff, stage, unstage, a local commit. No libgit2 type is public.
        .target(
            name: "ApelinGit",
            dependencies: [
                "ApelinCore",
                "ApelinGitOptions",
                .product(name: "GitKit", package: "libgit2.xcframework"),
            ],
            swiftSettings: swiftSettings,
        ),
        // libgit2's variadic option call, which Swift cannot make: two C
        // functions, for ApelinGit alone.
        .target(name: "ApelinGitOptions"),

        // Never shipped: the real EnvironmentWorker with a fake toolchain
        // backend, spawned by the session host's end-to-end toolchain test
        // (Tests/SessionHost, `make harness`), and the fake irisind's unpacker.
        .executableTarget(
            name: "apelin-environment-harness",
            dependencies: [
                "ApelinCore", "ApelinProtocol", "ApelinEnvironment",
                .product(name: "ApelinDebArchive", package: "ApelinFormats"),
            ],
            path: "Tests/EnvironmentHarness",
            swiftSettings: swiftSettings,
        ),

        // The app's console: scripts, `${…}`, expect, follow, the inbox and
        // resuming a run after the app went away. Parameterised on an
        // ApelinService, a DataFolder and a log sink; the app binds them.
        .target(name: "ApelinConsole", dependencies: ["ApelinCore", "ApelinProtocol"], swiftSettings: swiftSettings),

        // An ApelinTransport that answers from event streams captured on a
        // device (Fixtures/, written by Documents/Console/demo/
        // make-replay-fixtures.py), for working on the UI where no apelind
        // runs. Never linked into apelind or a worker.
        .target(
            name: "ApelinReplay",
            dependencies: ["ApelinCore", "ApelinProtocol"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings,
        ),

        .testTarget(name: "ApelinCoreTests", dependencies: ["ApelinCore"]),
        .testTarget(name: "ApelinProtocolTests", dependencies: ["ApelinProtocol"]),
        .testTarget(
            name: "ApelinEnvironmentTests",
            dependencies: [
                "ApelinEnvironment", "ApelinGit", "ApelinProject", "ApelinProtocol",
                .product(name: "ArchiveKit", package: "libarchive.xcframework"),
                .product(name: "ApelinDebArchive", package: "ApelinFormats"),
                .product(name: "ApelinDebian", package: "ApelinFormats"),
            ],
        ),
        .testTarget(name: "ApelinBuildTests", dependencies: [
            "ApelinBuild", "ApelinProject",
            .product(name: "ApelinMachO", package: "ApelinFormats"),
            .product(name: "ApelinDebArchive", package: "ApelinFormats"),
        ]),
        .testTarget(name: "ApelinProjectTests", dependencies: ["ApelinProject"]),
        .testTarget(name: "ApelinGitTests", dependencies: ["ApelinGit"]),
        .testTarget(name: "ApelinConsoleTests", dependencies: ["ApelinConsole", "ApelinCore", "ApelinProtocol"]),
        .testTarget(name: "ApelinReplayTests", dependencies: ["ApelinReplay", "ApelinCore", "ApelinProtocol"]),
    ],
    swiftLanguageVersions: [.v5],
)
