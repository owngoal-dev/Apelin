import CryptoKit
import Foundation

public struct ToolchainCatalog: Sendable {
    public static let appleCatalog = URL(string: "https://swscan.apple.com/content/catalogs/others/index-27-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog")!
    public let url: URL
    public init(url: URL = Self.appleCatalog) {
        self.url = url
    }

    public func list() async throws -> [ToolchainSource] {
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData),
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 64 * 1024 * 1024 else {
            throw ToolchainFailure("Unable to read the software update catalog. Try again.")
        }
        let (sources, products) = try Self.parse(data)
        // Each product's distribution names its version: fetched side by
        // side (a dozen small requests), one at a time they were most of the
        // catalog's six seconds on a device.
        let distributions: [(Int, URL)] = try sources.enumerated().compactMap { index, source in
            guard let distributions = products[source.productID]?["Distributions"] as? [String: String],
                  let address = distributions["English"],
                  var parts = URLComponents(string: address),
                  parts.host?.hasSuffix(".apple.com") == true else { return nil }
            parts.scheme = "https"
            guard let url = parts.url else { throw ToolchainFailure("Invalid distribution URL") }
            return (index, url)
        }
        let versions = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for (index, url) in distributions {
                group.addTask { try await (index, Self.distributionVersion(url)) }
            }
            var versions: [Int: String] = [:]
            for try await (index, version) in group {
                versions[index] = version
            }
            return versions
        }
        var result: [ToolchainSource] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            result.append(.init(
                productID: source.productID,
                version: versions[index] ?? source.version,
                url: source.url,
                size: source.size,
                upstreamDigest: source.upstreamDigest,
                upstreamDigestAlgorithm: source.upstreamDigestAlgorithm,
            ))
        }
        return CommandLineToolsSupport.catalog(adding: result)
    }

    /// The version a product's English distribution names, or nil.
    static func distributionVersion(_ url: URL) async throws -> String? {
        let (metadata, response) = try await URLSession.shared.data(
            for: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData),
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200, metadata.count < 2 * 1024 * 1024 else {
            throw ToolchainFailure("Unable to read the Command Line Tools details from Apple. Try again.")
        }
        let text = String(decoding: metadata, as: UTF8.self)
        let pattern = #"(?:Command Line Tools (?:for Xcode )?|\"SU_VERS\"\s*=\s*\")([0-9]+(?:\.[0-9]+)*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func parse(_ data: Data) throws -> (sources: [ToolchainSource], products: [String: [String: Any]]) {
        guard
            let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let products = root["Products"] as? [String: [String: Any]]
        else {
            throw ToolchainFailure("The software update catalog is in an unsupported format.")
        }
        var results: [ToolchainSource] = []
        for (id, product) in products {
            for package in product["Packages"] as? [[String: Any]] ?? [] {
                guard
                    let text = package["URL"] as? String,
                    var parts = URLComponents(string: text),
                    parts.path.hasSuffix("/CLTools_Executables.pkg"),
                    let size = package["Size"] as? NSNumber
                else { continue }
                parts.scheme = "https"
                guard let url = parts.url, url.host?.hasSuffix(".apple.com") == true else { continue }
                let metadata = product["ExtendedMetaInfo"] as? [String: Any] ?? [:]
                let version = metadata["ProductVersion"] as? String ?? metadata["Version"] as? String
                    ?? CommandLineToolsSupport.unknownVersion
                let digest = (package["Digest"] as? String) ?? (package["Digest"] as? Data).map { hex($0) }
                results.append(.init(
                    productID: id,
                    version: version,
                    url: url,
                    size: size.int64Value,
                    upstreamDigest: digest,
                    upstreamDigestAlgorithm: digest == nil ? nil : "xar-toc-sha1",
                ))
            }
        }
        return (results.sorted { $0.productID > $1.productID }, products)
    }
}

enum ResumableDownload {
    struct Receipt: Codable {
        let source: ToolchainSource; let validator: String?; let bytes: Int64; let prefixSHA256: String
    }

