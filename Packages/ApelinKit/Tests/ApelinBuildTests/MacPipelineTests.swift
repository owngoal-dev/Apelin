import ApelinBuild
import ApelinCore
import ApelinDebArchive
import ApelinMachO
import ApelinProject
import ApelinProtocol
import Foundation
import XCTest

/// The real pipeline on the Mac (Milestone 1 §8): the tweak template from
/// Extensions/Development made into a project, then built by ApelinBuild
/// with Xcode's clang, ld, lipo, dsymutil and strip against the iPhoneOS
/// SDK, signed by ApelinCodeSign and packaged by DebPackageWriter for
/// roothide and for rootless — then read back by dpkg-deb, codesign and
/// ldid where they are installed. The device runs the same code against
/// the registered toolchain.
final class MacPipelineTests: XCTestCase {
    private func requireTools() throws -> StaticEnvironmentRegistry {
        guard let registry = macRegistry() else { throw XCTSkip("no iPhoneOS SDK on this Mac") }
        return registry
    }

    private func dpkgDeb() -> String? {
        ["/opt/homebrew/bin/dpkg-deb", "/usr/local/bin/dpkg-deb"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func ldid() -> String? {
        ["/opt/homebrew/bin/ldid", "/usr/local/bin/ldid"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testTweakTemplateBuildsAndPackagesForBothBootstraps() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.tweak/objc-hook", name: "Hello Tweak", values: [
            "packageID": .string("com.example.hellotweak"),
        ], catalog: catalog, registry: registry)

        for bootstrap in [Bootstrap.roothide, .rootless] {
            let buildID = "mac-\(bootstrap.rawValue)-\(UUID().uuidString.prefix(8).lowercased())"
            let installRoot = bootstrap == .rootless ? "/var/jb" : "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
            let inputs = try BuildInputs.resolve(buildID: buildID, projectID: created.projectID, configuration: .release, store: store, catalog: catalog, registry: registry, installRoot: installRoot, home: home.path, bootstrap: bootstrap)
            let reporter = Collector()
            let result: BuildService.Result
            do {
                result = try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())
            } catch {
                XCTFail("\(bootstrap): \(error)\n\(reporter.lines.suffix(30).joined(separator: "\n"))")
                continue
            }
            let record = result.record
            XCTAssertEqual(reporter.stages, ["check", "compile:tweak", "link:tweak", "lipo:tweak", "dsym:tweak", "strip:tweak", "sign:tweak", "package", "verify"])
            XCTAssertEqual(reporter.diagnostics.filter { $0.severity == .error }, [])

            // The artifact: registered by ID, its digest the deb's.
            let loaded = try ArtifactStore(store: store).load(buildID)
            XCTAssertEqual(loaded, record)
            XCTAssertEqual(record.digest, try CanonicalJSON.sha256Tag(Data(contentsOf: URL(fileURLWithPath: record.path))))
            XCTAssertEqual(record.architecture, bootstrap == .rootless ? "iphoneos-arm64" : "iphoneos-arm64e")
            XCTAssertEqual(record.buildDigest, created.baseline.build.digest)
            XCTAssertEqual(record.packagingDigest, created.baseline.packaging.digest)

            // The product: the bootstrap's slices, signed, its dSYM's UUIDs its own.
            let product = try XCTUnwrap(result.products.product("tweak"))
            let image = try MachOImage(contentsOfFile: product.executable)
            XCTAssertEqual(image.slices.map(\.architecture).sorted(), bootstrap == .rootless ? ["arm64", "arm64e"] : ["arm64e"])
            XCTAssertTrue(image.slices.allSatisfy(\.isCodeSigned))
            let substrate = bootstrap == .rootless ? "@rpath/CydiaSubstrate.framework/CydiaSubstrate" : "@loader_path/.jbroot/usr/lib/libsubstrate.dylib"
            XCTAssertTrue(image.slices.allSatisfy { $0.linkedLibraries.contains(substrate) }, "\(image.slices.map(\.linkedLibraries))")
            XCTAssertEqual(image.slices.first?.installName, "@rpath/HelloTweak.dylib")
            let dsym = try XCTUnwrap(record.dsyms.first)
            XCTAssertEqual(dsym.uuids, product.uuids)
            let dwarfdump = try runTool("/usr/bin/xcrun", ["dwarfdump", "--uuid", dsym.path])
            for uuid in product.uuids.values {
                XCTAssertTrue(dwarfdump.output.contains(uuid), dwarfdump.output)
            }
            if bootstrap == .rootless {
                let inspection = try image.inspect(image.slices[0])
                XCTAssertEqual(inspection.runpaths, ["/var/jb/Library/Frameworks", "/var/jb/usr/lib"])
            }

            // What the binary carries: the build ID and the marker, and no
            // path of this Mac's project.
            let strings = try runTool("/usr/bin/strings", [product.executable]).output
            XCTAssertTrue(strings.contains(buildID), "the build ID is compiled in")
            XCTAssertTrue(strings.contains("ApelinLoaded %{public}s in %{public}s"))
            XCTAssertFalse(strings.contains(created.root.path), "the project path is in the binary")
            XCTAssertFalse(strings.contains(scratch.path), "a build path is in the binary")

            // The load check the diagnostics side reads.
            let check = try XCTUnwrap(record.loadCheck)
            XCTAssertEqual(check.marker, "ApelinLoaded \(buildID)")
            XCTAssertEqual(check.markerSubsystem, "com.example.hellotweak")
            XCTAssertEqual(check.dylibLogicalPath, "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.dylib")
            XCTAssertEqual(check.filterPlistLogicalPath, "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.plist")
            XCTAssertEqual(check.dylibInstalledPath, installRoot + check.dylibLogicalPath)
            XCTAssertEqual(check.bundles, ["com.apple.springboard"])

            // The deb, through ApelinDebArchive's own reader.
            let contents = try DebArchiveReader.contents(of: .path(record.path), contentsLimit: 64 * 1024)
            let control = try contents.control()
            XCTAssertEqual(control.package, "com.example.hellotweak")
            XCTAssertEqual(control.architecture, record.architecture)
            XCTAssertEqual(control["Depends"], "firmware (>= 16.0), mobilesubstrate")
            let icon = "https://owngoal-dev.github.io/Apelin/icons/wiki.qaq.apelin.dev.tweak.png"
            XCTAssertEqual(control["Icon"], icon, "the template's package icon")
            let prefix = bootstrap == .rootless ? "/var/jb" : ""
            let paths = Set(contents.entries.map(\.path))
            XCTAssertTrue(paths.contains(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.dylib"), "\(paths)")
            XCTAssertTrue(paths.contains(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.plist"), "\(paths)")
            // What the host looks up when irisind refuses the install: the
            // deb's files as dpkg lists them, and no folder.
            let files = try XCTUnwrap(record.packageFiles)
            XCTAssertEqual(Set(files), Set(contents.entries.filter { $0.kind != .directory }.map(\.path)))
            XCTAssertTrue(files.contains(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.dylib"), "\(files)")
            XCTAssertTrue(files.contains(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.plist"), "\(files)")
            XCTAssertEqual(record.wireArtifact.packageFiles, files, "the artifact event carries them to the host")

            // And through the tools a person would use.
            if let dpkgDeb = dpkgDeb() {
                let info = try runTool(dpkgDeb, ["-f", record.path, "Package", "Version", "Architecture", "Depends", "Icon"])
                XCTAssertEqual(info.status, 0, info.output)
                XCTAssertTrue(info.output.contains("Architecture: \(record.architecture)"), info.output)
                XCTAssertTrue(info.output.contains("Icon: \(icon)\n"), info.output)
                let listing = try runTool(dpkgDeb, ["-c", record.path])
                XCTAssertEqual(listing.status, 0, listing.output)
                XCTAssertTrue(listing.output.contains(".\(prefix)/Library/MobileSubstrate/DynamicLibraries/HelloTweak.dylib"), listing.output)
                XCTAssertTrue(listing.output.contains("root/wheel") || listing.output.contains("0/0"), listing.output)
                let extracted = scratch.appendingPathComponent("extracted-\(bootstrap.rawValue)")
                let extraction = try runTool(dpkgDeb, ["-x", record.path, extracted.path])
                XCTAssertEqual(extraction.status, 0, extraction.output)
                let dylib = extracted.appendingPathComponent(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.dylib")
                XCTAssertEqual(try Data(contentsOf: dylib), try Data(contentsOf: URL(fileURLWithPath: product.executable)))
                let filter = try PropertyListSerialization.propertyList(from: Data(contentsOf: extracted.appendingPathComponent(prefix + "/Library/MobileSubstrate/DynamicLibraries/HelloTweak.plist")), format: nil) as? [String: Any]
                XCTAssertEqual((filter?["Filter"] as? [String: Any])?["Bundles"] as? [String], ["com.apple.springboard"])

                let codesign = try runTool("/usr/bin/codesign", ["-dv", "--verbose=4", dylib.path])
                XCTAssertTrue(codesign.output.contains("Identifier=HelloTweak.dylib"), codesign.output)
                XCTAssertTrue(codesign.output.contains("Hash type=sha256"), codesign.output)
                if let ldid = ldid() {
                    // ldid signing the same file again changes nothing: the
                    // signature is the one ldid writes.
                    // under the same name: ldid signs under the file's name
                    let copy = scratch.appendingPathComponent("ldid-\(bootstrap.rawValue)/HelloTweak.dylib")
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: dylib, to: copy)
                    let signed = try runTool(ldid, ["-Hsha256", "-S", copy.path])
                    XCTAssertEqual(signed.status, 0, signed.output)
                    let theirs = try Data(contentsOf: copy)
                    let ours = try Data(contentsOf: dylib)
                    let difference = zip(theirs, ours).enumerated().first { $0.element.0 != $0.element.1 }?.offset
                    XCTAssertTrue(theirs.count == ours.count && difference == nil, "ldid -Hsha256 -S would sign it differently: \(theirs.count) vs \(ours.count), first difference at \(difference ?? -1)")
                    let entitlements = try runTool(ldid, ["-e", dylib.path])
                    XCTAssertEqual(entitlements.status, 0, entitlements.output)
                }
            }
        }
    }

    /// Every C and Objective-C template at iOS 15.0, the oldest iOS a
    /// rootless or roothide bootstrap runs on (issue #71): it builds for both
    /// bootstraps with `-Werror=unguarded-availability-new`, the arm64e
    /// slices keep their pointer signatures (the pipeline's own check), every
    /// slice says 15.0, so does an app's or a bundle's Info.plist, and the
    /// package depends on that firmware.
    func testCFamilyTemplatesBuildForTheOldestIOS() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let templates = catalog.usable.flatMap { item in
            (item.manifest?.templates ?? []).filter { $0.language != .swift }.map { "\(item.manifest!.id)/\($0.id)" }
        }
        XCTAssertEqual(templates.count, 5, "\(templates)")
        for template in templates {
            let created = try store.create(templateID: template, name: "Oldest \(template.split(separator: "/").last!)", values: [
                "deploymentTarget": .string("15.0"),
            ], catalog: catalog, registry: registry)
            for bootstrap in [Bootstrap.roothide, .rootless] {
                let installRoot = bootstrap == .rootless ? "/var/jb" : "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
                let inputs = try BuildInputs.resolve(buildID: "oldest-\(bootstrap.rawValue)-\(UUID().uuidString.prefix(8).lowercased())", projectID: created.projectID, configuration: .release, store: store, catalog: catalog, registry: registry, installRoot: installRoot, home: home.path, bootstrap: bootstrap)
                let reporter = Collector()
                let result: BuildService.Result
                do {
                    result = try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())
                } catch {
                    XCTFail("\(template) \(bootstrap): \(error)\n\(reporter.lines.suffix(30).joined(separator: "\n"))")
                    continue
                }
                // The templates' own warnings (cli/objc's unused argc) are those they have at 16.0.
                let lowered = reporter.diagnostics.filter { $0.severity == .error || $0.message.contains("availab") }
                XCTAssertEqual(lowered, [], "\(template) \(bootstrap)")
                for product in result.products.products {
                    let image = try MachOImage(contentsOfFile: product.executable)
                    for slice in image.slices {
                        XCTAssertEqual(try image.inspect(slice).minimumOS, "15.0.0", "\(template) \(bootstrap) \(slice.architecture)")
                    }
                    if product.type == .app || product.type == .bundle {
                        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: product.path).appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
                        XCTAssertEqual(info?["MinimumOSVersion"] as? String, "15.0", "\(template) \(bootstrap)")
                    }
                }
                let control = try DebArchiveReader.contents(of: .path(result.record.path), contentsLimit: 0).control()
                XCTAssertTrue(control["Depends"]?.hasPrefix("firmware (>= 15.0)") == true, "\(template) \(bootstrap): \(control["Depends"] ?? "")")
            }
        }
    }

    /// clang's diagnostics come back structured, relative to the project.
    func testCompileErrorsAreStructured() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.cli/c", name: "Broken", values: [:], catalog: catalog, registry: registry)
        let source = created.root.appendingPathComponent("Sources/main.c")
        try (String(contentsOf: source, encoding: .utf8) + "\nint broken(void) { return undeclared_name; }\n").write(to: source, atomically: true, encoding: .utf8)
        let lineCount = try String(contentsOf: source, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).count - 1
        let inputs = try BuildInputs.resolve(buildID: "broken", projectID: created.projectID, configuration: .debug, store: store, catalog: catalog, registry: registry, installRoot: "/var/jb", home: home.path, bootstrap: .rootless)
        let reporter = Collector()
        XCTAssertThrowsError(try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())) { error in
            let failure = error as? BuildFailure
            XCTAssertNotNil(failure)
            let diagnostic = failure?.diagnostics.first { $0.severity == .error }
            XCTAssertEqual(diagnostic?.file, "Sources/main.c")
            XCTAssertEqual(diagnostic?.line, lineCount)
            XCTAssertNotNil(diagnostic?.column)
            XCTAssertTrue(diagnostic?.message.contains("undeclared_name") ?? false, "\(String(describing: diagnostic))")
        }
        XCTAssertTrue(reporter.diagnostics.contains { $0.code == "clang.error" && $0.file == "Sources/main.c" })
    }

    /// The command-line template too, which has entitlements: signed with
    /// them, and a CLI layout under /usr/bin.
    func testCommandLineTemplateWithEntitlements() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.cli/objc", name: "Tool", values: [:], catalog: catalog, registry: registry)
        let inputs = try BuildInputs.resolve(buildID: "tool-build", projectID: created.projectID, configuration: .debug, store: store, catalog: catalog, registry: registry, installRoot: "/var/jb", home: home.path, bootstrap: .rootless)
        let result = try BuildService.build(inputs: inputs, store: store, reporter: Collector(), cancellation: BuildCancellation())
        let product = try XCTUnwrap(result.products.products.first)
        let image = try MachOImage(contentsOfFile: product.executable)
        for slice in image.slices {
            let entitlements = try image.entitlementsDictionary(of: slice)
            XCTAssertEqual(entitlements?["com.apple.private.security.no-sandbox"] as? Bool, true)
            // the GPU list the template carries from 0.1.1, under both keys
            for key in ["com.apple.security.iokit-user-client-class", "com.apple.security.exception.iokit-user-client-class"] {
                XCTAssertTrue((entitlements?[key] as? [String])?.contains("IOSurfaceRootUserClient") == true, key)
            }
        }
        XCTAssertNil(result.record.loadCheck)
        let contents = try DebArchiveReader.contents(of: .path(result.record.path), contentsLimit: 0)
        XCTAssertTrue(contents.entries.contains { $0.path.hasPrefix("/var/jb/usr/bin/") && $0.mode == 0o755 }, "\(contents.entries.map(\.path))")
    }

    /// A preference bundle whose pane is built in code beside its Root.plist
    /// one: the extension's Preferences declarations name the cell types,
    /// the specifier factories and properties and the list edits such a
    /// pane calls, and its stub links them, for both bootstraps.
    func testPreferenceBundleWithAPaneBuiltInCode() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.preferences/objc-bundle", name: "Coded Pane", values: [:], catalog: catalog, registry: registry)
        try Data(Self.codedPane.utf8).write(to: created.root.appendingPathComponent("Sources/CodedListController.m"))

        for bootstrap in [Bootstrap.roothide, .rootless] {
            let installRoot = bootstrap == .rootless ? "/var/jb" : "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF"
            let inputs = try BuildInputs.resolve(buildID: "coded-\(bootstrap.rawValue)", projectID: created.projectID, configuration: .debug, store: store, catalog: catalog, registry: registry, installRoot: installRoot, home: home.path, bootstrap: bootstrap)
            let reporter = Collector()
            do {
                _ = try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())
            } catch {
                XCTFail("\(bootstrap): \(error)\n\(reporter.lines.suffix(30).joined(separator: "\n"))")
                continue
            }
            XCTAssertEqual(reporter.diagnostics, [], "\(bootstrap)")
        }
    }

