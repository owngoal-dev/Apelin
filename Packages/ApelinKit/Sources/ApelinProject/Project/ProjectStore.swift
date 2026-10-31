import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Projects under `~/Documents/wiki.qaq.apelin/Projects/<name>/`, nowhere
/// else: creating one from a template, finding one by its ID.
public struct ProjectStore: Sendable {
    public static let projectFileName = "apelin-project.json"
    public static let projectSchemaVersion = 1

    public let dataFolder: DataFolder

    public init(dataFolder: DataFolder) {
        self.dataFolder = dataFolder
    }

    public var projectsDirectory: URL {
        dataFolder.projects
    }

    /// Build outputs, outside every project so a build never writes over a
    /// source: `Builds/<projectID>/<buildID>/`.
    public var buildsDirectory: URL {
        dataFolder.root.appendingPathComponent("Builds", isDirectory: true)
    }

    public struct Located: Sendable {
        public var name: String
        public var root: URL
        public var document: JSONDocument
        public var project: ProjectDocument
    }

    /// The project folder whose `apelin-project.json` carries `projectID`.
    /// A folder whose file does not parse is skipped here (projectCheck on
    /// its ID cannot find it; the UI lists it by name instead).
    public func root(of projectID: String) throws -> (name: String, root: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []).sorted()
        for name in names where ProjectName.validate(name) == nil {
            let root = projectsDirectory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? ProjectFiles.read(Self.projectFileName, in: root),
                  let document = try? StrictJSON.parse(data),
                  document["projectID"]?.stringValue == projectID else { continue }
            return (name, root)
        }
        throw ApelinError(.notFound, "no project with the ID \(projectID) under Projects/")
    }

    /// The project, parsed and validated.
    public func locate(_ projectID: String) throws -> Located {
        let (name, root) = try root(of: projectID)
        let data = try ProjectFiles.read(Self.projectFileName, in: root)
        do {
            let (document, project) = try ProjectValidation.load(data)
            return Located(name: name, root: root, document: document, project: project)
        } catch {
            throw ApelinError(.badRequest, "\(name)/\(Self.projectFileName): \(error)")
        }
    }

    /// An empty workspace has identity but no invented SDK or build recipe.
    /// `buildSystem: external` says so to a reader: whatever builds it is
    /// the workspace's own (a repository's Makefile, a script), never
    /// apelin-build. A workspace written before the key existed has
    /// `kind: workspace` and no `buildSystem`, and is read the same way. It
    /// starts as an untouched repository on `main` (`EmptyRepository`).
    public func createEmpty(name: String, automaticallyName: Bool = false) throws -> ProjectCreateResponse {
        if let problem = ProjectName.validate(name) {
            throw ApelinError(.badRequest, problem.reason)
        }
        try dataFolder.makeLevels(to: projectsDirectory)
        let destination = projectsDirectory.appendingPathComponent(name)
        let staging = projectsDirectory.appendingPathComponent(".creating-" + UUID().uuidString)
        guard mkdir(staging.path, 0o755) == 0 else { throw ApelinError(.internal, "could not create the workspace") }
        defer { try? FileManager.default.removeItem(at: staging) }
        let id = UUID().uuidString.lowercased()
        let document = JSONObject([
            ("schemaVersion", .integer(Int64(Self.projectSchemaVersion))),
            ("projectID", .string(id)),
            ("kind", .string("workspace")),
            ("buildSystem", .string("external")),
            ("displayName", .string(name)),
            ("autoName", .bool(automaticallyName)),
        ])
        try ProjectManifestFormat.data(.object(document))
            .write(to: staging.appendingPathComponent(Self.projectFileName), options: .atomic)
        try EmptyRepository.make(in: staging)
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw ApelinError(.conflict, "A project with this name already exists. Choose another name.")
        }
        return ProjectCreateResponse(projectID: id, name: name, path: destination.path)
    }

    // MARK: Creating

    public struct Created: Sendable {
        public var projectID: String
        public var name: String
        public var root: URL
        public var baseline: ProjectBaseline
    }

    /// Built-ins the IDE supplies and a caller may not set.
    static let reservedValues: Set<String> = [
        "projectName", "projectID", "templateExtensionID", "templateID", "templateVersion", "templateDigest",
    ]

    /// `projectCreate`: the template's files, substituted with typed and
    /// escaped values, written into a sibling staging folder on the same
    /// file system, the manifest in its written form
    /// (`ProjectManifestFormat`), the generated project validated and
    /// digested there, then given an untouched repository on `main`
    /// (`EmptyRepository`) and renamed into `Projects/<name>/`, which must
    /// not exist. A failure removes only the staging folder. No template
    /// script runs.
    public func create(
        templateID qualifiedID: String,
        name: String,
        values: [String: JSONDocument],
        catalog: ExtensionCatalog,
        registry: EnvironmentRegistry,
        projectID: String = UUID().uuidString.lowercased(),
        automaticallyName: Bool = false,
    ) throws -> Created {
        if let problem = ProjectName.validate(name) {
            throw ApelinError(.badRequest, problem.reason)
        }
        guard let (found, manifest, template) = catalog.template(qualifiedID) else {
            throw ApelinError(.notFound, "no usable template \(qualifiedID)")
        }
        let types = TemplateParameters.types(for: template)
        for key in values.keys.sorted() {
            if Self.reservedValues.contains(key) {
                throw ApelinError(.badRequest, "\(key) is supplied by Apelin")
            }
            if types[key] == nil {
                throw ApelinError(.badRequest, "unknown parameter \(key)")
            }
        }

        var resolved: [String: JSONDocument] = [
            "projectName": .string(name),
            "projectID": .string(projectID),
            "templateExtensionID": .string(manifest.id),
            "templateID": .string(template.id),
            "templateVersion": .string(manifest.version),
            "templateDigest": .string(template.digest),
        ]
        let slug = Self.slug(name)
        resolved["bundleID"] = values["bundleID"] ?? .string("local.apelin.\(slug)")
        resolved["packageID"] = values["packageID"] ?? .string("local.apelin.\(slug)")
        resolved["deploymentTarget"] = values["deploymentTarget"] ?? .string("16.0")
        resolved["architectures"] = values["architectures"]
            ?? .object(JSONObject(Bootstrap.allCases.compactMap { bootstrap in
                manifest.requirements.architectures[bootstrap].map {
                    (bootstrap.rawValue, .array($0.map { .string($0.rawValue) }))
                }
            }))
        let toolchain = try values["toolchainID"]?.stringValue ?? registry.defaultToolchainID()
        // The newest SDK the toolchain's tools read, not merely the newest.
        let toolchainRecord = try toolchain.flatMap { try registry.toolchain($0) }
        let readable = try registry.sdks()
            .filter { toolchainRecord?.reads(sdkVersion: $0.version) ?? true }
            .max { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
        let sdk = try values["sdkID"]?.stringValue
            ?? (toolchainRecord?.newestSDK == nil ? registry.defaultSDKID() : readable?.id)
        guard let toolchainID = toolchain else {
            throw ApelinError(.conflict, "No toolchain is set up. Set up a toolchain first.")
        }
        guard let sdkID = sdk else {
            if let toolchainRecord, let newest = toolchainRecord.newestSDK {
                throw ApelinError(
                    .conflict,
                    "Toolchain \(toolchainRecord.id) (Command Line Tools \(toolchainRecord.version)) supports iPhoneOS "
                        + "SDKs up to \(newest). Import a supported SDK first.",
                )
            }
            throw ApelinError(.conflict, "No SDK is available. Import an SDK first.")
        }
        resolved["toolchainID"] = .string(toolchainID)
        resolved["sdkID"] = .string(sdkID)
        resolved["toolchainDigest"] = try values["toolchainDigest"]
            ?? registry.toolchain(toolchainID).map { .string($0.digest) }
        resolved["sdkDigest"] = try values["sdkDigest"] ?? registry.sdk(sdkID).map { .string($0.digest) }
        if resolved["toolchainDigest"] == nil {
            throw ApelinError(.notFound, "Toolchain \(toolchainID) is not set up. Choose another toolchain.")
        }
        if resolved["sdkDigest"] == nil {
            throw ApelinError(.notFound, "SDK \(sdkID) is not available. Choose another SDK.")
        }
        for parameter in template.parameters {
            if let value = values[parameter.name] {
                resolved[parameter.name] = value
            } else if parameter.name == "productName", parameter.type == "identifier",
                      let product = Self.identifier(name)
            {
                // Named after the project: two projects on the template's
                // default would install the same file, and the second is refused.
                resolved[parameter.name] = .string(product)
            } else if let value = parameter.default?.value {
                resolved[parameter.name] = value
            }
        }
        for (key, type) in types {
            guard let value = resolved[key] else { throw ApelinError(.badRequest, "\(key): no value") }
            do {
                try TemplateParameters.validate(key, type, value)
            } catch {
                throw ApelinError(.badRequest, String(describing: error))
            }
        }

        try dataFolder.makeLevels(to: projectsDirectory)
        let destination = projectsDirectory.appendingPathComponent(name, isDirectory: true)
        var existing = stat()
        guard lstat(destination.path, &existing) != 0 else {
            throw ApelinError(.conflict, "A project named \(name) already exists. Choose another name.")
        }
        let staging = projectsDirectory.appendingPathComponent(
            ".\(name).creating-\(UUID().uuidString.prefix(8).lowercased())",
            isDirectory: true,
        )
        guard mkdir(staging.path, 0o755) == 0 else {
            throw ApelinError(.internal, "could not make a staging folder: \(String(cString: strerror(errno)))")
        }
        do {
            let templateRoot = found.root.appendingPathComponent(template.directory, isDirectory: true)
            for file in template.files {
                let relative = try TemplateParameters.substitutePath(file.path, values: resolved)
                let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
                guard !parts.contains(where: { $0.isEmpty || $0.hasPrefix(".") }) else {
                    throw TemplateError("\(file.path) resolves to an unusable path")
                }
                var data = try ProjectFiles.read(file.path, in: templateRoot)
                if file.format != "copy" {
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw TemplateError("\(file.path) is not UTF-8")
                    }
                    data = try Data(TemplateParameters.substitute(
                        text,
                        format: file.format,
                        types: types,
                        values: resolved,
                    ).utf8)
                }
                try Self.writeNew(data, to: relative, in: staging, mode: file.mode == "0755" ? 0o755 : 0o644)
            }
            let generated = try ProjectMetadata.initial(
                ProjectFiles.read(Self.projectFileName, in: staging),
                name: name,
                automaticallyName: automaticallyName,
            )
            try generated.write(to: staging.appendingPathComponent(Self.projectFileName), options: .atomic)
            let document: JSONDocument
            do {
                document = try ProjectValidation.load(generated).document
            } catch {
                throw TemplateError("generated apelin-project.json: \(error)")
            }
            let digests = try ApprovalDigests.compute(document, root: staging)
            try EmptyRepository.make(in: staging)
            guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST {
                    throw ApelinError(.conflict, "A project named \(name) already exists. Choose another name.")
                }
                throw ApelinError(
                    .internal,
                    "could not move the project into place: \(String(cString: strerror(errno)))",
                )
            }
            let baseline = ProjectBaseline(
                projectID: projectID,
                templateExtensionID: manifest.id,
                templateID: template.id,
                templateVersion: manifest.version,
                templateDigest: template.digest,
                build: .init(canonical: digests.build.canonical, digest: digests.build.digest),
                packaging: .init(canonical: digests.packaging.canonical, digest: digests.packaging.digest),
            )
            return Created(projectID: projectID, name: name, root: destination, baseline: baseline)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if let apelin = error as? ApelinError {
                throw apelin
            }
            throw ApelinError(.badRequest, String(describing: error))
        }
    }

    /// The name's ASCII letters and digits with each word capitalised
    /// (`I3 Chain Tweak` → `I3ChainTweak`), `_` in front of a leading digit;
    /// nil when nothing is left.
    static func identifier(_ name: String) -> String? {
        var out = ""
        var wordStart = true
        for scalar in name.unicodeScalars {
            if ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || ("0" ... "9").contains(scalar) {
                out += wordStart ? String(scalar).uppercased() : String(scalar)
                wordStart = false
            } else {
                wordStart = true
            }
        }
        guard let first = out.unicodeScalars.first else { return nil }
        if ("0" ... "9").contains(first) {
            out = "_" + out
        }
        return String(out.prefix(64))
    }

    /// Lowercase letters and digits of the name, other runs as one `-`.
    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.isEmpty, !out.hasSuffix("-") {
                out += "-"
            }
        }
        while out.hasSuffix("-") {
            out.removeLast()
        }
        return out.isEmpty ? "project" : String(out.prefix(48))
    }

    /// Creates `relative` under `root` with O_EXCL, making each missing
    /// directory level below `root` and refusing to follow a symlink.
    static func writeNew(_ data: Data, to relative: String, in root: URL, mode: mode_t) throws {
        let parts = relative.split(separator: "/").map(String.init)
        var current = root.path
        for part in parts.dropLast() {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw TemplateError("\(relative): a file stands where a folder goes")
                }
            } else if mkdir(current, 0o755) != 0 {
                throw TemplateError("\(relative): \(String(cString: strerror(errno)))")
            }
        }
        let path = current + "/" + parts.last!
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw TemplateError("\(relative): \(String(cString: strerror(errno)))") }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw TemplateError("\(relative): \(String(cString: strerror(errno)))")
                }
                offset += written
            }
        }
        fchmod(descriptor, mode)
    }
}

public extension JSONDocument {
    /// From the wire's loosely typed value: whole numbers become integers.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case let .bool(flag): self = .bool(flag)
        case let .number(number):
            self = number.rounded() == number && abs(number) <= Double(JSONDocument.maximumInteger)
                ? .integer(Int64(number))
                : .string(String(number))
        case let .string(text): self = .string(text)
        case let .array(items): self = .array(items.map(JSONDocument.init))
        case let .object(members):
            self = .object(JSONObject(members.sorted { $0.key < $1.key }.map { ($0.key, JSONDocument($0.value)) }))
        }
    }

    /// To the wire's value.
    var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case let .bool(flag): .bool(flag)
        case let .integer(number): .number(Double(number))
        case let .string(text): .string(text)
        case let .array(items): .array(items.map(\.jsonValue))
        case let .object(object):
            .object(Dictionary(
                object.entries.map { ($0.key, $0.value.jsonValue) },
                uniquingKeysWith: { a, _ in a },
            ))
        }
    }
}
