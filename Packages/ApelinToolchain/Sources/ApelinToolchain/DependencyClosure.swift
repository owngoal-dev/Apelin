import Foundation

struct DependencyClosure {
    /// The tools a build or a user runs by name, and the siblings two of them
    /// exec by path beside themselves, which no load command names (scheme 3):
    /// `otool` (llvm-otool) execs otool-classic for every flag it takes, and
    /// `ar` execs `ranlib` (libtool, which acts as ranlib by its name) for
    /// its `s` modifier, so `ar rcs`. Every reviewed release has both.
    /// Left out: llvm-otool's `-objdump` execs llvm-objdump (14.2's and
    /// 15.3's load libxar, which iOS lacks), and 15.3's ld and strip exec
    /// ld-classic, an ld64 that loads libxar, for `ld -ld_classic` and for
    /// strip's `-x`, `-S`, `-u` or `-r` on an object file (15.0 and 16.4
    /// ship one too). See the research document ▸ Retarget scheme 3.
    static let entryTools = [
        "clang", "ld", "lipo", "dsymutil", "strip", "ar", "ranlib", "libtool", "nm", "otool", "llvm-otool",
        "otool-classic",
    ]
    /// What the Swift tools read beside themselves: the host libraries and
    /// macro plugins the frontend loads (`host/`), and API notes.
    static let swiftResources = ["usr/lib/swift/host", "usr/lib/swift/apinotes"]
    /// libSwiftScan (170 MB, a second compiler) serves explicit module builds,
    /// which `swiftc` does not ask for; it stays out.
    static let swiftExcluded: Set<String> = [
        "usr/lib/swift/host/compiler/lib_InternalSwiftScan.dylib",
        "usr/lib/swift/host/lib_InternalSwiftScan.dylib",
    ]
    /// Links the Swift component keeps as links: the driver names, which the
    /// frontend tells apart by `argv[0]`, and the clang resource folder Swift's
    /// importer reads through `usr/lib/swift/clang`.
    static let swiftLinks = ["usr/bin/swiftc", "usr/bin/swift", "usr/lib/swift/clang"]
    let root: URL
    let components: Set<ToolchainComponent>
    /// dyld searches an image's `@rpath` through its own run paths, then those of
    /// every image that loaded it (the Swift compiler libraries have none of their
    /// own and rely on swift-frontend's), each already expanded to a path below
    /// the root. Filled by `select`, read by `resolve`.
    private var inherited: [String: [String]] = [:]

    init(root: URL, components: Set<ToolchainComponent>) {
        self.root = root
        self.components = components
    }