    private static let codedPane = """
    #import <Preferences/PSListController.h>

    @interface CodedListController : PSListController
    @end

    @implementation CodedListController
    - (NSArray *)specifiers {
        if (_specifiers == nil) {
            PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:@"Enabled"
                                                                 target:self
                                                                    set:@selector(setPreferenceValue:specifier:)
                                                                    get:@selector(readPreferenceValue:)
                                                                 detail:Nil
                                                                   cell:PSSwitchCell
                                                                   edit:Nil];
            [toggle setProperty:@"enabled" forKey:@"key"];
            [toggle setProperty:@YES forKey:@"default"];
            [toggle removePropertyForKey:@"footerText"];
            toggle.identifier = @"enabled";
            if (toggle.cellType == PSSwitchCell && toggle.target == self) {
                toggle.name = @"Enabled";
            }
            _specifiers = [@[[PSSpecifier groupSpecifierWithName:@"General"], toggle, [PSSpecifier emptyGroupSpecifier]] mutableCopy];
        }
        return _specifiers;
    }

    - (void)viewDidLoad {
        [super viewDidLoad];
        PSSpecifier *row = [self specifierForID:@"enabled"];
        [self reloadSpecifier:row];
        [self removeSpecifier:row animated:NO];
        [self insertSpecifier:row atIndex:1 animated:YES];
        [self addSpecifier:[PSSpecifier groupSpecifierWithName:@"More"]];
    }
    @end
    """

