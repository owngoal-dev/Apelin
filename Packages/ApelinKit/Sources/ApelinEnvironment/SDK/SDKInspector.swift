import ApelinCore
import ApelinMachO
import ApelinProtocol
import CryptoKit
import Darwin
import Foundation

/// What an SDK says it is, read from its own files and never from a folder
/// name: Theos's `iPhoneOS16.5.sdk` is a 16.4.
public struct SDKIdentity: Sendable, Equatable {
    /// `SDKSettings.json` ▸ `CanonicalName`, e.g. `iphoneos27.0`.
    public var canonicalName: String
    /// `SDKSettings.json` ▸ `Version`, e.g. `27.0`.
    public var version: String
    /// `Foundation.tbd`'s targets, e.g. `arm64e-ios`.
    public var targets: [String]
    /// The Swift module interfaces' `swift-compiler-version`, when there are any.
    public var swiftCompilerVersion: String?
    public var warnings: [String]
}

/// What the inspection of a staged SDK found.
public struct SDKInspection: Sendable {
    public var identity: SDKIdentity
    /// SHA-256 over every entry, sorted by path: its kind, path, and content
    /// digest or link target.
    public var digest: String
    public var fileCount: Int
    public var byteCount: Int64
    public var warnings: [String]
}

/// Identifies and checks an SDK tree before it is registered. An SDK is a
/// compiler input: nothing in it is run or loaded. So:
///
/// - every path stays inside the root after `realpath`; a link that leads
///   out is refused (one that dangles inside is a warning);
/// - devices, FIFOs and sockets are refused;
/// - Mach-O is judged by its header type, never by the executable bit:
///   `MH_DYLIB`, `MH_DYLIB_STUB` and `MH_OBJECT` are link inputs and pass,
///   `MH_EXECUTE` (in any slice of a fat file, or as a member of a static
///   archive) and `MH_BUNDLE` and every other type are refused, with why;
/// - a static archive's members must each be `MH_OBJECT` (or not Mach-O).
public struct SDKInspector: Sendable {
    public var maximumDepth = 64

    public init() {}

    /// Finds the SDK root under `folder`: the folder itself or the one
    /// folder at most three levels down that holds `SDKSettings.json`.
    public func locateRoot(in folder: URL) throws -> URL {
        var found: [URL] = []
        func search(_ url: URL, depth: Int) {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return }
            if lstat(url.appendingPathComponent("SDKSettings.json").path, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFREG
            {
                found.append(url)
                return
            }
            guard depth < 3, let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() where name != "__MACOSX" && !name.hasPrefix(".") {
                search(url.appendingPathComponent(name, isDirectory: true), depth: depth + 1)
            }
        }
        search(folder, depth: 0)
        guard let root = found.first else {
            throw ApelinError(.badRequest, "No SDK found. Choose an SDK folder or archive.")
        }
        guard found.count == 1 else {
            throw ApelinError(
                .badRequest,
                "Multiple SDKs found: \(found.map(\.lastPathComponent).joined(separator: ", ")). Import one SDK at a time.",
            )
        }
        return root
    }

    // MARK: Identity

    public func identify(_ root: URL) throws -> SDKIdentity {
        let settingsURL = root.appendingPathComponent("SDKSettings.json")
        try requireInside(settingsURL, root: root)
        guard let data = FileManager.default.contents(atPath: settingsURL.path), data.count < 4 << 20,
              let settings = try? JSONCoding.decode(JSONValue.self, from: data)
        else {
            throw ApelinError(.badRequest, "The SDK settings file is damaged. Choose another SDK.")
        }
        guard let canonicalName = settings["CanonicalName"]?.stringValue, Self.isPlainName(canonicalName) else {
            throw ApelinError(.badRequest, "The SDK has no valid name. Choose another SDK.")
        }
        guard canonicalName.lowercased().hasPrefix("iphoneos") else {
            throw ApelinError(.badRequest, "\(canonicalName) is not an iPhoneOS SDK. Choose an iPhoneOS SDK.")
        }
        guard let version = settings["Version"]?.stringValue, !version.isEmpty, Self.isPlainName(version) else {
            throw ApelinError(.badRequest, "The SDK has no valid version. Choose another SDK.")
        }

        var warnings: [String] = []
        let tbd = root.appendingPathComponent("System/Library/Frameworks/Foundation.framework/Foundation.tbd")
        try requireInside(tbd, root: root)
        guard let tbdData = FileManager.default.contents(atPath: tbd.path), tbdData.count < 64 << 20 else {
            throw ApelinError(.badRequest, "The SDK is missing its Foundation framework. Choose another SDK.")
        }
        let targets = Self.tbdTargets(String(decoding: tbdData, as: UTF8.self))
        guard !targets.isEmpty else {
            throw ApelinError(.badRequest, "The SDK's Foundation framework is damaged. Choose another SDK.")
        }
        if !targets.contains("arm64-ios") {
            // The community 27.0 SDK lists only arm64e and arm64e.x1, and the
            // device's ld still links an arm64 slice against it.
            warnings.append("Foundation.tbd lists no arm64-ios target (\(targets.joined(separator: ", "))); arm64 links are unverified")
        }
        return SDKIdentity(
            canonicalName: canonicalName,
            version: version,
            targets: targets,
            swiftCompilerVersion: swiftCompilerVersion(root),
            warnings: warnings,
        )
    }

