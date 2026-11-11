// swift-tools-version: 5.10
import PackageDescription

/// Apelin's diagnostics: what the mobile worker does through icli, what the
/// root log helper does with system libraries alone, crash symbolication and
/// blame, and the three-way "is the tweak loaded" check.
///
/// Everything except the IcliKit link builds and tests on a Mac with
/// `swift test`. IcliKit is an on-device library with no macOS platform, so it
/// is linked for iOS only and `IcliKitSurface` compiles to nothing elsewhere;
/// the tests drive `Diagnostics` through a fake `IcliSurface`.
let package = Package(
    name: "ApelinDiagnostics",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        // The mobile diagnostics worker: logs, crash reports, screenshot, UI
        // tree and actions, foreground app, running apps, respring fallback.
        .library(name: "ApelinDiagnostics", targets: ["ApelinDiagnosticsCore", "ApelinDiagnostics"]),
        // The root log helper's core. System libraries only: no icli, nothing
        // third-party, so the root helper links nothing it does not need.
        .library(name: "ApelinLogReader", targets: ["ApelinDiagnosticsCore", "ApelinLogReaderSPI", "ApelinLogReader"]),
        // Crash parsing, symbolication from the project's dSYM, and blame.
        .library(name: "ApelinCrash", targets: ["ApelinCrashReport", "ApelinCrashSymbols", "ApelinCrashBlame"]),
        // Marker line and filter plist, each answered apart.
        .library(name: "ConfirmLoaded", targets: ["ApelinDiagnosticsCore", "ConfirmLoaded"]),
        // What Workers/Diagnostics/main.swift calls: every product above
        // served over the worker channel.
        .library(name: "ApelinDiagnosticsWorker", targets: ["ApelinDiagnosticsWorker"]),
        // What Workers/LogReader/main.swift calls. System code only, like
        // everything apelin-log-reader links: ApelinLogReader, ApelinCore,
        // ApelinProtocol. `Scripts/check-system-only.py` holds it to that.
        .library(name: "ApelinLogReaderWorker", targets: ["ApelinLogReaderWorker"]),
    ],
    dependencies: [
        // owngoal-dev/icli, MIT. Any 1.x release; Package.resolved records the
        // reviewed version.
        .package(url: "https://github.com/owngoal-dev/icli.git", from: "1.0.0"),
        // Apelin's own wire and worker channel. System code only.
        .package(path: "../ApelinKit"),
    ],
    targets: [
        // Request and result types every product shares. Foundation only.
        .target(name: "ApelinDiagnosticsCore"),

        .target(
            name: "ApelinDiagnostics",
            dependencies: [
                "ApelinDiagnosticsCore",
                .product(name: "IcliKit", package: "icli", condition: .when(platforms: [.iOS])),
            ],
        ),

        // LoggingSupport's live stream, driven from Objective-C. Foundation
        // and libobjc; the framework itself is opened at run time.
        .target(
            name: "ApelinLogReaderSPI",
            linkerSettings: [.linkedFramework("Foundation")],
        ),
        .target(name: "ApelinLogReader", dependencies: ["ApelinDiagnosticsCore", "ApelinLogReaderSPI"]),

        // Ported from Xrash (MIT); each folder keeps the upstream LICENSE.
        .target(name: "ApelinCrashReport", exclude: ["LICENSE"]),
        .target(name: "ApelinCrashSymbols", dependencies: ["ApelinCrashReport"], exclude: ["LICENSE"]),
        .target(name: "ApelinCrashBlame", dependencies: ["ApelinCrashReport"], exclude: ["LICENSE"]),

        .target(name: "ConfirmLoaded", dependencies: ["ApelinDiagnosticsCore"]),

        // apelin-diagnostics (mobile): logStream, crashList, crashSymbolicate,
        // confirmLoaded, captureScreen, readUITree, uiAction.
        .target(
            name: "ApelinDiagnosticsWorker",
            dependencies: [
                "ApelinDiagnostics", "ApelinCrashReport", "ApelinCrashSymbols", "ApelinCrashBlame", "ConfirmLoaded",
                // The stream pump both log workers share.
                "ApelinLogReaderWorker",
                .product(name: "ApelinCore", package: "ApelinKit"),
                .product(name: "ApelinProtocol", package: "ApelinKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),
        // apelin-log-reader (root): logStream through the root live stream.
        .target(
            name: "ApelinLogReaderWorker",
            dependencies: [
                "ApelinLogReader",
                .product(name: "ApelinCore", package: "ApelinKit"),
                .product(name: "ApelinProtocol", package: "ApelinKit"),
            ],
            swiftSettings: [.enableUpcomingFeature("ConciseMagicFile")],
        ),

        .testTarget(
            name: "ApelinDiagnosticsTests",
            dependencies: ["ApelinDiagnostics"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "ApelinLogReaderTests", dependencies: ["ApelinLogReader"]),
        .testTarget(
            name: "ApelinCrashReportTests",
            dependencies: ["ApelinCrashReport"],
            exclude: ["LICENSE"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(
            name: "ApelinCrashSymbolsTests",
            dependencies: ["ApelinCrashSymbols", "ApelinCrashBlame"],
            exclude: ["LICENSE"],
            resources: [.copy("Fixtures")],
        ),
        .testTarget(name: "ApelinCrashBlameTests", dependencies: ["ApelinCrashBlame"], exclude: ["LICENSE"]),
        .testTarget(name: "ConfirmLoadedTests", dependencies: ["ConfirmLoaded"]),
        .testTarget(
            name: "ApelinDiagnosticsWorkerTests",
            dependencies: [
                "ApelinDiagnosticsWorker", "ApelinLogReaderWorker", "ApelinDiagnostics", "ConfirmLoaded",
                .product(name: "ApelinCore", package: "ApelinKit"),
                .product(name: "ApelinProtocol", package: "ApelinKit"),
            ],
        ),
    ],
)
