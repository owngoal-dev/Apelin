import Foundation

/// The two bootstrap layouts a project packages for. `/var/jb` prefixes
/// every rootless path; roothide relocates an unprefixed package into its
/// jbroot. Which one a device is comes from the install root `hello`
/// answered, never from a guess.
public enum Bootstrap: String, Codable, Sendable, CaseIterable, Comparable {
    case rootless
    case roothide

    public static func < (lhs: Bootstrap, rhs: Bootstrap) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ProjectKind: String, Codable, Sendable {
    case app, tweak, cli, preferences
}

public enum ProjectLanguage: String, Codable, Sendable {
    case c, objc, swift
}

public enum ProductType: String, Codable, Sendable {
    case app, dylib, bundle, executable
}

public enum Architecture: String, Codable, Sendable, CaseIterable {
    case arm64, arm64e
}

/// `apelin-project.json`, version 1, typed. Read only after the document
/// passed `ProjectValidation`; the digests are cut from the parsed document
/// instead, so formatting and omitted defaults stay as written.
public struct ProjectDocument: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projectID: String
    public var displayName: String?
    public var autoName: Bool?
    public var kind: ProjectKind
    public var template: TemplateSource
    public var environment: EnvironmentBinding
    public var language: ProjectLanguage
    public var deploymentTarget: String
    public var architectures: ArchitectureMap
    public var configurations: Configurations
    public var products: [Product]
    public var build: Build
    public var package: Package

    public struct TemplateSource: Codable, Sendable, Equatable {
        public var extensionID: String
        public var templateID: String
        public var version: String
        public var digest: String
    }

    public struct Binding: Codable, Sendable, Equatable {
        public var id: String
        public var digest: String
    }

    public struct EnvironmentBinding: Codable, Sendable, Equatable {
        public var toolchain: Binding
        public var sdk: Binding
    }

    public struct ArchitectureMap: Codable, Sendable, Equatable {
        public var rootless: [Architecture]?
        public var roothide: [Architecture]?

        public subscript(bootstrap: Bootstrap) -> [Architecture]? {
            switch bootstrap {
            case .rootless: rootless
            case .roothide: roothide
            }
        }

        public var bootstraps: [Bootstrap] {
            Bootstrap.allCases.filter { self[$0] != nil }
        }
    }

    public struct Configuration: Codable, Sendable, Equatable {
        public var optimization: String
        public var debugInfo: Bool
        public var defines: [String: String]?
        public var cFlags: [String]?
        public var swiftFlags: [String]?
        public var linkFlags: [String]?
    }

    public struct Configurations: Codable, Sendable, Equatable {
        public var Debug: Configuration
        public var Release: Configuration
    }

    public struct ExtensionSupport: Codable, Sendable, Equatable {
        public var `extension`: String
        public var component: String
    }

    public struct Product: Codable, Sendable, Equatable {
        public var id: String
        public var type: ProductType
        public var name: String
        public var sources: [String]
        public var headerSearchPaths: [String]?
        public var resources: [String]?
        public var infoPlist: String?
        public var entitlements: String?
        public var installName: String?
        public var objcARC: Bool?
        public var frameworks: [String]?
        public var weakFrameworks: [String]?
        public var libraries: [String]?
        public var frameworkSearchPaths: [String]?
        public var librarySearchPaths: [String]?
        public var extensionSupport: [ExtensionSupport]?

        /// `@rpath/<name>.dylib` unless the project names one.
        public var effectiveInstallName: String {
            installName ?? "@rpath/\(name).dylib"
        }
    }

    public enum StripStyle: String, Codable, Sendable {
        case debug
        case nonGlobal = "non-global"
    }

    public enum ScriptInterpreter: String, Codable, Sendable {
        case sh, bash, zsh, python3, perl
    }

    public enum Step: Codable, Sendable, Equatable {
        case compile(product: String, flags: [String])
        case link(product: String, flags: [String])
        case bundleResources(product: String)
        case lipo(product: String)
        case dsym(product: String)
        case strip(product: String, style: StripStyle)
        case sign(product: String)
        case script(
            id: String,
            interpreter: ScriptInterpreter,
            file: String,
            arguments: [String],
            inputs: [String],
            outputs: [String],
        )

        public var typeName: String {
            switch self {
            case .compile: "compile"
            case .link: "link"
            case .bundleResources: "bundle-resources"
            case .lipo: "lipo"
            case .dsym: "dsym"
            case .strip: "strip"
            case .sign: "sign"
            case .script: "script"
            }
        }

        public var product: String? {
            switch self {
            case let .compile(product, _), let .link(product, _), let .bundleResources(product), let .lipo(product),
                 let .dsym(product), let .strip(product, _), let .sign(product):
                product
            case .script:
                nil
            }
        }

