import Foundation

/// The skills every session has, one file each in `BuiltIn/`. They are
/// source, not bundle resources: a resource bundle's accessor would carry the
/// build machine's path into the binary.
///
/// What they say about the device was read from Apelin's own templates and
/// pipeline and from the sibling apps' sources and notes (Irisin's installer,
/// icli, Xrash, iGhostVT, Fila, LookInside's tweak) and roothide's developer
/// notes; a claim nobody has seen hold on a device stays out.
enum BuiltInSkills {
    static let all: [SkillDocument] = [
        tweakDevelopment,
        bootstrapPaths,
        tweakRuntime,
        preferenceBundle,
        projectDescription,
        externalBuild,
        deviceExecutables,
        packagingAndInstall,
        packageDependencies,
        crashTriage,
        deviceCLI,
        gitWorkflow,
        packageRepository,
        packageDepiction,
    ]

    /// Every built-in's name begins `apelin-` (owner, 2026-10-25), so none
    /// is taken for a user's skill of the same subject. Transcripts,
    /// memories and project instructions from before name them without it;
    /// `apelin_skill_read` still finds them by the old name when no skill
    /// has it now.
    static let legacyNames: [String: String] = [
        "tweak-development": "apelin-tweak-development",
        "bootstrap-paths": "apelin-bootstrap-paths",
        "tweak-runtime": "apelin-tweak-runtime",
        "preference-bundle": "apelin-preference-bundle",
        "project-description": "apelin-project-description",
        "external-build": "apelin-external-build",
        "packaging-and-install": "apelin-packaging-and-install",
        "package-dependencies": "apelin-package-dependencies",
        "crash-triage": "apelin-crash-triage",
    ]
}
