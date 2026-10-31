@testable import ApelinProject
import Foundation
import XCTest

/// The Swift side against `Documents/Schemas/Fixtures`, the same fixtures
/// `Tools/check-fixtures.py` runs the reference implementation on.
final class SchemaFixtureTests: XCTestCase {
    func testEmbeddedSchemasAreTheFiles() throws {
        let project = try String(contentsOf: Repository.schemas.appendingPathComponent("apelin-project.schema.json"), encoding: .utf8)
        let manifest = try String(contentsOf: Repository.schemas.appendingPathComponent("extension-manifest.schema.json"), encoding: .utf8)
        XCTAssertEqual(EmbeddedSchemas.project + "\n", project, "run Packages/ApelinKit/Scripts/embed-schemas.py")
        XCTAssertEqual(EmbeddedSchemas.manifest + "\n", manifest, "run Packages/ApelinKit/Scripts/embed-schemas.py")
    }

    func testProjectFixtures() throws {
        try checkDocuments("project", ProjectValidation.errors)
    }

    func testExtensionFixtures() throws {
        try checkDocuments("extension", ManifestValidation.errors)
    }

    private func checkDocuments(_ kind: String, _ validate: (JSONDocument) -> [String]) throws {
        let valid = Repository.fixtures.appendingPathComponent("\(kind)/valid")
        let names = try FileManager.default.contentsOfDirectory(atPath: valid.path).filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty)
        for name in names {
            let errors = try validate(StrictJSON.parse(contentsOf: valid.appendingPathComponent(name)))
            XCTAssertEqual(errors, [], "\(kind)/valid/\(name)")
        }
        let invalid = Repository.fixtures.appendingPathComponent("\(kind)/invalid")
        guard case let .object(expectations) = try StrictJSON.parse(contentsOf: invalid.appendingPathComponent("expectations.json")) else {
            return XCTFail("expectations")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: invalid.path).filter { $0.hasSuffix(".json") && $0 != "expectations.json" }.sorted()
        XCTAssertEqual(Set(files), Set(expectations.keys))
        for name in files {
            let expected = expectations[name]?.stringValue ?? "?"
            var errors: [String]
            do {
                errors = try validate(StrictJSON.parse(contentsOf: invalid.appendingPathComponent(name)))
            } catch {
                errors = [String(describing: error)]
            }
            XCTAssertTrue(errors.contains { $0.contains(expected) }, "\(kind)/invalid/\(name): expected '\(expected)', got \(errors)")
        }
    }

    func testCanonicalJSONVectors() throws {
        guard case let .array(vectors) = try StrictJSON.parse(contentsOf: Repository.fixtures.appendingPathComponent("canonical-json.json")) else {
            return XCTFail("vectors")
        }
        XCTAssertFalse(vectors.isEmpty)
        for vector in vectors {
            XCTAssertEqual(try CanonicalJSON.string(XCTUnwrap(vector["input"])), vector["canonical"]?.stringValue, vector["name"]?.stringValue ?? "")
        }
    }

    func testStrictReaderRefusals() {
        let refused: [String: String] = [
            "\u{FEFF}{}": "byte order mark",
            #"{"a": 1, "a": 2}"#: "duplicate member",
            #"{"a": 1.0}"#: "non-integer",
            #"{"a": 1e3}"#: "non-integer",
            #"{"a": 9007199254740992}"#: "outside",
            #"{"a": "\ud800"}"#: "lone surrogate",
            "{\"a\": \"\u{1}\"}": "control character",
            #"{"a": NaN}"#: "unexpected",
        ]
        for (text, expected) in refused {
            XCTAssertThrowsError(try StrictJSON.parse(Data(text.utf8)), text) { error in
                XCTAssertTrue(String(describing: error).contains(expected), "\(text): \(error)")
            }
        }
        XCTAssertEqual(try StrictJSON.parse(Data(#"{"é": "é", "n": -0}"#.utf8))["n"], .integer(0))
    }

    // MARK: Placeholders and escaping, the check-fixtures.py tables

    private var placeholderTypes: [String: ParameterType] {
        var types = TemplateParameters.builtin.mapValues { ParameterType(type: $0) }
        types["displayName"] = ParameterType(type: "string")
        types["productName"] = ParameterType(type: "identifier")
        types["bundles"] = ParameterType(type: "bundleIDList")
        types["enabled"] = ParameterType(type: "bool")
        return types
    }

    func testPlaceholderRules() {
        let rules: [(String, String, Bool)] = [
            ("objc", #"self.title = @"{{displayName}}";"#, true),
            ("objc", "NSString *title = {{displayName}};", false),
            ("objc", "@interface {{productName}}Controller : NSObject", true),
            ("objc", "static int on = {{enabled}};", true),
            ("objc", "NSArray *b = {{bundles}};", false),
            ("swift", #"let title = "{{displayName}}""#, true),
            ("json", #""name": "{{displayName}}""#, true),
            ("json", #""name": {{displayName}}"#, false),
            ("json", #""bundles": {{bundles}}"#, true),
            ("json", #""bundles": "{{bundles}}""#, false),
            ("json", #""architectures": {{architectures}}"#, true),
            ("plist-xml", "<string>{{displayName}}</string>", true),
            ("plist-xml", #"<string attr="{{displayName}}">x</string>"#, false),
            ("plist-xml", "<array>{{bundles}}</array>", true),
            ("shell", "echo {{packageID}}", true),
            ("shell", "echo {{displayName}}", false),
            ("shell", "echo {{projectName}}", false),
            ("deb-control", "Name: {{displayName}}", true),
            ("text", "{{unknownName}}", false),
            ("copy", "{{anything}}", true),
        ]
        for (format, text, allowed) in rules {
            let errors = TemplateParameters.checkText(text, format: format, types: placeholderTypes, where: "rule")
            XCTAssertEqual(errors.isEmpty, allowed, "\(format): \(text) \(errors)")
        }
        for (path, allowed) in [("{{productName}}.m", true), ("{{displayName}}.m", false), ("{{projectName}}/x", false)] {
            XCTAssertEqual(TemplateParameters.checkPath(path, types: placeholderTypes, where: "path").isEmpty, allowed, path)
        }
    }

    func testEscaping() throws {
        let escapes: [(String, String, String)] = [
            ("objc", "a\"b\\c\nd", #"a\"b\\c\nd"#),
            ("swift", #"say \(x) "hi""#, #"say \\(x) \"hi\""#),
            ("json", "a\"b\\c\u{1}", #"a\"b\\c\u0001"#),
            ("plist-xml", "<Tom & 'Jerry'>", "&lt;Tom &amp; &apos;Jerry&apos;&gt;"),
        ]
        for (format, value, expected) in escapes {
            XCTAssertEqual(try TemplateParameters.substitute("{{displayName}}", format: format, types: placeholderTypes, values: ["displayName": .string(value)]), expected, format)
        }
        for (format, value) in [("deb-control", "two\nlines"), ("shell", "a b")] {
            XCTAssertThrowsError(try TemplateParameters.substitute("{{displayName}}", format: format, types: placeholderTypes, values: ["displayName": .string(value)]), format)
        }
        XCTAssertEqual(try TemplateParameters.substitute("{{bundles}}", format: "json", types: placeholderTypes, values: ["bundles": .array([.string("a.b"), .string("c.d")])]), #"["a.b", "c.d"]"#)
        XCTAssertEqual(try TemplateParameters.substitute("{{bundles}}", format: "plist-xml", types: placeholderTypes, values: ["bundles": .array([.string("a.b")])]), "<string>a.b</string>")
        XCTAssertEqual(try TemplateParameters.substitute("{{enabled}}", format: "objc", types: placeholderTypes, values: ["enabled": .bool(true)]), "1")
        XCTAssertEqual(try TemplateParameters.substitute("{{architectures}}", format: "json", types: placeholderTypes, values: [
            "architectures": .object(JSONObject([("roothide", .array([.string("arm64e")])), ("rootless", .array([.string("arm64"), .string("arm64e")]))])),
        ]), #"{"rootless": ["arm64", "arm64e"], "roothide": ["arm64e"]}"#)
    }

    // MARK: Digests

    private var digestCase: URL {
        Repository.fixtures.appendingPathComponent("digest/cli-with-script")
    }

    func testDigestFixture() throws {
        let digests = try ApprovalDigests.compute(projectAt: digestCase.appendingPathComponent("project"))
        let expected = try StrictJSON.parse(contentsOf: digestCase.appendingPathComponent("expected.json"))
        XCTAssertEqual(digests.build.canonical, expected["build"]?["canonical"]?.stringValue)
        XCTAssertEqual(digests.build.digest, expected["build"]?["digest"]?.stringValue)
        XCTAssertEqual(digests.packaging.canonical, expected["packaging"]?["canonical"]?.stringValue)
        XCTAssertEqual(digests.packaging.digest, expected["packaging"]?["digest"]?.stringValue)
    }

    /// check-fixtures.py's edit table: each edit moves exactly the digests
    /// README ▸ Approval digests says it moves.
    func testDigestEditTable() throws {
        let base = try ApprovalDigests.compute(projectAt: digestCase.appendingPathComponent("project"))
        typealias Edit = (URL) throws -> Void
        func append(_ path: String, _ text: String) -> Edit {
            { root in
                let handle = try FileHandle(forWritingTo: root.appendingPathComponent(path))
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try handle.close()
            }
        }
        func editJSON(_ change: @escaping (inout JSONObject) -> Void) -> Edit {
            { root in
                let url = root.appendingPathComponent("apelin-project.json")
                guard case var .object(document) = try StrictJSON.parse(contentsOf: url) else { return }
                change(&document)
                // Reordered and reindented on every write, as json.dumps(sort_keys) does.
                try JSONWriter.compact(.object(JSONObject(document.entries.reversed()))).write(to: url)
            }
        }
        let writeOneLine: Edit = { root in
            let url = root.appendingPathComponent("apelin-project.json")
            let oneLine = try JSONWriter.compact(StrictJSON.parse(contentsOf: url)) + Data("\n".utf8)
            // Afresh, in its folder's group, which formatting keeps.
            try FileManager.default.removeItem(at: url)
            try oneLine.write(to: url)
        }
        func set(_ object: inout JSONObject, _ path: [String], _ value: JSONDocument) {
            guard let head = path.first else { return }
            if path.count == 1 {
                object[head] = value; return
            }
            if let index = Int(path[1]), case var .array(items)? = object[head], case var .object(inner) = items[index] {
                if path.count == 2 {
                    return
                }
                set(&inner, Array(path.dropFirst(2)), value)
                items[index] = .object(inner)
                object[head] = .array(items)
            } else if case var .object(inner)? = object[head] {
                set(&inner, Array(path.dropFirst()), value)
                object[head] = .object(inner)
            }
        }
        let edits: [(String, Edit, Bool, Bool)] = [
            ("source code edited", append("Sources/main.c", "/* edited */\n"), false, false),
            ("new source file", { try Data("int extra;\n".utf8).write(to: $0.appendingPathComponent("Sources/extra.c")) }, false, false),
            ("package version bumped", editJSON { set(&$0, ["package", "version"], .string("9.9.9")) }, false, false),
            ("members reordered", editJSON { _ in }, false, false),
            ("written on one line", writeOneLine, false, false),
            ("formatted from one line", { try writeOneLine($0); XCTAssertTrue(try ProjectManifestFormat.formatFile(in: $0)) }, false, false),
            ("toolchain rebound", editJSON { set(&$0, ["environment", "toolchain", "id"], .string("clt-28.0")) }, false, false),
            ("compile flag added", editJSON { set(&$0, ["build", "steps", "1", "flags"], .array([.string("-DEXTRA=1")])) }, true, false),
            ("build script edited", append("Scripts/generate-version.sh", "# edited\n"), true, false),
            ("entitlements edited", append("Packaging/Tool.entitlements", "\n"), true, false),
            ("deployment target raised", editJSON { set(&$0, ["deploymentTarget"], .string("17.0")) }, true, false),
            ("postinst edited", append("Packaging/postinst", "# edited\n"), false, true),
            ("installed data file edited", append("Packaging/apelinhello.conf", "x=1\n"), false, true),
            ("dependency added", editJSON { set(&$0, ["package", "depends"], .array([.string("coreutils")])) }, false, true),
            ("icon set", editJSON { set(&$0, ["package", "icon"], .string("https://example.com/icon.png")) }, false, true),
            ("install path changed", editJSON { set(&$0, ["package", "layout", "0", "path"], .string("/usr/local/bin/apelinhello")) }, false, true),
        ]
        for (name, edit, buildMoves, packagingMoves) in edits {
            let scratch = try scratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let root = scratch.appendingPathComponent("project")
            try FileManager.default.copyItem(at: digestCase.appendingPathComponent("project"), to: root)
            try edit(root)
            let after = try ApprovalDigests.compute(projectAt: root)
            XCTAssertEqual(after.build.digest != base.build.digest, buildMoves, "\(name): build")
            XCTAssertEqual(after.packaging.digest != base.packaging.digest, packagingMoves, "\(name): packaging")
        }
    }

    /// A referenced file that escapes the project makes the description
    /// uncomputable.
    func testEscapingReferenceIsUncomputable() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("project")
        try FileManager.default.copyItem(at: digestCase.appendingPathComponent("project"), to: root)
        let entitlements = root.appendingPathComponent("Packaging/Tool.entitlements")
        try FileManager.default.removeItem(at: entitlements)
        try FileManager.default.createSymbolicLink(atPath: entitlements.path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try ApprovalDigests.compute(projectAt: root))
    }
}
