import Darwin
import Foundation

/// A toolchain carried from one device to another as its retargeted tree,
/// the way setup left it before packaging (`manifest.json` at the top).
///
/// Export copies the installed tree back to those bytes: every file of the
/// manifest checked against its digest, RootHide's runtime brand undone
/// (`removingRuntimeBrand`), its links and folders as they are. Import
/// trusts nothing the tree says about itself until it holds: the manifest's
/// identity, an ID that is the one setup derives, a release Apelin still
/// supports from a source Apelin reviewed, every file and link the manifest
/// lists and nothing else, each matching its digest.
public enum ToolchainTransfer {
    /// The largest `manifest.json` a tree may have.
    public static let manifestLimit = 64 << 20

    /// Copies the toolchain installed at `installed` into `destination`,
    /// which must not exist, and answers its manifest. `progress` is told
    /// each path as it goes.
    public static func exportCopy(
        installed: URL,
        to destination: URL,
        progress: (String) -> Void = { _ in },
    ) throws -> ToolchainManifest {
        let root = try canonical(installed)
        let manifestData = try readManifest(at: root)
        let manifest = try JSONDecoder().decode(ToolchainManifest.self, from: manifestData)
        try ToolchainSetup.validateIdentity(manifest)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ToolchainFailure("The export folder already exists.")
        }
        try directory(destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)

