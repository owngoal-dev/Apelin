import ApelinCore
import Foundation
import XCTest

/// What a review of the journal's redaction found it let through, or took
/// too long over (issue #27): each case is one a log must not carry.
final class LogRedactionAttackTests: XCTestCase {
    private let redaction = LogRedaction(home: "/var/mobile", installRoot: "/var/jb")

    /// Runs of what no rule finds, each as long as a dump a tool prints.
    private func adversarial(_ unit: String, bytes: Int = 256 * 1024) -> String {
        String(repeating: unit, count: bytes / unit.utf8.count)
    }

    func testEveryRuleIsLinearOnLongRunsThatAreNoMatch() {
        // one slow rule is enough to know: a quadratic one takes minutes
        continueAfterFailure = false
        let inputs = [
            adversarial("0123456789abcdef"), // xxd -p, ioreg -l
            adversarial("a.b-c_d+e%"), // what an address is made of, with no @
            adversarial("eyJhbGciOi"), // base64 that keeps starting a token
            adversarial("ab.ab.ab.ab."), // a name of endless labels
            adversarial("key=ab key=ab "),
            adversarial("x:"),
            adversarial("A1B2C3D4E5F6G7H8"),
            adversarial("fd12:"),
        ]
        for input in inputs {
            var start = Date()
            _ = redaction.text(input, limit: 1024)
            let cut = Date().timeIntervalSince(start)
            XCTAssertLessThan(cut, 0.1, "a 256 KB text cut to 1 KB: \(input.prefix(16))")
            start = Date()
            _ = redaction.redacted(input)
            let whole = Date().timeIntervalSince(start)
            XCTAssertLessThan(whole, 2, "the whole of a 256 KB text, read once: \(input.prefix(16))")
        }
    }

    func testSecretsInsideJSONAndQuotedValuesAreTakenOut() {
        let texts = [
            #"{"apiKey": "q9w8e7r6t5y4u3i2", "password": "hunter2hunter2"}"#,
            #"{\"apiKey\":\"q9w8e7r6t5y4u3i2\",\"password\":\"hunter2hunter2\"}"#,
            #"password = "correct horse battery staple""#,
            #"PASSWORD='hunter2hunter2'"#,
        ]
        for text in texts {
            let kept = redaction.redacted(text)
            for secret in ["q9w8e7r6t5y4u3i2", "hunter2hunter2", "horse battery"] {
                XCTAssertFalse(kept.contains(secret), "\(secret) survived: \(kept)")
            }
        }
    }

    func testSecretsNamedTheWaysProgramsNameThemAreTakenOut() {
        let output = """
        {"authToken": "a1b2c3d4e5f6", "apiToken": "tok123456789", "sessionToken": "sess98765432"}
        {"secretKey": "sk123456789", "privateKey": "pk123456789", "apiSecret": "as123456789"}
        AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
        DB_PASS=dbpass5551234 MYSQL_PASSWORD=mysql5551234 GITLAB_TOKEN=gltok5551234
        mysql --password hunter3hunter3 --user root
        curl -u admin:curlpass5551234 https://example.com
        Cookie: session=cookie5551234; theme=dark
        Set-Cookie: id=setcookie5551234; Path=/
        Authorization: token 0123456789abcdef0123456789abcdef01234567
        xai-\(String(repeating: "x1", count: 20)) glpat-\(String(repeating: "g2", count: 12))
        hf_\(String(repeating: "h3", count: 15)) gsk_\(String(repeating: "q4", count: 15))
        sk_live_\(String(repeating: "s5", count: 12)) rk_live_\(String(repeating: "r6", count: 12))
        """
        let kept = redaction.redacted(output)
        let secrets = [
            "a1b2c3d4e5f6", "tok123456789", "sess98765432", "sk123456789", "pk123456789", "as123456789",
            "wJalrXUtnFEMI", "dbpass5551234", "mysql5551234", "gltok5551234", "hunter3hunter3", "curlpass5551234",
            "cookie5551234", "setcookie5551234", "0123456789abcdef0123", "x1x1x1", "g2g2g2", "h3h3h3", "q4q4q4",
            "s5s5s5", "r6r6r6",
        ]
        for secret in secrets {
            XCTAssertFalse(kept.contains(secret), "\(secret) survived:\n\(kept)")
        }
        // what names no secret stays
        XCTAssertTrue(kept.contains("--user root"), kept)
        XCTAssertTrue(redaction.redacted("max_tokens: 4000, passed: 1234, author: Lakr").contains("max_tokens: 4000, passed: 1234"))
    }

    func testDeviceAndNetworkIdentifiersAreTakenOut() {
        let text = """
        UDID 00008030-00112233445566AA and \(String(repeating: "a1b2c3d4e5", count: 4))
        serial AB12CD34EF56, MAC 02:00:00:00:00:01
        ssh to 192.168.1.20, 10.0.0.5:2222 and fe80::1c2b:3a4d:5e6f:7a8b%en0
        Adas-iPhone.local and router.home.arpa, /home/someone/x
        /private/preboot/6F8C2E1A9B3D4C5E6F708192A3B4C5D6/jb-AbCd1234/procursus
        """
        let kept = redaction.redacted(text)
        let identifiers = [
            "00008030-00112233445566AA", "a1b2c3d4e5a1b2c3d4e5", "AB12CD34EF56", "02:00:00:00:00:01", "192.168.1.20",
            "10.0.0.5", "fe80::1c2b", "Adas-iPhone", "router.home.arpa", "someone", "6F8C2E1A9B3D4C5E", "AbCd1234",
        ]
        for identifier in identifiers {
            XCTAssertFalse(kept.contains(identifier), "\(identifier) survived:\n\(kept)")
        }
        // what every device's says goes through
        XCTAssertEqual(redaction.redacted("clang listened on 127.0.0.1, CLT 15.3"), "clang listened on 127.0.0.1, CLT 15.3")
    }
}
