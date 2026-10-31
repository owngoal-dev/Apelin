import ApelinCore
import Foundation
import XCTest

/// What a diagnostic log keeps of a text: no credential, e-mail address or
/// path that names this device's install, and a cut that says how long the
/// text was.
final class LogRedactionTests: XCTestCase {
    func testCredentialsAddressesAndThisDevicesPathsAreTakenOut() {
        let redaction = LogRedaction(
            home: "/private/var/containers/Bundle/Application/.jbroot-1A2B3C4D5E6F/var/mobile",
            installRoot: "/private/var/containers/Bundle/Application/.jbroot-1A2B3C4D5E6F",
        )
        let keys = [
            "ghp_" + String(repeating: "a1", count: 18),
            "github_pat_" + String(repeating: "B2", count: 20),
            "gho_" + String(repeating: "c3", count: 18),
            "sk-ant-api03-" + String(repeating: "d4", count: 20),
            "oc_sk_" + String(repeating: "e5", count: 10),
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJl",
            "sk-proj-" + String(repeating: "f6", count: 16),
        ]
        let text = """
        Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123
        x-api-key: \(keys[3])
        {"token":"plain-secret-value","access_token":"also-secret"}
        GITHUB_TOKEN=\(keys[0]) and \(keys[1]), \(keys[2]), \(keys[4]), \(keys[5]) (\(keys[6]))
        https://user:hunter22@example.com/repo.git
        author someone@example.com wrote icon@2x.png
        /private/var/containers/Bundle/Application/.jbroot-1A2B3C4D5E6F/var/mobile/Documents/wiki.qaq.apelin
        /private/var/containers/Bundle/Application/.jbroot-1A2B3C4D5E6F/usr/bin/clang
        /var/mobile/Library and /var/root/.ssh and /var/containers/Bundle/.jbroot-FFFF0000/x
        /Users/someone/Documents/build.log, max_tokens: 4000 tokens≈12,000
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAA
        -----END OPENSSH PRIVATE KEY-----
        """
        let redacted = redaction.redacted(text)
        let secrets = keys + ["abcdefghijklmnopqrstuvwxyz0123", "plain-secret-value", "also-secret", "hunter22", "someone", "b3BlbnNz"]
        for secret in secrets {
            XCTAssertFalse(redacted.contains(secret), "\(secret) survived:\n\(redacted)")
        }
        XCTAssertFalse(redacted.contains(".jbroot-1A2B") || redacted.contains("FFFF0000"), redacted)
        XCTAssertTrue(redacted.contains("~/Documents/wiki.qaq.apelin"), redacted)
        XCTAssertTrue(redacted.contains("<install root>/usr/bin/clang"), redacted)
        XCTAssertTrue(redacted.contains("~/Library and <root home>/.ssh"), redacted)
        XCTAssertTrue(redacted.contains("<email> wrote icon@2x.png"), redacted)
        XCTAssertTrue(redacted.contains("/Users/<user>/Documents/build.log"), redacted)
        XCTAssertTrue(redacted.contains("max_tokens: 4000 tokens≈12,000"), "a count is no credential:\n\(redacted)")
        XCTAssertTrue(redacted.contains("<private key>"), redacted)
        // rootless's install root is every rootless device's
        XCTAssertEqual(LogRedaction(home: "/var/mobile", installRoot: "/var/jb").redacted("/var/jb/usr/bin"), "/var/jb/usr/bin")
    }

    func testACutTextSaysHowLongItWas() {
        let long = String(repeating: "é", count: 3000)
        let cut = LogRedaction.truncated(long, limit: 1025)
        XCTAssertTrue(cut.hasSuffix("… [truncated from 6,000 bytes]"), cut)
        // cut on a character, never inside one
        XCTAssertTrue(cut.hasPrefix(String(repeating: "é", count: 512) + "…"))
        XCTAssertEqual(LogRedaction.truncated("short", limit: 1024), "short")
        XCTAssertEqual(LogRedaction(home: nil, installRoot: nil).text(long, limit: 10).utf8.count, 10 + "… [truncated from 6,000 bytes]".utf8.count)
        // a megabyte of output is redacted only as far as it is kept, and
        // says how long it was before anything was taken out
        let key = "ghp_" + String(repeating: "a1", count: 18)
        let output = key + " " + String(repeating: "x", count: 1_000_000)
        let kept = LogRedaction(home: nil, installRoot: nil).text(output, limit: 1024)
        XCTAssertTrue(kept.hasPrefix("<redacted> xxx") && kept.hasSuffix("… [truncated from 1,000,041 bytes]"), kept)
        // what redaction shortens below the bound is not cut
        XCTAssertEqual(LogRedaction(home: nil, installRoot: nil).text(key + "!", limit: 20), "<redacted>!")
        XCTAssertEqual(LogRedaction.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(LogRedaction.grouped(999), "999")
        XCTAssertEqual(LogRedaction.grouped(-1000), "-1,000")
    }
}
