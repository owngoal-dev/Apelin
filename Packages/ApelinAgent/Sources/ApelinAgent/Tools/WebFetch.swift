import Foundation
import KWWKAI

/// apelin_web_fetch: one public http or https page as text. The worker
/// fetches it itself, as mobile, with no host request, through a session
/// that keeps no cookie, cache or credential. An address on the local
/// network is refused before anything is sent (`PublicHost`), and so is
/// each redirect to one; a body is read up to 5 MB and answered 32 KB of
/// text at a time. What a page says is data the model reads, never
/// instructions.
struct WebFetch: Sendable {
    /// The most text, in UTF-8 bytes, one call answers.
    static let pageBytes = 32 * 1024
    /// The most of a body read; a longer page is cut there.
    static let maximumBodyBytes = 5 * 1024 * 1024
    static let maximumRedirects = 5
    /// For the whole call, its redirects included.
    static let timeoutSeconds = 30

    static let shared = WebFetch()

    private let session: URLSession

    /// A test hands in its own configuration; either way nothing is kept.
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Self.timeoutSeconds)
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Apelin",
            "Accept": "text/html, application/xhtml+xml, text/plain, text/markdown, application/json, application/xml;q=0.9, */*;q=0.5",
        ]
        session = URLSession(configuration: configuration, delegate: RedirectHold(), delegateQueue: nil)
    }

    /// The page `arguments` name, from their `offset` on.
    func fetch(_ arguments: JSONValue) async throws -> WebPage {
        let url = try Self.target(arguments.requireString("url"))
        let offset = max(0, arguments.argInt("offset") ?? 0)
        let session = session
        let body = try await Self.withinTimeout(url) { try await Self.load(url, session: session) }
        return try body.page(from: offset)
    }

    /// The page an address names, its fragment (never sent) dropped, or
    /// why it is not fetched; checked before anyone is asked.
    static func target(_ address: String) throws -> URL {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address) else {
            throw ToolArgumentError("url does not read as an address: \(address)")
        }
        if let refusal = refusal(url) {
            throw ToolArgumentError("not fetched: \(refusal); apelin_web_fetch reads public http and https pages")
        }
        return withoutFragment(url)
    }

    private static func withoutFragment(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? url
    }

    /// Why a URL, the first or one a redirect names, is not fetched, as a
    /// clause; nil for a public page.
    private static func refusal(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return "\(url.absoluteString) is not an http or https address"
        }
        guard url.user == nil, url.password == nil else {
            return "the address carries a user name or password"
        }
        guard let host = url.host, !host.isEmpty else {
            return "\(url.absoluteString) names no host"
        }
        return PublicHost.refusal(host)
    }

    /// Follows the redirects by hand, so each is checked before it is
    /// followed, and reads the page the last one leads to.
    private static func load(_ start: URL, session: URLSession) async throws -> FetchedPage {
        var url = start
        for _ in 0 ... maximumRedirects {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            guard let response = response as? HTTPURLResponse else {
                bytes.task.cancel()
                throw ToolDeniedError(message: "\(url.absoluteString) did not answer over HTTP")
            }
            guard (300 ... 399).contains(response.statusCode), response.statusCode != 304,
                  let location = response.value(forHTTPHeaderField: "Location")
            else {
                return try await read(bytes, response: response, url: url)
            }
            bytes.task.cancel()
            guard let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                throw ToolDeniedError(message: "not followed: \(url.absoluteString) redirects to \(location), which does not read as an address")
            }
            if let refusal = refusal(next) {
                throw ToolDeniedError(message: "not followed: \(url.absoluteString) redirects to \(next.absoluteString), but \(refusal)")
            }
            url = withoutFragment(next)
        }
        throw ToolDeniedError(message: "not followed: \(start.absoluteString) redirects more than \(maximumRedirects) times")
    }

    private static func read(_ bytes: URLSession.AsyncBytes, response: HTTPURLResponse, url: URL) async throws -> FetchedPage {
        defer { bytes.task.cancel() }
        let header = response.value(forHTTPHeaderField: "Content-Type")
        let type = header.flatMap(mediaType)
        let kind = kind(of: type)
        // Only a stated type is refused unread; with none, the body decides.
        guard let kind else {
            let size = response.expectedContentLength >= 0
                ? ByteCountFormatter.string(fromByteCount: response.expectedContentLength, countStyle: .file)
                : "of unknown size"
            throw ToolDeniedError(message: "not read: \(url.absoluteString) is \(type ?? ""), \(size); apelin_web_fetch reads text, HTML, JSON and XML")
        }
        var body: [UInt8] = []
        body.reserveCapacity(Int(min(Int64(maximumBodyBytes), max(0, response.expectedContentLength))))
        var truncated = false
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else {
                truncated = true
                break
            }
            body.append(byte)
        }
        // A type that says nothing of the body: text unless it holds a NUL.
        if kind == .unknown, body.prefix(8192).contains(0) {
            throw ToolDeniedError(message: "not read: \(url.absoluteString) is \(type ?? "of no stated type") and its body is not text")
        }
        let html = kind == .html
        let text = decode(body, charset: header.flatMap(charset), html: html)
        let page = html ? HTMLText(text, url: url) : nil
        return FetchedPage(
            url: url,
            status: response.statusCode,
            contentType: type,
            title: page?.title,
            text: page?.text ?? text,
            truncated: truncated,
        )
    }

    private enum Kind {
        case html, text
        /// No type, or `application/octet-stream`: read, then judged.
        case unknown
    }

    /// How a media type is read; nil for one that is not text.
    private static func kind(of type: String?) -> Kind? {
        guard let type, type != "application/octet-stream" else { return .unknown }
        if type == "text/html" || type == "application/xhtml+xml" {
            return .html
        }
        if type.hasPrefix("text/") || type.hasSuffix("+json") || type.hasSuffix("+xml") || textTypes.contains(type) {
            return .text
        }
        return nil
    }

    private static let textTypes: Set = [
        "application/json", "application/xml", "application/javascript", "application/ecmascript",
        "application/x-javascript", "application/yaml", "application/x-yaml", "application/toml",
        "application/x-sh", "application/x-ndjson", "application/sql", "application/graphql",
    ]

    /// `text/html; charset=utf-8` → `text/html`; nil for an empty one.
    private static func mediaType(_ header: String) -> String? {
        let type = header.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return type.isEmpty ? nil : type
    }

    /// The `charset` parameter of a Content-Type, a header's or a
    /// `<meta http-equiv>`'s.
    static func charset(_ contentType: String) -> String? {
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
            let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// The body as text: in the charset its header names, else the one an
    /// HTML page declares, else UTF-8 with an invalid byte replaced.
    static func decode(_ body: [UInt8], charset: String?, html: Bool) -> String {
        if let name = charset ?? (html ? HTMLText.declaredCharset(body) : nil),
           let encoding = encoding(named: name), encoding != .utf8,
           let text = String(bytes: body, encoding: encoding)
        {
            return text
        }
        var text = String(decoding: body, as: UTF8.self)
        if text.unicodeScalars.first == "\u{FEFF}" {
            text.unicodeScalars.removeFirst()
        }
        return text
    }

    private static func encoding(named name: String) -> String.Encoding? {
        let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }

    /// `body`, unless the call outlasts `timeoutSeconds`.
    private static func withinTimeout<T: Sendable>(
        _ url: URL,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(operation: body)
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw ToolTimeoutError(message: "\(url.absoluteString) did not answer within \(timeoutSeconds) seconds")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}

/// Hands every redirect back unfollowed, so `WebFetch.load` checks where
/// it leads first.
private final class RedirectHold: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
    ) async -> URLRequest? {
        nil
    }
}

