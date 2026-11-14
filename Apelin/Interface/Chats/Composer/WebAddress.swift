import Foundation

/// The address the composer's Web capture loads, from what the reader typed.
///
/// Most addresses are typed without a scheme, the more so while the
/// field's placeholder was `https://`, which read as if the scheme were
/// there already. Such an address is taken as https (#61: every one was
/// refused as invalid, so the capture "failed every time").
enum WebAddress {
    /// The page to load, or nil for text that names none: another scheme,
    /// a name and password, white space inside it, or, with no scheme
    /// typed, a single word, which is a search rather than a host.
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        let scheme = text.range(of: "://").map { text[..<$0.lowerBound].lowercased() }
        if let scheme, scheme != "http", scheme != "https" {
            return nil
        }
        let address = scheme == nil ? "https://" + text.drop { $0 == "/" } : text
        guard let url = URL(string: address) ?? URL(string: escaped(address)),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              scheme != nil || host.contains(".") || host.contains(":") || host == "localhost"
        else {
            return nil
        }
        return url
    }

    /// `address` with every character a URL cannot hold percent-encoded and
    /// its own escapes kept, for a system whose `URL(string:)` refuses them
    /// (before iOS 17).
    private static func escaped(_ address: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'()*+,-./:;=?@[]_~",
        )
        return address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address
    }
}