    /// The artifact's digests describe the bytes it holds: a file the
    /// packaging description names that changes after the check — here a
    /// script step rewrites it mid-build — fails the build instead of
    /// shipping under the digest of what it was.
    func testAFileChangedAfterTheCheckFailsTheBuild() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.cli/c", name: "Changing", values: [:], catalog: catalog, registry: registry)
        let manifest = created.root.appendingPathComponent("apelin-project.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var build = try XCTUnwrap(document["build"] as? [String: Any])
        build["steps"] = (build["steps"] as? [Any] ?? []) + [["type": "script", "id": "rewrite", "interpreter": "sh", "file": "rewrite.sh", "requiresApproval": true]]
        document["build"] = build
        var package = try XCTUnwrap(document["package"] as? [String: Any])
        package["layout"] = (package["layout"] as? [Any] ?? []) + [["path": "/usr/share/changing/notes.txt", "file": "notes.txt"]]
        document["package"] = package
        try JSONSerialization.data(withJSONObject: document, options: .withoutEscapingSlashes).write(to: manifest)
        try Data("approved\n".utf8).write(to: created.root.appendingPathComponent("notes.txt"))
        try Data("printf 'changed\\n' > notes.txt\n".utf8).write(to: created.root.appendingPathComponent("rewrite.sh"))

        // An install root of / so the script step finds this Mac's /bin/sh.
        let inputs = try BuildInputs.resolve(buildID: "changing", projectID: created.projectID, configuration: .debug, store: store, catalog: catalog, registry: registry, installRoot: "/", home: home.path, bootstrap: .rootless)
        let reporter = Collector()
        XCTAssertThrowsError(try BuildService.build(inputs: inputs, store: store, reporter: reporter, cancellation: BuildCancellation())) { error in
            XCTAssertTrue(String(describing: error).contains("notes.txt changed after the project check"), "\(error)")
        }
        XCTAssertEqual(reporter.stages.suffix(2), ["script", "package"])
        XCTAssertThrowsError(try ArtifactStore(store: store).load("changing"))
    }