    /// Output-relative name → canonical source file. Aliases are copied as files, never external links.
    mutating func select() throws -> [String: URL] {
        var selected: [String: URL] = [:]
        var pending = Self.entryTools.map { "usr/bin/" + $0 }
        if components.contains(.swift) {
            pending.append("usr/bin/swift-frontend")
            // Older frontends integrate the driver and use a plugin server.
            let helper =
                FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/bin/swift-driver").path)
                    ? "swift-driver" : "swift-plugin-server"
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("usr/bin/" + helper).path) {
                pending.append("usr/bin/" + helper)
            }
        }
        while let path = pending.popLast() {
            try Task.checkCancellation()
            if selected[path] != nil {
                continue
            }
            try autoreleasepool {
                let source = try canonical(root.appendingPathComponent(path))
                guard contained(source, in: root) else {
                    throw ToolchainFailure("Tool dependency escapes extracted tree")
                }
                selected[path] = source
                let data = try Data(contentsOf: source, options: .mappedIfSafe)
                let image = try MachOImage(data)
                let passedOn = try image.rpaths.filter { !$0.hasPrefix("/") }.map { Self.expand($0, loader: path) }
                    + (inherited[path] ?? [])
                for dependency in try image.dependencies {
                    guard !MachOImage.isMacOSOnly(dependency) else {
                        throw ToolchainFailure("\(path) needs a macOS-only framework: \(dependency)")
                    }
                    if let relative = try resolve(dependency, loader: path, rpaths: image.rpaths) {
                        // An image already gone through goes through again when it inherits a new
                        // run path: its own dependencies may resolve elsewhere now, as `resolve`
                        // will find them when the tree is retargeted.
                        if inherit(passedOn, by: relative) {
                            selected[relative] = nil
                        }
                        pending.append(relative)
                    }
                }
            }
        }
        // Compiler resource data is not in Mach-O load commands. Preserve its directory contract.
        let resourceRoots = ["usr/lib/clang"] + (components.contains(.swift) ? Self.swiftResources : [])
        for resource in resourceRoots {
            let url = root.appendingPathComponent(resource)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            ) else {
                throw ToolchainFailure("Cannot enumerate compiler resources")
            }
            for case let file as URL in enumerator {
                let canonicalFile = try canonical(file)
                guard contained(canonicalFile, in: root) else {
                    throw ToolchainFailure("Compiler resource escapes toolchain")
                }
                if try canonicalFile.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    continue
                }
                let relative = file.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
                if Self.swiftExcluded.contains(relative) {
                    continue
                }
                // swift-frontend dlopens host/libSwiftInProcPluginServer.dylib, whose run path
                // (@loader_path, the host folder) the libraries and macro plugins it loads
                // resolve their @rpath through; none of them is in a load command.
                if relative.hasPrefix("usr/lib/swift/host/") {
                    inherit(["usr/lib/swift/host"], by: MachOImage.flattened(relative))
                }
                if relative.contains("/lib/darwin/") {
                    let name = file.lastPathComponent
                    // iOS target runtimes only. libclang_rt.ios.a is the builtins library, where
                    // `@available` and `#available` find __isPlatformVersionAtLeast (scheme 2).
                    guard name == "libclang_rt.ios.a" || name.contains("_ios.") || name.contains("_ios_") else {
                        continue
                    }
                }
                selected[MachOImage.flattened(relative)] = canonicalFile
            }
        }
        return selected
    }

    /// Adds `paths` to what `image` inherits, in order and once each; answers
    /// whether it inherits anything new.
    @discardableResult
    private mutating func inherit(_ paths: [String], by image: String) -> Bool {
        var known = inherited[image] ?? []
        let count = known.count
        for path in paths where !known.contains(path) {
            known.append(path)
        }
        inherited[image] = known
        return known.count > count
    }

    /// `path` with `@loader_path` and `@executable_path` read below the root,
    /// for an image at `loader`; every tool is in `usr/bin`.
    private static func expand(_ path: String, loader: String) -> String {
        path.replacingOccurrences(of: "@loader_path", with: (loader as NSString).deletingLastPathComponent)
            .replacingOccurrences(of: "@executable_path", with: "usr/bin")
    }

    /// The Swift component's links, path → relative target, read from the
    /// package; each must land on a selected file or a folder of them.
    func links(selected: [String: URL]) throws -> [String: String] {
        guard components.contains(.swift) else { return [:] }
        var links: [String: String] = [:]
        for path in Self.swiftLinks {
            let target = try FileManager.default.destinationOfSymbolicLink(
                atPath: root.appendingPathComponent(path).path,
            )
            guard let resolved = Self.lexicallyResolved(target, from: path),
                  selected[resolved] != nil || selected.keys.contains(where: { $0.hasPrefix(resolved + "/") })
            else {
                throw ToolchainFailure("\(path) links to \(target), which is not part of the toolchain")
            }
            links[path] = target
        }
        return links
    }

    /// `target` read from the folder of `link`, both below the root: the
    /// relative path it names, or nil when it is absolute or climbs out.
    static func lexicallyResolved(_ target: String, from link: String) -> String? {
        guard !target.hasPrefix("/"), !target.utf8.contains(0), !target.isEmpty else { return nil }
        var parts = Array(link.split(separator: "/").dropLast().map(String.init))
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    func resolve(_ name: String, loader: String, rpaths: [String]) throws -> String? {
        let clt = "/Library/Developer/CommandLineTools/"
        var candidates: [String] = []
        if name.hasPrefix(clt) {
            candidates = [String(name.dropFirst(clt.count))]
        } else if name.hasPrefix("@loader_path/") || name.hasPrefix("@executable_path/") {
            candidates = [Self.expand(name, loader: loader)]
        } else if name.hasPrefix("@rpath/") {
            let suffix = String(name.dropFirst(7))
            candidates = rpaths.map { Self.expand($0, loader: loader) + "/" + suffix }
            candidates += (inherited[loader] ?? []).map { $0 + "/" + suffix }
            candidates += ["usr/lib/" + suffix, "Library/PrivateFrameworks/" + suffix, "Library/Frameworks/" + suffix]
        } else if name.hasPrefix("/usr/lib/") || name.hasPrefix("/System/Library/") {
            return nil
        } else {
            throw ToolchainFailure("Unresolved dependency: \(name)")
        }
        for candidate in candidates {
            let relative = candidate.hasPrefix(clt) ? String(candidate.dropFirst(clt.count)) : candidate
            guard !relative.hasPrefix("/") else { continue }
            let file = root.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: file.path) {
                let resolved = try canonical(file)
                guard contained(resolved, in: root) else { throw ToolchainFailure("Dependency outside toolchain") }
                return MachOImage.flattened(
                    resolved.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/"),
                )
            }
            // Source has Versions/A; output does not. The outer alias resolves the source layout.
            let flat = MachOImage.flattened(relative)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(flat).path) {
                return flat
            }
        }
        throw ToolchainFailure("Missing dependency: \(name) required by \(loader)")
    }

    static func relativeReference(from loader: String, to destination: String) -> String {
        let from = Array(loader.split(separator: "/").dropLast()), to = destination.split(separator: "/")
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] {
            common += 1
        }
        return "@loader_path/"
            + (Array(repeating: "..", count: from.count - common) + to.dropFirst(common).map(String.init))
            .joined(separator: "/")
    }
}
