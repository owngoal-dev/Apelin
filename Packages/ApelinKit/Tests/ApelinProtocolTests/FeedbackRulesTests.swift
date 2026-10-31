@testable import ApelinProtocol
import XCTest

/// What a public issue filed as feedback may say: the shapes of a device's
/// private data are refused, by kind and never quoted; what a bad case
/// ordinarily holds goes through.
final class FeedbackRulesTests: XCTestCase {
    private let title = "The build log stops early"

    private func problem(_ body: String, paths: [String] = [], names: [String] = []) -> String? {
        FeedbackRules.problem(title: title, body: body, paths: paths, names: names)
    }

    func testTheTitleIsOneLineAndTheBodyIsBounded() {
        XCTAssertNil(FeedbackRules.problem(title: "  \(title)  ", body: "It ends before the link step."))
        XCTAssertNotNil(FeedbackRules.problem(title: "   ", body: "x"), "an empty title")
        XCTAssertNotNil(FeedbackRules.problem(title: "Two\nlines", body: "x"))
        XCTAssertNotNil(FeedbackRules.problem(title: "Two\u{2028}lines", body: "x"))
        XCTAssertNotNil(FeedbackRules.problem(title: String(repeating: "a", count: FeedbackRules.maximumTitleLength + 1), body: "x"))
        XCTAssertNil(FeedbackRules.problem(title: String(repeating: "a", count: FeedbackRules.maximumTitleLength), body: "x"))
        XCTAssertNotNil(problem(" \n\t"), "an empty body")
        XCTAssertNotNil(problem(String(repeating: "a", count: FeedbackRules.maximumBodyBytes + 1)))
        XCTAssertNil(problem(String(repeating: "a", count: FeedbackRules.maximumBodyBytes)))
        XCTAssertNotNil(problem("a\u{0}b"), "a NUL")
    }

    func testPrivateDataIsRefusedByKindAndNeverQuoted() throws {
        let refused: [(text: String, kind: String)] = [
            ("token ghp_" + String(repeating: "A1b2", count: 9), "token"),
            ("github_pat_11ABCDEFG0123456789_abcdefghijklmnop", "token"),
            ("key sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "token"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----", "token"),
            ("Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345", "token"),
            ("in /var/mobile/Documents/wiki.qaq.apelin/Projects/Secret", "home"),
            ("/private/var/mobile/Library/Logs", "home"),
            ("/var/containers/Bundle/Application/.jbroot-1A2B3C4D/usr/lib", "home"),
            ("on the Mac, /Users/someone/Desktop", "home"),
            ("ssh to 192.168.1.20", "network"),
            ("10.0.0.5:2222", "network"),
            ("172.20.3.4", "network"),
            ("100.101.102.103 over the tailnet", "network"),
            ("fe80::1c2b:3a4d:5e6f:7a8b", "network"),
            ("Adas-iPhone.local.", "network"),
            ("the router is router.home.arpa", "network"),
            ("rootless at /private/preboot/6F8C2E1A9B3D4C5E/jb-AbCd1234", "home"),
            ("key xai-" + String(repeating: "x1", count: 20), "token"),
            ("UDID 00008030-00112233445566AA", "identifier"),
            ("UDID " + String(repeating: "a1b2c3d4e5", count: 4), "identifier"),
            ("serial AB12CD34EF56", "identifier"),
            ("MAC 02:00:00:00:00:01", "identifier"),
        ]
        let words = [
            "token": "token or key", "home": "home or install path",
            "network": "local network", "identifier": "device identifier",
        ]
        for (text, kind) in refused {
            let found = try XCTUnwrap(problem("Steps:\n" + text), text)
            XCTAssertTrue(try found.contains(XCTUnwrap(words[kind])), "\(text): \(found)")
            let value = try String(XCTUnwrap(text.split(separator: " ").last))
            XCTAssertFalse(found.contains(value), "\(text) is never quoted")
        }
        XCTAssertNotNil(FeedbackRules.problem(title: "Fails at 192.168.0.2", body: "x"), "the title is read too")
    }

    func testThisDevicesOwnPathsAndNameAreRefused() {
        XCTAssertNil(problem("see /opt/apelin-test/data/x"))
        XCTAssertNotNil(problem("see /opt/apelin-test/data/x", paths: ["/opt/apelin-test"]))
        XCTAssertNotNil(problem("it is Adas-iPhone that fails", names: ["Adas-iPhone"]))
        XCTAssertNil(problem("it is Adas-iPhones that fails", names: ["Adas-iPhone"]), "a word, not a part of one")
        XCTAssertNil(problem("on an iPhone 15 Pro", names: ["iPhone"]), "a name every device of its kind has says nothing")
        XCTAssertNil(problem("under /var/jb/usr/lib/apelin", paths: ["/var/jb", "/"]), "rootless's install root is every rootless device's")
    }

