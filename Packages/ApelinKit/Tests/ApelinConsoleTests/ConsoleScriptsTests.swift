@testable import ApelinConsole
import ApelinCore
import ApelinProtocol
import Foundation
import XCTest

/// The scripts kept in Documents/Console/scripts/: each one decodes, names
/// only operations and builtins, refers only to labels before it, and every
/// request without a `${…}` reference decodes as its operation's request
/// type. Together they call every operation the console allows. The demo scripts that made the
/// replay fixtures (Documents/Console/demo/) are held to the same form.
final class ConsoleScriptsTests: XCTestCase {
    /// Operations no script calls, each with the reason. Keep it empty
    /// unless a script truly cannot reach one.
    private static let notScripted: [AppOperation: String] = [
        .agentAPIConfiguration: "Only the editing form may read saved API keys; the console refuses it before sending.",
        .gitCredentialSet: "A git credential comes only from Sign In with GitHub in Settings ▸ Git; the console refuses it before sending.",
        .feedbackStar: "A star is given on the reader's GitHub account only by their tap in the app; the console refuses it before sending.",
        .devicePasscodeSave: "The device passcode is typed by a person in Settings, and its test locks the device; the console refuses it before sending.",
    ]

    private static func consoleFolder(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ApelinConsoleTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ApelinKit
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // the repository
            .appendingPathComponent("Documents/Console/\(name)", isDirectory: true)
    }

    private static var scriptsFolder: URL {
        consoleFolder("scripts")
    }

    private static var demoFolder: URL {
        consoleFolder("demo")
    }

    private func scripts(in folder: URL = scriptsFolder) throws -> [(name: String, script: ConsoleScript)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertFalse(names.isEmpty, "no scripts in \(folder.path)")
        return try names.map { name in
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            do {
                return try (name, JSONCoding.decode(ConsoleScript.self, from: data))
            } catch {
                throw ConsoleFailure("\(name) does not decode: \(error)")
            }
        }
    }

    func testEveryScriptIsWellFormed() throws {
        for (name, script) in try scripts() + scripts(in: Self.demoFolder) {
            XCTAssertNotNil(script.name, "\(name) has no name")
            XCTAssertFalse(script.steps.isEmpty, "\(name) has no steps")
            var labels = Set<String>()
            for (index, step) in script.steps.enumerated() {
                let place = "\(name) step \(index) (\(step.op))"
                let request = step.request ?? .object([:])
                for label in Self.referencedLabels(request) {
                    XCTAssertTrue(labels.contains(label), "\(place) refers to ${\(label)…} before any step has that label")
                }
                if let builtin = ConsoleBuiltin(rawValue: step.op) {
                    switch builtin {
                    case .wait:
                        XCTAssertNotNil(request["seconds"]?.doubleValue, "\(place): wait takes seconds")
                    case .expect:
                        XCTAssertNoThrow(try request.decode(ConsoleExpectation.self), place)
                        if let target = request["step"]?.stringValue {
                            XCTAssertTrue(labels.contains(target), "\(place) expects of \(target), which no earlier step is labelled")
                        }
                    }
                } else if let operation = AppOperation(rawValue: step.op) {
                    if !ConsoleSubstitution.hasReference(request) {
                        XCTAssertNoThrow(try Self.decode(operation.requestType, request), "\(place): the request does not decode")
                    }
                } else {
                    XCTFail("\(place): \(step.op) is neither an operation nor wait or expect")
                }
                if let label = step.label {
                    XCTAssertTrue(labels.insert(label).inserted, "\(place): label \(label) is used twice")
                }
            }
        }
    }

    func testTheScriptsCallEveryOperation() throws {
        let called = try Set(scripts().flatMap { $0.script.steps.compactMap { AppOperation(rawValue: $0.op) } })
        for operation in AppOperation.allCases where Self.notScripted[operation] == nil {
            XCTAssertTrue(called.contains(operation), "no script in Documents/Console/scripts/ calls \(operation.rawValue)")
        }
        for operation in Self.notScripted.keys {
            XCTAssertFalse(called.contains(operation), "\(operation.rawValue) is scripted now; take it off notScripted")
        }
    }

    /// The labels `${label.…}` references in a request name.
    private static func referencedLabels(_ value: JSONValue) -> [String] {
        switch value {
        case let .string(text):
            var labels: [String] = []
            var rest = Substring(text)
            while let open = rest.range(of: "${") {
                let tail = rest[open.upperBound...]
                let end = tail.firstIndex { $0 == "." || $0 == "}" } ?? tail.endIndex
                labels.append(String(tail[..<end]))
                rest = tail[end...]
            }
            return labels
        case let .array(items):
            return items.flatMap(referencedLabels)
        case let .object(object):
            return object.values.flatMap(referencedLabels)
        default:
            return []
        }
    }

    private static func decode<R: OperationRequest>(_: R.Type, _ request: JSONValue) throws {
        _ = try request.decode(R.self)
    }
}
