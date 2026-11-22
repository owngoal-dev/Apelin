import ApelinBuild
import ApelinCore
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

enum Repository {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // ApelinBuildTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ApelinKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()
    static let extensions = root.appendingPathComponent("Extensions/Development")
}

func scratchDirectory(_ label: String = "apelin-i3-build") throws -> URL {
    let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("\(label).\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return URL(fileURLWithPath: CanonicalPath.resolve(url.path)!, isDirectory: true)
}

/// Runs a tool and answers its status and combined output.
@discardableResult
func runTool(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    if let directory {
        process.currentDirectoryURL = directory
    }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Xcode's tools and iPhoneOS SDK as a registry; nil when this Mac has no
/// iPhoneOS SDK, and the pipeline tests skip. `APELIN_TEST_TOOLCHAIN` (an
/// extracted Command Line Tools package, the folder holding `Library`) with
/// `APELIN_TEST_SDK` (an iPhoneOS SDK that release reads) put a reviewed
/// release's own clang and ld in Xcode's place.
func macRegistry() -> StaticEnvironmentRegistry? {
    let environment = ProcessInfo.processInfo.environment
    if let toolchain = environment["APELIN_TEST_TOOLCHAIN"], let sdk = environment["APELIN_TEST_SDK"] {
        guard let settings = try? Data(contentsOf: URL(fileURLWithPath: sdk).appendingPathComponent("SDKSettings.json")),
              let object = try? JSONSerialization.jsonObject(with: settings) as? [String: Any],
              let sdkVersion = object["Version"] as? String
        else { return nil }
        return StaticEnvironmentRegistry(
            toolchains: [RegisteredToolchain(id: "clt-under-review", digest: "sha256:" + String(repeating: "a", count: 64), version: "review", path: toolchain, components: ["c-family"])],
            sdks: [RegisteredSDK(id: "iPhoneOS\(sdkVersion)-review", digest: "sha256:" + String(repeating: "b", count: 64), version: sdkVersion, path: sdk)],
        )
    }
    guard let clang = try? runTool("/usr/bin/xcrun", ["--sdk", "iphoneos", "--find", "clang"]), clang.status == 0,
          let sdk = try? runTool("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"]), sdk.status == 0,
          let version = try? runTool("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-version"]), version.status == 0
    else { return nil }
    let toolchain = URL(fileURLWithPath: clang.output.trimmingCharacters(in: .whitespacesAndNewlines))
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    let sdkVersion = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return StaticEnvironmentRegistry(
        toolchains: [RegisteredToolchain(id: "xcode-default", digest: "sha256:" + String(repeating: "a", count: 64), version: "xcode", path: toolchain, components: ["c-family", "swift"])],
        sdks: [RegisteredSDK(id: "iPhoneOS\(sdkVersion)-xcode", digest: "sha256:" + String(repeating: "b", count: 64), version: sdkVersion, path: sdk.output.trimmingCharacters(in: .whitespacesAndNewlines))],
    )
}

/// Collects what a build reports.
final class Collector: BuildReporter, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stages: [String] = []
    private(set) var lines: [String] = []
    private(set) var diagnostics: [ProjectDiagnostic] = []

    func stage(_ name: String, product: String?) {
        lock.lock(); stages.append(product.map { "\(name):\($0)" } ?? name); lock.unlock()
    }

    func log(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func diagnostic(_ diagnostic: ProjectDiagnostic) {
        lock.lock(); diagnostics.append(diagnostic); lock.unlock()
    }
}

/// A home with the data folder made, as the package's postinst makes it.
func makeHome(in scratch: URL) throws -> (home: URL, store: ProjectStore) {
    let home = scratch.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/wiki.qaq.apelin"), withIntermediateDirectories: true)
    return (home, ProjectStore(dataFolder: DataFolder(home: home.path)))
}