    func testWhatABadCaseOrdinarilyHoldsGoesThrough() {
        let report = """
        On iOS 17.3.1 (21D61), arm64e, roothide, the build of local.apelin.hello failed.
        Its log is ~/Documents/wiki.qaq.apelin/Builds/p/9F86D081-884C-4D63-A1B2-0123456789AB/build.log;
        the artifact's digest is sha256:\(String(repeating: "ab", count: 32)) and the commit 1a2b3c4d.
        IPHONEOS_DEPLOYMENT_TARGET is 16.0; clang listened on 127.0.0.1. CLT 15.3 from /var/jb/usr/lib.
        Crash image UUID 4C4C44A5-5555-3144-A1B2-C3D4E5F60718, build ID BUILD-42.
        """
        XCTAssertNil(problem(report))
    }

    func testTheFooterNamesTheVersionTheSystemAndTheBootstrapOnly() {
        XCTAssertEqual(
            FeedbackRules.footer(appVersion: "0.2.7", appBuild: "18", osVersion: "17.3.1", bootstrap: .roothide),
            "Sent with Apelin 0.2.7 (18) · iOS 17.3.1 · roothide",
        )
        XCTAssertEqual(
            FeedbackRules.footer(appVersion: nil, appBuild: "18", osVersion: "26.0", bootstrap: .rootless),
            "Sent with Apelin (version unknown) · iOS 26.0 · rootless",
        )
        XCTAssertEqual(FeedbackRules.issueBody("Body.\n\n ", footer: "F"), "Body.\n\n---\nF")
    }

    // MARK: Edits

    func testAnEditChecksOnlyWhatChanges() throws {
        XCTAssertNotNil(FeedbackRules.editProblem(title: nil, body: nil), "an edit changes something")
        XCTAssertNil(FeedbackRules.editProblem(title: "  The build log stops before the link step ", body: nil))
        XCTAssertNil(FeedbackRules.editProblem(title: nil, body: "It also stops on rootless."))
        XCTAssertEqual(FeedbackRules.editProblem(title: "  ", body: nil), "the title is empty")
        XCTAssertEqual(FeedbackRules.editProblem(title: nil, body: " \n"), "the body is empty")
        XCTAssertNotNil(FeedbackRules.editProblem(title: "Two\nlines", body: nil))
        let network = try XCTUnwrap(FeedbackRules.editProblem(title: nil, body: "From 192.168.1.20"))
        XCTAssertTrue(network.contains("local network"), network)
        XCTAssertNotNil(FeedbackRules.editProblem(title: "Fails at 192.168.0.2", body: nil), "the title is read too")
        XCTAssertNotNil(FeedbackRules.editProblem(title: nil, body: "see /opt/apelin-test/data/x", paths: ["/opt/apelin-test"]))
        XCTAssertNotNil(FeedbackRules.editProblem(title: nil, body: "it is Adas-iPhone that fails", names: ["Adas-iPhone"]))
        let footer = FeedbackRules.footer(appVersion: "0.2.7", appBuild: "18", osVersion: "17.3.1", bootstrap: .roothide)
        let withFooter = try XCTUnwrap(FeedbackRules.editProblem(title: nil, body: FeedbackRules.issueBody("Body.", footer: footer)))
        XCTAssertTrue(withFooter.contains("leave it out"), "the footer stays below the body as it was: \(withFooter)")
    }

    func testTheFooterIsSplitOffAsTheBodyEndsWithIt() {
        let footer = FeedbackRules.footer(appVersion: "0.2.7", appBuild: "18", osVersion: "17.3.1", bootstrap: .rootless)
        let sent = FeedbackRules.issueBody("It ends before the link step.\n", footer: footer)
        let split = FeedbackRules.split(issueBody: sent)
        XCTAssertEqual(split.text, "It ends before the link step.")
        XCTAssertEqual(split.footer, footer)
        XCTAssertEqual(split.replacingText("It also stops on roothide.\n\n"), "It also stops on roothide.\n\n---\n" + footer)

        // GitHub's own line ends, after an edit on the site, and a version
        // Apelin could not read: the footer still comes off, and goes back
        // as it was.
        let unknown = FeedbackRules.footer(appVersion: nil, appBuild: nil, osVersion: "26.0", bootstrap: .roothide)
        let edited = "Line one\r\nLine two\r\n\r\n---\r\n" + unknown + "\r\n"
        let fromSite = FeedbackRules.split(issueBody: edited)
        XCTAssertEqual(fromSite.text, "Line one\r\nLine two")
        XCTAssertEqual(fromSite.footer, unknown)
        XCTAssertEqual(fromSite.replacingText("New"), "New\r\n\r\n---\r\n" + unknown + "\r\n")

        // No footer, or one that is not the body's end: the body is all text.
        for body in [
            "No footer here.",
            "Quoted:\n\n---\n" + footer + "\n\nand more below it.",
            "Sent with Apelin 0.2.7 (18) · iOS 17.3.1 · rootless",
            "Body\n---\n" + footer,
            "Body\n\n---\nSent with Apelin 0.2.7 · iOS 17.3.1 · jailbroken",
        ] {
            let split = FeedbackRules.split(issueBody: body)
            XCTAssertNil(split.footer, body)
            XCTAssertEqual(split.text, body)
            XCTAssertEqual(split.replacingText("New"), "New", "nothing is added below an issue that has no footer")
        }
    }
}