    /// `targets: [ a, b ]` of the first TBD document (v4 YAML, possibly over
    /// several lines), `archs` and `platform` of a v3 one (`arm64` and `ios`
    /// read as `arm64-ios`), or `target_info[].target` of a v5 JSON TBD.
    static func tbdTargets(_ text: String) -> [String] {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"),
           let json = try? JSONCoding.decode(JSONValue.self, from: Data(text.utf8)),
           case let .array(infos)? = json["target_info"]
        {
            return infos.compactMap { $0["target"]?.stringValue }
        }
        if let targets = yamlList("targets:", in: text) {
            return targets
        }
        // v3: the document's own `archs` come before any `exports` entry's.
        guard let archs = yamlList("\narchs:", in: text),
              let platformKey = text.range(of: "\nplatform:")
        else { return [] }
        let platform = text[platformKey.upperBound...].prefix { $0 != "\n" }
            .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard !platform.isEmpty else { return [] }
        return archs.map { "\($0)-\(platform)" }
    }

    /// The bracketed list after the first `key`, its items unquoted.
    private static func yamlList(_ key: String, in text: String) -> [String]? {
        guard let found = text.range(of: key) else { return nil }
        let rest = text[found.upperBound...]
        guard let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") else { return nil }
        return rest[rest.index(after: open) ..< close]
            .split(separator: ",")
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            .filter { !$0.isEmpty }
    }

