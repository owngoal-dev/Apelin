import Foundation

/// An NSError's localized description, taken back out of its `description`.
///
/// kwwk kept a transport failure as the error's whole `description` —
/// `Error Domain=NSURLErrorDomain Code=-1009 "The Internet connection
/// appears to be offline." UserInfo={…}`, the underlying errors and the
/// failing task with it — before 0.1.106, and still does for an error with
/// no text of its own (its sentence `(null)`); that is the text an agent
/// session's `error` event carries, and a session's log keeps the older
/// ones. A reader wants only the sentence in quotes.
public enum ErrorDescription {
    /// The quoted sentence of an NSError's `description`, or, where it
    /// was `(null)`, what `localizedDescription` says for its domain and
    /// code; any other text as it is.
    public static func localized(_ text: String) -> String {
        let domainPrefix = "Error Domain="
        guard text.hasPrefix(domainPrefix),
              let code = text.range(of: " Code="),
              let open = text.range(of: " \"", range: code.upperBound ..< text.endIndex),
              let number = Int(text[code.upperBound ..< open.lowerBound])
        else {
            return text
        }
        let rest = text[open.upperBound...]
        let close = rest.range(of: "\" UserInfo={")?.lowerBound
            ?? (rest.hasSuffix("\"") ? rest.index(before: rest.endIndex) : nil)
        guard let close else { return text }
        let sentence = rest[..<close]
        guard sentence.isEmpty || sentence == "(null)" else { return String(sentence) }
        let domain = String(text[text.index(text.startIndex, offsetBy: domainPrefix.count) ..< code.lowerBound])
        return NSError(domain: domain, code: number).localizedDescription
    }
}
