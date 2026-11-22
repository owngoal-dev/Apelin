import ApelinCore
import Foundation
import XCTest

/// The user's custom instructions (issue #74): written by the app, read by
/// the agent, each scope a bounded text file in the data folder that a
/// stale window cannot overwrite, a link never followed, and one that does
/// not read set aside rather than replaced.
final class CustomInstructionsStoreTests: XCTestCase {
    private let projectID = "6f1c5b0e-0000-4000-8000-00000000beef"

    private func file(_ root: URL, _ relative: String) -> URL {
        root.appendingPathComponent("Instructions/" + relative)
    }

    func testEachScopeIsSavedTrimmedAndReadBackAndAnEmptyOneClears() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        XCTAssertEqual(store.read(.allChats), SavedInstructions.none, "nothing saved, and no folder made by reading")
        XCTAssertEqual(try store.load(.project(projectID)), CustomInstructionsStore.Loaded(text: "", setAside: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))

        try store.save("  Check my premises first.\n\n", for: .allChats, replacing: "")
        try store.save("Package each patch on its own.", for: .project(projectID), replacing: "")
        XCTAssertEqual(store.read(.allChats), .text("Check my premises first."))
        XCTAssertEqual(store.read(.project(projectID)), .text("Package each patch on its own."))
        XCTAssertEqual(store.read(.project("another-project")), SavedInstructions.none, "another project's is its own")
        XCTAssertEqual(try String(contentsOf: file(root, "global.md"), encoding: .utf8), "Check my premises first.\n")
        XCTAssertEqual(try String(contentsOf: file(root, "Projects/\(projectID).md"), encoding: .utf8), "Package each patch on its own.\n")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file(root, "global.md").path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)

        try store.save(" \n", for: .allChats, replacing: "Check my premises first.")
        XCTAssertEqual(store.read(.allChats), SavedInstructions.none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(root, "global.md").path), "clearing removes the file")
        XCTAssertEqual(store.projectIDs(), [projectID])
    }

    func testTheBoundsAndTheKeysAreHeld() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        let most = String(repeating: "规", count: CustomInstructionsStore.maximumCharacters)
        try store.save(most, for: .allChats, replacing: "")
        XCTAssertEqual(store.read(.allChats), .text(most))
        XCTAssertThrowsError(try store.save(most + "x", for: .allChats, replacing: most)) {
            XCTAssertEqual($0 as? CustomInstructionsError, .tooLong)
        }
        XCTAssertThrowsError(try store.save("a\u{0}b", for: .allChats, replacing: most)) {
            XCTAssertEqual($0 as? CustomInstructionsError, .invalidContent)
        }
        XCTAssertEqual(store.read(.allChats), .text(most), "a refused save leaves the file as it was")
        for key in ["temporary:6f1c5b0e", "../global", "", "-x", ".hidden", String(repeating: "a", count: 65), "a/b", "café"] {
            XCTAssertFalse(CustomInstructionsStore.isProjectKey(key), key)
            XCTAssertThrowsError(try store.save("x", for: .project(key), replacing: "")) {
                XCTAssertEqual($0 as? CustomInstructionsError, .invalidProject)
            }
            XCTAssertEqual(store.read(.project(key)), SavedInstructions.none)
        }
        XCTAssertTrue(CustomInstructionsStore.isProjectKey(projectID))
        XCTAssertTrue(CustomInstructionsStore.isProjectKey("project-1A2B3C4D"))

        // Written by hand past the bound, it does not read; neither does a
        // file that is not UTF-8 or holds a NUL.
        for bytes in [Data(String(repeating: "a", count: CustomInstructionsStore.maximumCharacters + 1).utf8),
                      Data([0xFF, 0xFE, 0x41]), Data("a\u{0}b".utf8),
                      Data(count: CustomInstructionsStore.maximumBytes + 1)]
        {
            try bytes.write(to: file(root, "global.md"))
            XCTAssertEqual(store.read(.allChats), .unreadable)
        }
    }

    func testALinkAHardLinkAnotherOwnerOrAWritableFileIsNotReadAndTheLoadSetsItAside() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        try store.save("Mine.", for: .allChats, replacing: "")
        let global = file(root, "global.md")
        let outside = root.appendingPathComponent("outside.md")
        try Data("Someone else's.".utf8).write(to: outside)

        // A link: never followed, by the reader or the save.
        try FileManager.default.removeItem(at: global)
        try FileManager.default.createSymbolicLink(at: global, withDestinationURL: outside)
        XCTAssertEqual(store.read(.allChats), .unreadable)
        XCTAssertThrowsError(try store.save("New.", for: .allChats, replacing: "")) {
            XCTAssertEqual($0 as? CustomInstructionsError, .changed, "a save over a file that does not read is refused")
        }
        let loaded = try store.load(.allChats)
        XCTAssertEqual(loaded.text, "")
        let aside = try XCTUnwrap(loaded.setAside)
        XCTAssertTrue(aside.hasPrefix("global.md.unreadable-"), aside)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: file(root, aside).path), outside.path, "the link itself was set aside")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "Someone else's.", "and what it named is untouched")
        try store.save("New.", for: .allChats, replacing: loaded.text)
        XCTAssertEqual(store.read(.allChats), .text("New."))

        // A second link to the file, or a file others may write.
        let other = root.appendingPathComponent("other.md")
        try FileManager.default.linkItem(at: global, to: other)
        XCTAssertEqual(store.read(.allChats), .unreadable)
        try FileManager.default.removeItem(at: other)
        XCTAssertEqual(store.read(.allChats), .text("New."))
        try FileManager.default.setAttributes([.posixPermissions: 0o622], ofItemAtPath: global.path)
        XCTAssertEqual(store.read(.allChats), .unreadable)
        let again = try store.load(.allChats)
        XCTAssertNotNil(again.setAside)
        XCTAssertNotEqual(again.setAside, aside, "a second set-aside copy never replaces the first")
        XCTAssertEqual(store.read(.allChats), SavedInstructions.none)
    }

    func testAFolderThatIsALinkIsRefused() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try Data("Planted.".utf8).write(to: elsewhere.appendingPathComponent("global.md"))
        try FileManager.default.createSymbolicLink(at: store.folder, withDestinationURL: elsewhere)
        XCTAssertEqual(store.read(.allChats), .unreadable)
        XCTAssertThrowsError(try store.load(.allChats)) { XCTAssertEqual($0 as? CustomInstructionsError, .unsafeFile) }
        XCTAssertThrowsError(try store.save("x", for: .allChats, replacing: "")) {
            XCTAssertEqual($0 as? CustomInstructionsError, .unsafeFile)
        }
        XCTAssertNil(store.projectIDs())
        XCTAssertEqual(try String(contentsOf: elsewhere.appendingPathComponent("global.md"), encoding: .utf8), "Planted.")

        // Its Projects/ as a link.
        try FileManager.default.removeItem(at: store.folder)
        try FileManager.default.createDirectory(at: store.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.folder.appendingPathComponent("Projects"), withDestinationURL: elsewhere.appendingPathComponent("Projects"))
        XCTAssertEqual(store.read(.project(projectID)), .unreadable)
        XCTAssertThrowsError(try store.save("x", for: .project(projectID), replacing: ""))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.appendingPathComponent("Projects").path), [])
    }

    func testAStaleWindowCannotUndoAnotherSaveOrAClear() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        try store.save("First.", for: .allChats, replacing: "")
        let window = try store.load(.allChats).text
        try CustomInstructionsStore(root: root).save("", for: .allChats, replacing: "First.")
        XCTAssertThrowsError(try store.save("Edited.", for: .allChats, replacing: window)) {
            XCTAssertEqual($0 as? CustomInstructionsError, .changed)
        }
        XCTAssertEqual(store.read(.allChats), SavedInstructions.none, "the Clear stands")
        XCTAssertThrowsError(try store.save("New.", for: .allChats, replacing: "Something else.")) {
            XCTAssertEqual($0 as? CustomInstructionsError, .changed)
        }
    }

    func testConcurrentWritersFromOneStartLeaveExactlyOneWholeText() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try CustomInstructionsStore(root: root).save("Start.", for: .project(projectID), replacing: "")
        let id = projectID
        let accepted = await withTaskGroup(of: String?.self) { group in
            for index in 0 ..< 12 {
                group.addTask {
                    let text = "Writer \(index): " + String(repeating: "x", count: 1500)
                    do {
                        try CustomInstructionsStore(root: root).save(text, for: .project(id), replacing: "Start.")
                        return text
                    } catch {
                        return nil
                    }
                }
            }
            var saved: [String] = []
            for await text in group {
                if let text {
                    saved.append(text)
                }
            }
            return saved
        }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertEqual(CustomInstructionsStore(root: root).read(.project(projectID)), .text(accepted[0]))
        let left = try FileManager.default.contentsOfDirectory(atPath: file(root, "Projects").path)
        XCTAssertEqual(left, ["\(projectID).md"], "no temporary file is left")
    }

    func testADeletedProjectsInstructionsGoAndOnlyWhenEveryFolderTellsItsProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CustomInstructionsStore(root: root)
        let kept = "11111111-0000-4000-8000-000000000001"
        let gone = "22222222-0000-4000-8000-000000000002"
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        func project(_ name: String, _ manifest: String?) throws {
            let folder = projects.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let manifest {
                try Data(manifest.utf8).write(to: folder.appendingPathComponent("apelin-project.json"))
            }
        }
        try store.save("Kept.", for: .project(kept), replacing: "")
        try store.save("Gone.", for: .project(gone), replacing: "")
        try store.save("Everywhere.", for: .allChats, replacing: "")
        try Data("x".utf8).write(to: file(root, "Projects/\(gone).md.unreadable-1800000000"))

        XCTAssertEqual(store.removeGoneProjects(), [], "no Projects/ takes nothing")
        try project("Kept", #"{"projectID":"\#(kept)"}"#)
        try project("Gone", #"{"projectID":"\#(gone)"}"#)
        // Not projects: a link, a file, a hidden folder.
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("Linked"), withDestinationURL: root)
        try Data().write(to: projects.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: projects.appendingPathComponent(".Next.creating-1a2b"), withIntermediateDirectories: true)
        XCTAssertEqual(store.removeGoneProjects(), [])
        XCTAssertEqual(store.projectIDs(), [kept, gone])

        try FileManager.default.removeItem(at: projects.appendingPathComponent("Gone"))
        // A folder whose manifest is set aside by an import, or does not
        // read: it may be either project, so nothing goes.
        try project("Importing", nil)
        XCTAssertEqual(store.removeGoneProjects(), [])
        try project("Importing", "{")
        XCTAssertEqual(store.removeGoneProjects(), [])
        try project("Importing", #"{"projectID":"33333333-0000-4000-8000-000000000003"}"#)
        XCTAssertEqual(store.removeGoneProjects(), [gone])
        XCTAssertEqual(store.read(.project(gone)), SavedInstructions.none)
        XCTAssertEqual(store.projectIDs(), [kept], "its set-aside copy went too")
        XCTAssertEqual(store.read(.project(kept)), .text("Kept."))
        XCTAssertEqual(store.read(.allChats), .text("Everywhere."))

        try store.removeProject(kept)
        XCTAssertEqual(store.read(.project(kept)), SavedInstructions.none)
        try store.removeProject(kept)
    }
}