    private func swiftCompilerVersion(_ root: URL) -> String? {
        let swift = root.appendingPathComponent("usr/lib/swift")
        let preferred = swift.appendingPathComponent("Swift.swiftmodule")
        for folder in [preferred, swift] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".swiftinterface") {
                let file = folder.appendingPathComponent(name)
                guard (try? requireInside(file, root: root)) != nil,
                      let handle = FileHandle(forReadingAtPath: file.path)
                else { continue }
                defer { try? handle.close() }
                let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
                for line in head.split(separator: "\n") where line.hasPrefix("// swift-compiler-version:") {
                    return line.dropFirst("// swift-compiler-version:".count).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    // MARK: Inspection

    /// Walks the whole tree: containment, file types, Mach-O types, digest.
    public func inspect(_ root: URL, reporter: TaskReporter = .silent) throws -> SDKInspection {
        let identity = try identify(root)
        guard let canonicalRoot = CanonicalPath.resolve(root.path) else {
            throw ApelinError(.notFound, "the SDK folder no longer exists")
        }
        var walk = Walk(root: URL(fileURLWithPath: canonicalRoot, isDirectory: true), reporter: reporter)
        try walk.directory("", depth: 0, maximumDepth: maximumDepth)
        try walk.checkFiles()
        walk.lines.sort()
        var hash = SHA256()
        for line in walk.lines {
            hash.update(data: Data((line + "\n").utf8))
        }
        var warnings = identity.warnings
        if walk.danglingLinks > 0 {
            warnings.append("\(walk.danglingLinks) symbolic links inside the SDK lead nowhere")
        }
        return SDKInspection(
            identity: identity,
            digest: TransferDigest.hex(hash.finalize()),
            fileCount: walk.files.count,
            byteCount: walk.byteCount,
            warnings: warnings,
        )
    }

    private struct Walk {
        let root: URL
        let reporter: TaskReporter
        var lines: [String] = []
        var files: [String] = []
        var byteCount: Int64 = 0
        var danglingLinks = 0
        let throttle = ProgressThrottle()

        init(root: URL, reporter: TaskReporter) {
            self.root = root
            self.reporter = reporter
        }

        mutating func directory(_ relative: String, depth: Int, maximumDepth: Int) throws {
            guard depth <= maximumDepth else { throw ApelinError(.badRequest, "\(relative) is nested too deep") }
            let url = relative.isEmpty ? root : root.appendingPathComponent(relative, isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
            for name in names {
                try reporter.checkCancelled()
                let path = relative.isEmpty ? name : relative + "/" + name
                let full = root.appendingPathComponent(path)
                var metadata = stat()
                guard lstat(full.path, &metadata) == 0 else { throw ArchiveExtractor.posix("read \(path)") }
                switch metadata.st_mode & S_IFMT {
                case S_IFDIR:
                    lines.append("d \(path)")
                    try directory(path, depth: depth + 1, maximumDepth: maximumDepth)
                case S_IFLNK:
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: full.path)
                    if let resolved = CanonicalPath.resolve(full.path) {
                        guard CanonicalPath.isCanonical(resolved, inside: root.path) else {
                            throw ApelinError(.denied, "\(path) links outside the SDK (\(target))")
                        }
                    } else {
                        // Dangling: judge the spelling. Absolute or climbing out is refused.
                        let lexical = full.deletingLastPathComponent()
                            .appendingPathComponent(target)
                            .standardizedFileURL.path
                        guard !target.hasPrefix("/"), CanonicalPath.isCanonical(lexical, inside: root.path) else {
                            throw ApelinError(.denied, "\(path) links outside the SDK (\(target))")
                        }
                        danglingLinks += 1
                    }
                    lines.append("l \(path) \(target)")
                case S_IFREG:
                    files.append(path)
                    byteCount += Int64(metadata.st_size)
                default:
                    throw ApelinError(.badRequest, "\(path) is a device, FIFO or socket")
                }
            }
        }

        /// Every regular file the walk found: its Mach-O policy check and
        /// digest, on several cores (each file is independent, and an SDK
        /// is tens of thousands of them). The lines are the ones a file at
        /// a time gives, and a refusal is the one the first refused file in
        /// walk order gives, whichever core met it first.
        mutating func checkFiles() throws {
            let files = files
            let root = root, reporter = reporter, throttle = throttle
            let results = ResultSlots(count: files.count)
            let done = Counter()
            DispatchQueue.concurrentPerform(iterations: Self.workers) { worker in
                var index = worker
                while index < files.count {
                    // Past a refusal no later file can change the answer.
                    if results.firstFailure.map({ $0 < index }) == true {
                        return
                    }
                    let path = files[index]
                    let full = root.appendingPathComponent(path)
                    results.set(index, Result {
                        try reporter.checkCancelled()
                        try MachOPolicy.check(full, relative: path)
                        return try "f \(path) \(Self.fileDigest(full, reporter: reporter))"
                    })
                    let count = done.increment()
                    if throttle.shouldEmit() {
                        reporter.progress("inspecting", completed: Int64(count), detail: path)
                    }
                    index += Self.workers
                }
            }
            for index in files.indices {
                try lines.append(results.get(index))
            }
        }

        static var workers: Int {
            min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        }

        static func fileDigest(_ url: URL, reporter: TaskReporter) throws -> String {
            guard let handle = FileHandle(forReadingAtPath: url.path) else {
                throw ArchiveExtractor.posix("open \(url.lastPathComponent)")
            }
            defer { try? handle.close() }
            var hash = SHA256()
            while true {
                let chunk = try autoreleasepool { try handle.read(upToCount: 1 << 20) } ?? Data()
                if chunk.isEmpty {
                    break
                }
                hash.update(data: chunk)
                try reporter.checkCancelled()
            }
            return TransferDigest.hex(hash.finalize())
        }
    }

    // MARK: Helpers

    private func requireInside(_ url: URL, root: URL) throws {
        guard let resolvedRoot = CanonicalPath.resolve(root.path) else {
            throw ApelinError(.notFound, "the SDK folder no longer exists")
        }
        guard let resolved = CanonicalPath.resolve(url.path) else { return }
        guard CanonicalPath.isCanonical(resolved, inside: resolvedRoot) else {
            throw ApelinError(.denied, "\(url.lastPathComponent) leads outside the SDK")
        }
    }

    /// A name safe as part of a folder name: letters, digits, `.`, `_`, `-`.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && !name.hasPrefix(".")
            && name.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0)
            }
    }
}

