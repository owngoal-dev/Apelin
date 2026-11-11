import ApelinBuild
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

final class ToolRunnerTests: XCTestCase {
    private let environment = ["PATH": "/usr/bin:/bin"]

    /// argv is argv: nothing in it is read by a shell.
    func testArgumentsAreNotInterpreted() throws {
        let result = try ToolRunner.run(ToolInvocation(executable: "/bin/echo", arguments: ["$HOME;", "`id`", "a b"], workingDirectory: "/", environment: environment), cancellation: BuildCancellation())
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "$HOME; `id` a b\n")
    }

    func testWorkingDirectoryStatusAndStderr() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let pwd = try ToolRunner.run(ToolInvocation(executable: "/bin/pwd", arguments: [], workingDirectory: scratch.path, environment: environment), cancellation: BuildCancellation())
        XCTAssertEqual(pwd.output.trimmingCharacters(in: .newlines), scratch.path)
        let failing = try ToolRunner.run(ToolInvocation(executable: "/bin/ls", arguments: ["/nonexistent-apelin"], workingDirectory: "/", environment: environment), cancellation: BuildCancellation())
        XCTAssertNotEqual(failing.status, 0)
        XCTAssertTrue(failing.output.contains("nonexistent-apelin"), "stderr is collected")
    }

    /// No descriptor of the caller's leaks into a tool.
    func testDescriptorsAreNotInherited() throws {
        let opened = open("/dev/null", O_RDONLY)
        let leaked = dup2(opened, 47)
        close(opened)
        defer { close(leaked) }
        let result = try ToolRunner.run(ToolInvocation(executable: "/bin/sh", arguments: ["-c", "ls /dev/fd"], workingDirectory: "/", environment: environment), cancellation: BuildCancellation())
        let descriptors = result.output.split(whereSeparator: \.isNewline).compactMap { Int($0) }
        XCTAssertFalse(descriptors.contains(Int(leaked)), "\(descriptors)")
    }

    /// Cancelling kills the tool and its children, and nothing starts after.
    func testCancellationKillsTheProcessGroup() throws {
        let cancellation = BuildCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try ToolRunner.run(ToolInvocation(executable: "/bin/sh", arguments: ["-c", "sleep 30 & sleep 30; wait"], workingDirectory: "/", environment: environment), cancellation: cancellation)) {
            XCTAssertTrue($0 is BuildCancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertThrowsError(try ToolRunner.run(ToolInvocation(executable: "/bin/echo", arguments: [], workingDirectory: "/", environment: environment), cancellation: cancellation))
    }
}

final class ToolDiagnosticsTests: XCTestCase {
    func testClangLines() {
        let output = """
        /p/Hello/Sources/Tweak.m:12:5: error: use of undeclared identifier 'x'
        Sources/Tweak.m:3:1: warning: unused variable 'y' [-Wunused-variable]
        ./Sources/a.h:1:10: fatal error: 'missing.h' file not found
            12 |     x = 1;
        1 error generated.
        ld: warning: dylib (/x/libsubstrate.tbd) was built for newer iOS version (17.0) than being linked (16.0)
        ld: library 'nope' not found
        clang: error: linker command failed with exit code 1 (use -v to see invocation)
        Undefined symbols for architecture arm64e:
        """
        let diagnostics = ToolDiagnostics.parse(output, tool: "clang", projectRoot: "/p/Hello")
        XCTAssertEqual(diagnostics.count, 7, "\(diagnostics)")
        XCTAssertEqual(diagnostics[0], ProjectDiagnostic(code: "clang.error", severity: .error, message: "use of undeclared identifier 'x'", file: "Sources/Tweak.m", line: 12, column: 5))
        XCTAssertEqual(diagnostics[1].severity, .warning)
        XCTAssertEqual(diagnostics[2].file, "Sources/a.h")
        XCTAssertEqual(diagnostics[2].severity, .error)
        XCTAssertEqual(diagnostics[3].severity, .warning)
        XCTAssertNil(diagnostics[3].file)
        XCTAssertEqual(diagnostics[4].message, "library 'nope' not found")
        XCTAssertEqual(diagnostics[5].severity, .error)
        XCTAssertEqual(diagnostics[6].severity, .error)
    }
}