    /// The check reads apelin-project.json again: a build stops when that is
    /// not the document it was resolved from, but not over a display name.
    func testADescriptionChangedAfterResolvingFailsTheBuild() throws {
        let registry = try requireTools()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (home, store) = try makeHome(in: scratch)
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        let created = try store.create(templateID: "wiki.qaq.apelin.dev.cli/c", name: "Moving", values: [:], catalog: catalog, registry: registry)
        let manifest = created.root.appendingPathComponent("apelin-project.json")
        func edit(_ change: (inout [String: Any]) -> Void) throws {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
            change(&document)
            try JSONSerialization.data(withJSONObject: document, options: .withoutEscapingSlashes).write(to: manifest)
        }
        func resolve(_ buildID: String) throws -> BuildInputs {
            try BuildInputs.resolve(buildID: buildID, projectID: created.projectID, configuration: .debug, store: store, catalog: catalog, registry: registry, installRoot: "/var/jb", home: home.path, bootstrap: .rootless)
        }

        let renamed = try resolve("renamed")
        try edit { $0["displayName"] = "Moved" }
        XCTAssertNoThrow(try BuildService.build(inputs: renamed, store: store, reporter: Collector(), cancellation: BuildCancellation()))

        let moved = try resolve("moved")
        try edit { document in
            var package = document["package"] as? [String: Any] ?? [:]
            package["section"] = "System"
            document["package"] = package
        }
        XCTAssertThrowsError(try BuildService.build(inputs: moved, store: store, reporter: Collector(), cancellation: BuildCancellation())) { error in
            XCTAssertTrue(String(describing: error).contains("apelin-project.json changed"), "\(error)")
        }
    }
}