/// One answer per file, written by whichever core checked it, and the
/// lowest index that failed.
private final class ResultSlots: @unchecked Sendable {
    private let lock = PthreadLock()
    private var slots: [Result<String, Error>?]
    private var failure: Int?

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    var firstFailure: Int? {
        lock.withLock { failure }
    }

    func set(_ index: Int, _ result: Result<String, Error>) {
        lock.withLock {
            slots[index] = result
            if case .failure = result, failure.map({ index < $0 }) ?? true {
                failure = index
            }
        }
    }

    /// The answer for `index`; every one before the first failure is set.
    @objc dynamic func get(_ index: Int) throws -> String {
        let slot = lock.withLock { slots[index] }
        guard let slot else { throw ApelinError(.internal, "file \(index) was not inspected") }
        return try slot.get()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = PthreadLock()
    @objc private dynamic var value = 0
    @objc dynamic func increment() -> Int {
        lock.withLock { value += 1; return value }
    }
}

#if !canImport(ObjectiveC)
    private func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T {
        try body()
    }
#endif

/// Mach-O by header type, for files an SDK may carry.
enum MachOPolicy {
    static let maximumSliceBytes: Int64 = 1 << 30
    static let maximumArchiveMembers = 100_000

    /// Throws `denied` for a Mach-O type an SDK may not carry.
    static func check(_ url: URL, relative: String) throws {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw ArchiveExtractor.posix("open \(relative)")
        }
        defer { try? handle.close() }
        let head = [UInt8](handle.readData(ofLength: 8))
        guard head.count >= 4 else { return }
        if head.starts(with: Array("!<arch>\n".utf8)) {
            try checkArchive(handle, offset: 0, size: Int64(handle.seekToEndOfFile()), relative: relative)
            return
        }
        if isMachOMagic(head) {
            let image: MachOImage
            do {
                image = try MachOImage(contentsOfFile: url.path)
            } catch {
                throw ApelinError(.denied, "\(relative) is a damaged Mach-O file (\(error))")
            }
            try image.slices.forEach { try checkSlice($0.fileType, $0.architecture, relative) }
            return
        }
        switch head.prefix(4) {
        case [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]:
            try checkFat(url, handle: handle, sixtyFour: head[3] == 0xBF, relative: relative)
        default:
            return
        }
    }

    static func isMachOMagic(_ bytes: [UInt8]) -> Bool {
        switch Array(bytes.prefix(4)) {
        case [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE]:
            true
        default:
            false
        }
    }

    private static func checkSlice(_ type: MachOImage.FileType?, _ architecture: String, _ relative: String) throws {
        switch type {
        case .dynamicLibrary?, .dynamicLibraryStub?, .object?:
            return
        case .executable?:
            throw ApelinError(
                .denied,
                "\(relative) is an executable (MH_EXECUTE, \(architecture)); an SDK holds link inputs only",
            )
        case .bundle?:
            throw ApelinError(
                .denied,
                "\(relative) is a loadable bundle (MH_BUNDLE, \(architecture)); an SDK holds link inputs only",
            )
        case let other?:
            throw ApelinError(.denied, "\(relative) is a Mach-O type an SDK does not carry (\(other), \(architecture))")
        case nil:
            throw ApelinError(.denied, "\(relative) is a Mach-O file of an unknown type (\(architecture))")
        }
    }