/// A page as fetched, all of its text.
private struct FetchedPage {
    var url: URL
    var status: Int
    var contentType: String?
    var title: String?
    var text: String
    var truncated: Bool

    /// The 32 KB of text from `offset`, ended on a line break where one
    /// is near the end.
    func page(from offset: Int) throws -> WebPage {
        let utf8 = Array(text.utf8)
        guard offset == 0 || offset < utf8.count else {
            throw ToolArgumentError("offset \(offset) is past the end of the page's text, which is \(utf8.count) bytes")
        }
        var start = offset
        while start < utf8.count, utf8[start] & 0xC0 == 0x80 {
            start += 1
        }
        var end = min(start + WebFetch.pageBytes, utf8.count)
        if end < utf8.count {
            while end > start, utf8[end] & 0xC0 == 0x80 {
                end -= 1
            }
            if let newline = utf8[max(start, end - WebFetch.pageBytes / 8) ..< end].lastIndex(of: 0x0A) {
                end = newline + 1
            }
        }
        return WebPage(
            url: url.absoluteString,
            status: status,
            contentType: contentType,
            title: title,
            text: String(decoding: utf8[start ..< end], as: UTF8.self),
            offset: start,
            nextOffset: end < utf8.count ? end : nil,
            remainingBytes: utf8.count - end,
            truncated: truncated,
        )
    }
}

/// What one call answers: where the page ended up, how it answered, and a
/// stretch of its text.
struct WebPage: Sendable, Hashable {
    var url: String
    var status: Int
    var contentType: String?
    var title: String?
    var text: String
    var offset: Int
    /// Where the next call reads on; nil at the end of the text.
    var nextOffset: Int?
    var remainingBytes: Int
    /// The body was longer than `WebFetch.maximumBodyBytes` and cut there.
    var truncated: Bool

    /// As the model reads it, like file_read's: a line on the page, then
    /// its text, then where to go on.
    var answer: String {
        var lines = ["\(url) (HTTP \(status)\(contentType.map { ", \($0)" } ?? ""))"]
        if let title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        lines.append("")
        lines.append(text.isEmpty && offset == 0 ? "(no text: a page that script draws has none here)" : text)
        if let nextOffset {
            lines.append("… \(remainingBytes) more bytes of text; continue with offset \(nextOffset)")
        }
        if truncated {
            lines.append("… the page is longer than \(WebFetch.maximumBodyBytes / (1024 * 1024)) MB and was cut there")
        }
        return lines.joined(separator: "\n")
    }
}
