import Foundation

/// The composer's Web capture takes an address as people type it
/// (`WebAddress`): without a scheme it is https, and what names no page is
/// refused before anything loads.
func checkWebAddress() {
    func address(_ typed: String) -> String? {
        WebAddress.url(from: typed)?.absoluteString
    }

    precondition(address("example.com") == "https://example.com", "a bare host is https")
    precondition(address("  www.apple.com/iphone/\n") == "https://www.apple.com/iphone/", "white space around it goes")
    precondition(address("example.com/page?q=1#top") == "https://example.com/page?q=1#top")
    precondition(address("//example.com/x") == "https://example.com/x")
    precondition(address("localhost:8080/x") == "https://localhost:8080/x")
    precondition(address("203.0.113.10/status") == "https://203.0.113.10/status")
    precondition(address("http://example.com/a") == "http://example.com/a", "a typed scheme is kept")
    precondition(address("https://example.com") == "https://example.com")
    precondition(WebAddress.url(from: "HTTPS://Example.com/A")?.scheme?.lowercased() == "https")
    precondition(address("http://intranet/wiki") == "http://intranet/wiki", "with a scheme, any host")

    let escaped = address("example.com/维基?q=百科")
    precondition(escaped?.hasPrefix("https://example.com/%E7%BB%B4%E5%9F%BA?q=") == true, "\(escaped ?? "nil")")
    precondition(address("example.com/a%20b") == "https://example.com/a%20b", "its own escapes are kept")

    for refused in [
        "", "   ", "https://", "apelin", "two words", "example.com/a b",
        "ftp://example.com/file", "file:///etc/passwd", "javascript:alert(1)",
        "mailto:someone@example.com", "user:secret@example.com", "https://user:secret@example.com/",
        "tel:+123456", "apelin://chat?prompt=hi",
    ] {
        precondition(address(refused) == nil, "\(refused) names no page: \(address(refused) ?? "")")
    }
    print("ok: a web address typed without a scheme is https, another scheme, a word or a credential is refused")
}