    /// A fat file: Mach-O slices through MachOImage, static-archive slices
    /// member by member. `0xCAFEBABE` with many "architectures" is a Java
    /// class file, not Mach-O.
    private static func checkFat(_: URL, handle: FileHandle, sixtyFour: Bool, relative: String) throws {
        handle.seek(toFileOffset: 4)
        let countBytes = [UInt8](handle.readData(ofLength: 4))
        guard countBytes.count == 4 else { return }
        let count = countBytes.reduce(0) { $0 << 8 | Int($1) }
        guard count > 0, count <= 64 else { return }
        let entrySize = sixtyFour ? 32 : 20
        let table = [UInt8](handle.readData(ofLength: count * entrySize))
        guard table.count == count * entrySize else { throw ApelinError(.denied, "\(relative) is a damaged fat file") }
        let fileSize = Int64(handle.seekToEndOfFile())
        func big(_ at: Int, _ width: Int) -> Int64 {
            table[at ..< at + width].reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
        for index in 0 ..< count {
            let base = index * entrySize
            let offset = sixtyFour ? big(base + 8, 8) : big(base + 8, 4)
            let size = sixtyFour ? big(base + 16, 8) : big(base + 12, 4)
            guard offset > 0, size > 0, offset + size <= fileSize, size <= maximumSliceBytes else {
                throw ApelinError(.denied, "\(relative) is a damaged fat file")
            }
            handle.seek(toFileOffset: UInt64(offset))
            let magic = [UInt8](handle.readData(ofLength: 8))
            if magic.starts(with: Array("!<arch>\n".utf8)) {
                try checkArchive(handle, offset: offset, size: size, relative: relative)
            } else if !Self.isMachOMagic(magic) {
                // Not code for any CPU: a fat `.metallib` holds one Metal
                // library per GPU family (`MTLB`), and the iOS SDKs carry
                // them inside frameworks. Nothing here can be executed.
                continue
            } else {
                handle.seek(toFileOffset: UInt64(offset))
                let slice = handle.readData(ofLength: Int(size))
                let image: MachOImage
                do {
                    image = try MachOImage(data: slice)
                } catch {
                    throw ApelinError(.denied, "\(relative) has a slice that is not Mach-O or is damaged (\(error))")
                }
                try image.slices.forEach { try checkSlice($0.fileType, $0.architecture, relative) }
            }
        }
    }

    /// A static archive (`ar`, BSD or SysV names): every member that is
    /// Mach-O must be an object file.
    private static func checkArchive(_ handle: FileHandle, offset start: Int64, size: Int64, relative: String) throws {
        var cursor = start + 8
        let end = start + size
        var members = 0
        while cursor + 60 <= end {
            handle.seek(toFileOffset: UInt64(cursor))
            let header = handle.readData(ofLength: 60)
            guard header.count == 60,
                  header[header.startIndex + 58] == 0x60,
                  header[header.startIndex + 59] == 0x0A
            else {
                throw ApelinError(.denied, "\(relative) is a damaged static archive")
            }
            let name = String(decoding: header.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard let memberSize = Int64(String(decoding: header[header.startIndex + 48 ..< header.startIndex + 58], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)), memberSize >= 0, cursor + 60 + memberSize <= end
            else {
                throw ApelinError(.denied, "\(relative) is a damaged static archive")
            }
            members += 1
            guard members <= maximumArchiveMembers else {
                throw ApelinError(.denied, "\(relative) has too many members")
            }
            var dataStart = cursor + 60
            var dataSize = memberSize
            var memberName = name
            if name.hasPrefix("#1/"), let nameLength = Int64(name.dropFirst(3)), nameLength <= memberSize {
                handle.seek(toFileOffset: UInt64(dataStart))
                memberName = String(decoding: handle.readData(ofLength: Int(nameLength)), as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                dataStart += nameLength
                dataSize -= nameLength
            }
            let isSymbolTable = memberName.hasPrefix("__.SYMDEF") || memberName == "/" || memberName == "//"
            if !isSymbolTable, dataSize >= 4 {
                handle.seek(toFileOffset: UInt64(dataStart))
                let magic = [UInt8](handle.readData(ofLength: 4))
                if isMachOMagic(magic) {
                    guard dataSize <= maximumSliceBytes else {
                        throw ApelinError(.denied, "\(relative) has a member too large to check")
                    }
                    handle.seek(toFileOffset: UInt64(dataStart))
                    let data = handle.readData(ofLength: Int(dataSize))
                    let image: MachOImage
                    do {
                        image = try MachOImage(data: data)
                    } catch {
                        throw ApelinError(.denied, "\(relative)(\(memberName)) is a damaged Mach-O member (\(error))")
                    }
                    for slice in image.slices where slice.fileType != .object {
                        if slice.fileType == .executable {
                            throw ApelinError(
                                .denied,
                                "\(relative)(\(memberName)) is an executable (MH_EXECUTE) inside a static archive",
                            )
                        }
                        throw ApelinError(
                            .denied,
                            "\(relative)(\(memberName)) is not an object file inside a static archive",
                        )
                    }
                }
            }
            cursor += 60 + memberSize + (memberSize % 2)
        }
    }
}