        // Folders first, every one the installed tree has: an empty one
        // (usr/lib/swift/iphoneos) is part of what setup made.
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        )
        while let item = walker?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let relative = try relativePath(item, under: root)
            let target = destination.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: target,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755],
            )
        }

        for (relative, digest) in manifest.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            try checkPlain(relative)
            let source = root.appendingPathComponent(relative)
            var metadata = stat()
            guard lstat(source.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
                throw ToolchainFailure("The installed toolchain is missing \(relative).")
            }
            let target = destination.appendingPathComponent(relative)
            try directory(target.deletingLastPathComponent())
            let mode: Int = metadata.st_mode & 0o111 != 0 ? 0o755 : 0o644
            try autoreleasepool {
                if try digestFile(source) == digest {
                    try FileManager.default.copyItem(at: source, to: target)
                } else {
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    guard let original = try? removingRuntimeBrand(from: data), sha256(original) == digest else {
                        throw ToolchainFailure(
                            "The installed toolchain's \(relative) no longer matches what setup installed.",
                        )
                    }
                    try original.write(to: target)
                }
            }
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            progress(relative)
        }
        for (relative, linkTarget) in (manifest.links ?? [:]).sorted(by: { $0.key < $1.key }) {
            try checkPlain(relative)
            let link = destination.appendingPathComponent(relative)
            try directory(link.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: linkTarget)
        }
        let manifestCopy = destination.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestCopy)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifestCopy.path)
        // What goes out is what setup would have handed the packager.
        try ToolchainSetup.verify(manifest, at: destination)
        return manifest
    }

    /// Checks a tree a transfer file brought and answers its manifest.
    public static func verifyImported(_ tree: URL) throws -> ToolchainManifest {
        let root = try canonical(tree)
        let manifest = try JSONDecoder().decode(ToolchainManifest.self, from: readManifest(at: root))
        try ToolchainSetup.validateIdentity(manifest)
        if let refusal = refusal(
            version: manifest.source.version,
            productID: manifest.source.productID,
            sourceSHA256: manifest.sourceSHA256,
            scheme: manifest.retargetSchemeVersion,
            swift: manifest.components.contains(.swift),
        ) {
            throw ToolchainFailure(refusal)
        }
        let expected = ToolchainSetup.identity(
            sourceSHA256: manifest.sourceSHA256,
            scheme: manifest.retargetSchemeVersion,
            minimumOS: manifest.minimumOS,
            components: manifest.components,
        )
        guard manifest.id == expected else {
            throw ToolchainFailure(
                "The toolchain's identity does not match its source and components. Import another copy.",
            )
        }
        guard (try? ToolchainSetup.encodedVersion(manifest.minimumOS)) != nil else {
            throw ToolchainFailure("The toolchain names an unusable minimum iOS version.")
        }

        // Nothing beside what the manifest lists: an extra file would be
        // installed as root's without a digest anyone checked. So a folder
        // the walk cannot list stops it, rather than being passed over.
        let links = manifest.links ?? [:]
        var unreadable = false
        let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
            errorHandler: { _, _ in unreadable = true; return false },
        )
        while let item = walker?.nextObject() as? URL {
            let relative = try relativePath(item, under: root)
            var metadata = stat()
            guard lstat(item.path, &metadata) == 0 else { throw ToolchainFailure("Cannot read \(relative).") }
            switch metadata.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                guard relative == "manifest.json" || manifest.files[relative] != nil else {
                    throw ToolchainFailure("The toolchain carries \(relative), which its manifest does not list.")
                }
                guard metadata.st_mode & 0o7000 == 0 else {
                    throw ToolchainFailure(
                        "The toolchain file \(relative) has unsafe permissions. Import another copy.",
                    )
                }
            case S_IFLNK:
                guard links[relative] != nil else {
                    throw ToolchainFailure(
                        "The toolchain carries the link \(relative), which its manifest does not list.",
                    )
                }
                walker?.skipDescendants()
            default:
                throw ToolchainFailure("The toolchain contains an unsupported item: \(relative). Import another copy.")
            }
        }
        guard walker != nil, !unreadable else {
            throw ToolchainFailure("The toolchain could not be read completely. Import another copy.")
        }
        try ToolchainSetup.verify(manifest, at: root)
        return manifest
    }

    /// Why this device would not take a toolchain of this release, source,
    /// scheme and components; nil when it would. A tree an earlier scheme
    /// Apelin still reads made is taken under its own ID, as it is installed
    /// on the device it came from: 27.0 can no longer be downloaded, so a
    /// transfer file is the one way to bring it to another device.
    public static func refusal(
        version: String,
        productID: String,
        sourceSHA256: String,
        scheme: Int,
        swift: Bool,
    ) -> String? {
        guard ToolchainSetup.readableSchemes.contains(scheme) else {
            return "This toolchain was prepared by a different version of Apelin. Set it up again on this device."
        }
        if let reason = CommandLineToolsSupport.refusal(for: version, productID: productID) {
            return reason
        }
        let release = CommandLineToolsSupport.release(version)! // refusal(for:) answered nil
        guard release.sources[productID] == sourceSHA256 else {
            return "This toolchain was not adapted from the Apple package Apelin reviewed for Command Line Tools \(version)."
        }
        if let reason = release.compatibility.hostRefusal {
            return reason
        }
        if swift {
            guard let support = release.swiftSupport else {
                return "This version of Apelin does not support Swift from Command Line Tools \(version)."
            }
            if let reason = support.hostRefusal {
                return reason
            }
        }
        return nil
    }

    private static func readManifest(at root: URL) throws -> Data {
        let url = root.appendingPathComponent("manifest.json")
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw ToolchainFailure("The toolchain is incomplete: its manifest is missing.")
        }
        guard metadata.st_size <= manifestLimit else {
            throw ToolchainFailure("The toolchain manifest exceeds the size limit.")
        }
        return try Data(contentsOf: url)
    }

    private static func checkPlain(_ relative: String) throws {
        guard !relative.hasPrefix("/"), !relative.utf8.contains(0), !relative.isEmpty,
              !relative.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
        else {
            throw ToolchainFailure("The toolchain manifest lists an invalid file path. Set up the toolchain again.")
        }
    }

    private static func relativePath(_ item: URL, under root: URL) throws -> String {
        let components = item.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        guard components.starts(with: base), components.count > base.count else {
            throw ToolchainFailure("A file of the toolchain is outside it.")
        }
        return components.dropFirst(base.count).joined(separator: "/")
    }
}