    static func run(
        _ source: ToolchainSource,
        in staging: URL,
        progress: ToolchainProgressHandler,
        session: URLSession = .shared,
        rangeBytes: Int64 = Self.rangeBytes,
        parallelRanges: Int = Self.parallelRanges,
    ) async throws -> URL {
        guard source.url.scheme == "https", source.size > 0, source.size <= 8 * 1024 * 1024 * 1024 else {
            throw ToolchainFailure("The download details for this toolchain are invalid. Choose another toolchain.")
        }
        let file = staging.appendingPathComponent("source.pkg"),
            record = staging.appendingPathComponent("download.json")
        var offset: Int64 = 0
        var validator: String?
        // The verified prefix's hash, read once and carried on as each range is written.
        var prefixHash = SHA256()
        if let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: record)),
           receipt.source == source,
           let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
           (attrs[.size] as? NSNumber)?.int64Value == receipt.bytes
        {
            let prefix = try FileHandle(forReadingFrom: file)
            defer { try? prefix.close() }
            while let data = try autoreleasepool(invoking: { try prefix.read(upToCount: 1024 * 1024) }), !data.isEmpty {
                try Task.checkCancellation(); prefixHash.update(data: data)
            }
            if hex(prefixHash.finalize()) == receipt.prefixSHA256 {
                offset = receipt.bytes; validator = receipt.validator
            }
        }
        if offset == 0 {
            prefixHash = SHA256()
            try Data().write(to: file, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        // Explicit small range requests bound memory and give durable checkpoints, including after
        // disconnects. Up to `parallelRanges` are in flight at once: Apple's CDN serves one
        // connection at about half what four do (15.6 against 33 MB/s on an iPhone 15 Pro).
        // A batch is written, hashed and checkpointed in order once all of it has arrived, so
        // the receipt still only ever names a verified, contiguous prefix.
        while offset < source.size {
            try Task.checkCancellation()
            // The first range alone when no validator is known yet: every later one is asked
            // with If-Range against the validator it answered.
            let width = validator == nil ? 1 : parallelRanges
            var ranges: [(Int64, Int64)] = []
            var next = offset
            while ranges.count < width, next < source.size {
                let end = min(next + rangeBytes, source.size) - 1
                ranges.append((next, end)); next = end + 1
            }
            let known = validator
            let parts = try await withThrowingTaskGroup(of: (Int, Data, HTTPURLResponse).self) { group in
                for (index, range) in ranges.enumerated() {
                    group.addTask {
                        let (data, response) = try await fetch(
                            source.url,
                            from: range.0,
                            to: range.1,
                            validator: range.0 > 0 ? known : nil,
                            session: session,
                        )
                        return (index, data, response)
                    }
                }
                var parts = [(Data, HTTPURLResponse)?](repeating: nil, count: ranges.count)
                for try await (index, data, response) in group {
                    parts[index] = (data, response)
                }
                return parts.map { $0! }
            }
            for ((start, end), (data, response)) in zip(ranges, parts) {
                let newValidator = response.value(forHTTPHeaderField: "ETag")
                    ?? response.value(forHTTPHeaderField: "Last-Modified")
                // Only a whole answer, or a partial one under another validator, says the package
                // changed. Any other refusal (a 429, a 403) keeps the verified prefix for a retry.
                if start > 0, response.statusCode == 200 || (response.statusCode == 206 && newValidator != validator) {
                    try handle.truncate(atOffset: 0)
                    try? FileManager.default.removeItem(at: record)
                    throw ToolchainFailure("The package changed on the server. Try again to download the new version.")
                }
                guard
                    response.statusCode == 206,
                    response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(source.size)",
                    data.count == end - start + 1
                else {
                    throw ToolchainFailure("The download server sent an unexpected response. Try again.")
                }
                try handle.seek(toOffset: UInt64(start)); try handle.write(contentsOf: data); try handle.synchronize()
                prefixHash.update(data: data)
                offset = end + 1; validator = newValidator
                let checkpointDigest = hex(prefixHash.finalize())
                try writeJSON(
                    Receipt(source: source, validator: validator, bytes: offset, prefixSHA256: checkpointDigest),
                    to: record,
                )
            }
            progress(.init(
                stage: .downloading,
                completedBytes: offset,
                totalBytes: source.size,
                detail: source.productID,
            ))
        }
        if let digest = source.upstreamDigest {
            guard source.upstreamDigestAlgorithm == "xar-toc-sha1" else {
                throw ToolchainFailure("Unsupported upstream digest algorithm")
            }
            let reader = try BinaryReader(file)
            let header = try reader.read(28)
            guard header.prefix(4) == Data("xar!".utf8) else {
                throw ToolchainFailure("The downloaded package format is not supported. Choose another toolchain.")
            }
            let length = try header.number(8, as: UInt64.self, big: true)
            guard length <= 16 * 1024 * 1024 else {
                throw ToolchainFailure(
                    "The downloaded package index exceeds the size limit. Choose another toolchain.",
                )
            }
            try reader.seek(UInt64(header.number(4, as: UInt16.self, big: true)))
            let actual = try hex(Insecure.SHA1.hash(data: reader.read(Int(length))))
            guard actual == digest.lowercased() else {
                try handle.truncate(atOffset: 0)
                try? FileManager.default.removeItem(at: record)
                throw ToolchainFailure(
                    "The downloaded package failed its integrity check. Try again to start a fresh download.",
                )
            }
        }
        return file
    }

    /// Ranges in flight at once, and the size of each.
    static let parallelRanges = 4
    static let rangeBytes: Int64 = 8 * 1024 * 1024

    /// One range, retried as before: a 5xx is retried, a non-206 answer is handed back for the
    /// caller to judge, and a body longer than asked for is refused as it arrives.
    static func fetch(
        _ url: URL,
        from start: Int64,
        to end: Int64,
        validator: String?,
        session: URLSession,
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let validator {
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        for attempt in 0 ..< 4 {
            do {
                let receiver = RangeReceiver(expected: Int(end - start + 1))
                let (data, response) = try await receiver.run(request, session: session)
                guard let http = response as? HTTPURLResponse else {
                    throw ToolchainFailure("The download server sent an invalid response. Try again.")
                }
                if http.statusCode >= 500 {
                    throw ToolchainFailure("Apple's download service is unavailable. Try again later.")
                }
                return (http.statusCode == 206 ? data : Data(), http)
            } catch {
                try Task.checkCancellation()
                if attempt == 3 {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000)
            }
        }
        throw ToolchainFailure("The package download failed. Try again.")
    }
}

/// Collects one range's body as the session delivers it, in the chunks it arrives in rather
/// than byte by byte (which cost a core on a device), and cancels the request the moment it
/// grows past the size asked for, so a body is never held beyond its range.
private final class RangeReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expected: Int
    private let lock = NSLock()
    private var data = Data()
    @objc private dynamic var response: URLResponse?
    @objc private dynamic var overrun = false
    @objc private dynamic var rejected = false
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    /// The answer, once the request completed. A request cancelled before `run` stored its
    /// continuation can complete first; `run` then answers with this instead of waiting.
    private var outcome: Result<(Data, URLResponse), Error>?

    init(expected: Int) {
        self.expected = expected
        data.reserveCapacity(expected)
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let task = session.dataTask(with: request)
        task.delegate = self
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let outcome = lock.withLock {
                    if self.outcome == nil {
                        self.continuation = continuation
                    }
                    return self.outcome
                }
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    task.resume()
                }
            }
        } onCancel: { task.cancel() }
    }

    @objc dynamic func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
    ) {
        // Anything but a partial answer is judged by its status and headers alone: its body
        // (a whole package, for a 200) is never read.
        let partial = (response as? HTTPURLResponse)?.statusCode == 206
        lock.withLock {
            self.response = response
            if !partial {
                rejected = true
            }
        }
        completionHandler(partial ? .allow : .cancel)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let over = lock.withLock { () -> Bool in
            guard !overrun else { return true }
            if data.count + chunk.count > expected {
                overrun = true; return true
            }
            data.append(chunk)
            return false
        }
        if over {
            dataTask.cancel()
        }
    }

    @objc dynamic func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, result) = lock.withLock { () -> (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) in
            let result: Result<(Data, URLResponse), Error> =
                if overrun {
                    .failure(ToolchainFailure("The download server sent an unexpected response. Try again."))
                } else if rejected, let response {
                    .success((Data(), response))
                } else if let error {
                    .failure(error)
                } else if let response {
                    .success((data, response))
                } else {
                    .failure(ToolchainFailure("The download server sent an invalid response. Try again."))
                }
            outcome = result
            defer { self.continuation = nil }
            return (self.continuation, result)
        }
        continuation?.resume(with: result)
    }
}