final class PackagerControlTests: XCTestCase {
    /// `package.icon` is the control's `Icon`, after `Name` as the
    /// toolchain's deb has it; a package without one has no `Icon`. The
    /// depictions follow it the same way.
    func testTheIconAndTheDepictionsAreWrittenOnlyWhenTheProjectHasThem() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let toolchain = RegisteredToolchain(
            id: "clt-27.0-sample",
            digest: "sha256:" + String(repeating: "1", count: 64),
            version: "27.0",
            path: "/nonexistent",
            components: ["c-family"],
        )
        let sdk = RegisteredSDK(
            id: "iPhoneOS27.0-00000000",
            digest: "sha256:" + String(repeating: "2", count: 64),
            version: "27.0",
            path: "/nonexistent",
        )
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(
            templateID: "wiki.qaq.apelin.dev.tweak/objc-hook",
            name: "Icon Tweak",
            values: [:],
            catalog: catalog,
            registry: StaticEnvironmentRegistry(toolchains: [toolchain], sdks: [sdk]),
        )
        var inputs = try BuildInputs(
            buildID: "control",
            projectRoot: created.root,
            project: store.locate(created.projectID).project,
            configuration: .release,
            bootstrap: .rootless,
            toolchain: toolchain,
            sdk: sdk,
            catalog: catalog,
            workDirectory: scratch,
            installRoot: "/var/jb",
            home: home.path,
        )
        let products = try JSONDecoder().decode(BuildProducts.self, from: Data(#"{"products": [], "dsyms": [], "log": ""}"#.utf8))
        let icon = "https://owngoal-dev.github.io/Apelin/icons/wiki.qaq.apelin.dev.tweak.png"

        let control = try Packager(inputs: inputs, products: products, shell: "/bin/sh").control()
        XCTAssertEqual(control["Icon"], icon, "the template's icon")
        XCTAssertEqual(control.fields.map(\.name), [
            "Package", "Version", "Architecture", "Description", "Name", "Icon", "Author", "Maintainer", "Section", "Depends",
        ])
        XCTAssertTrue(try control.rendered().contains("\nIcon: \(icon)\n"))

        inputs.project.package.icon = nil
        let without = try Packager(inputs: inputs, products: products, shell: "/bin/sh").control()
        XCTAssertNil(without["Icon"])
        XCTAssertFalse(try without.rendered().contains("Icon:"))

        // `package.depiction` and `package.sileoDepiction` are the control's
        // `Depiction` and `SileoDepiction`, after `Icon`, each only when the
        // project has it (issue #44); no template writes either
        XCTAssertNil(control["Depiction"])
        XCTAssertNil(control["SileoDepiction"])
        XCTAssertFalse(try control.rendered().contains("Depiction"))
        let page = "https://example.github.io/repo/depictions/local.apelin.icon-tweak/"
        let native = page + "depiction.json"
        inputs.project.package.icon = icon
        inputs.project.package.depiction = page
        inputs.project.package.sileoDepiction = native
        let depicted = try Packager(inputs: inputs, products: products, shell: "/bin/sh").control()
        XCTAssertEqual(depicted.fields.map(\.name), [
            "Package", "Version", "Architecture", "Description", "Name", "Icon", "Depiction", "SileoDepiction",
            "Author", "Maintainer", "Section", "Depends",
        ])
        XCTAssertTrue(try depicted.rendered().contains("\nIcon: \(icon)\nDepiction: \(page)\nSileoDepiction: \(native)\n"))

        inputs.project.package.depiction = nil
        let nativeOnly = try Packager(inputs: inputs, products: products, shell: "/bin/sh").control()
        XCTAssertNil(nativeOnly["Depiction"])
        XCTAssertEqual(nativeOnly["SileoDepiction"], native)
        XCTAssertFalse(try nativeOnly.rendered().contains("\nDepiction:"))
    }
}

final class BootstrapResolutionTests: XCTestCase {
    func testFromTheAssignment() {
        XCTAssertEqual(BootstrapResolution.bootstrap(installRoot: "/var/jb", home: "/var/mobile"), .rootless)
        XCTAssertEqual(BootstrapResolution.bootstrap(installRoot: "/private/preboot/ABC/jb-X/procursus", home: "/var/mobile"), .rootless)
        let jbroot = "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
        XCTAssertEqual(BootstrapResolution.bootstrap(installRoot: jbroot, home: jbroot + "/var/mobile"), .roothide)
        XCTAssertEqual(BootstrapResolution.bootstrap(installRoot: jbroot + "x", home: jbroot + "/var/mobile"), .rootless)
    }
}