        private enum Keys: String, CodingKey {
            case type, product, flags, style, identity, id, interpreter, file, arguments, inputs, outputs,
                 requiresApproval
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            func product() throws -> String {
                try c.decode(String.self, forKey: .product)
            }
            switch type {
            case "compile":
                self = try .compile(
                    product: product(),
                    flags: c.decodeIfPresent([String].self, forKey: .flags) ?? [],
                )
            case "link":
                self = try .link(product: product(), flags: c.decodeIfPresent([String].self, forKey: .flags) ?? [])
            case "bundle-resources": self = try .bundleResources(product: product())
            case "lipo": self = try .lipo(product: product())
            case "dsym": self = try .dsym(product: product())
            case "strip":
                self = try .strip(
                    product: product(),
                    style: c.decodeIfPresent(StripStyle.self, forKey: .style) ?? .nonGlobal,
                )
            case "sign": self = try .sign(product: product())
            case "script":
                self = try .script(
                    id: c.decode(String.self, forKey: .id),
                    interpreter: c.decode(ScriptInterpreter.self, forKey: .interpreter),
                    file: c.decode(String.self, forKey: .file),
                    arguments: c.decodeIfPresent([String].self, forKey: .arguments) ?? [],
                    inputs: c.decodeIfPresent([String].self, forKey: .inputs) ?? [],
                    outputs: c.decodeIfPresent([String].self, forKey: .outputs) ?? [],
                )
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown step \(type)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(typeName, forKey: .type)
            switch self {
            case let .compile(product, flags), let .link(product, flags):
                try c.encode(product, forKey: .product)
                if !flags.isEmpty {
                    try c.encode(flags, forKey: .flags)
                }
            case let .bundleResources(product), let .lipo(product), let .dsym(product):
                try c.encode(product, forKey: .product)
            case let .strip(product, style):
                try c.encode(product, forKey: .product)
                try c.encode(style, forKey: .style)
            case let .sign(product):
                try c.encode(product, forKey: .product)
                try c.encode("adhoc", forKey: .identity)
            case let .script(id, interpreter, file, arguments, inputs, outputs):
                try c.encode(id, forKey: .id)
                try c.encode(interpreter, forKey: .interpreter)
                try c.encode(file, forKey: .file)
                try c.encode(arguments, forKey: .arguments)
                try c.encode(inputs, forKey: .inputs)
                try c.encode(outputs, forKey: .outputs)
                try c.encode(true, forKey: .requiresApproval)
            }
        }
    }

    public struct Build: Codable, Sendable, Equatable {
        public var steps: [Step]
    }

    public struct LayoutEntry: Codable, Sendable, Equatable {
        public var path: String
        public var product: String?
        public var file: String?
        public var mode: String?
        public var substitutePrefix: Bool?
    }

    public struct TweakFilter: Codable, Sendable, Equatable {
        public var dylib: String
        public var bundles: [String]?
        public var executables: [String]?
        public var classes: [String]?
    }

    public struct MaintainerScripts: Codable, Sendable, Equatable {
        public var preinst: String?
        public var postinst: String?
        public var prerm: String?
        public var postrm: String?

        public var all: [(name: String, path: String)] {
            [("preinst", preinst), ("postinst", postinst), ("prerm", prerm), ("postrm", postrm)]
                .compactMap { name, path in
                    path.map { (name, $0) }
                }
        }
    }

    public struct DependsByBootstrap: Codable, Sendable, Equatable {
        public var rootless: [String]?
        public var roothide: [String]?

        public subscript(bootstrap: Bootstrap) -> [String]? {
            switch bootstrap {
            case .rootless: rootless
            case .roothide: roothide
            }
        }
    }

    public struct Package: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var version: String
        public var description: String
        public var longDescription: [String]?
        /// The control's `Icon`, an https URL; templates write their
        /// extension's icon on Apelin's Pages.
        public var icon: String?
        /// The control's `Depiction`, the https address of the package's
        /// web page.
        public var depiction: String?
        /// The control's `SileoDepiction`, the https address of the native
        /// depiction: the JSON Sileo and Irisin draw, a changelog tab
        /// among its views.
        public var sileoDepiction: String?
        public var author: String
        public var maintainer: String?
        public var section: String
        public var depends: [String]?
        public var dependsByBootstrap: DependsByBootstrap?
        public var recommends: [String]?
        public var suggests: [String]?
        public var conflicts: [String]?
        public var breaks: [String]?
        public var replaces: [String]?
        public var provides: [String]?
        public var layout: [LayoutEntry]
        public var maintainerScripts: MaintainerScripts?
        public var tweakFilter: TweakFilter?
    }

    public func configuration(_ name: ConfigurationName) -> Configuration {
        switch name {
        case .debug: configurations.Debug
        case .release: configurations.Release
        }
    }

    public func product(_ id: String) -> Product? {
        products.first { $0.id == id }
    }

    /// Decodes a document that already passed validation.
    public init(document: JSONDocument) throws {
        self = try JSONDecoder().decode(ProjectDocument.self, from: JSONWriter.compact(document))
    }
}

/// `Debug` or `Release`, as the project spells them.
public enum ConfigurationName: String, Codable, Sendable {
    case debug = "Debug"
    case release = "Release"
}
