import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// What a public issue Apelin files says about the device it came from —
/// feedback on Apelin's own repository (`FeedbackService`) and an issue on
/// a repository the user chose (`GitHubIssueService`) alike. The title and
/// body are checked by `FeedbackRules`, against this device's own home,
/// install root and host name too, which both services do before the
/// sign-in is read; below the body goes the footer written here, from
/// Apelin's own Info.plist, the iOS version and the bootstrap, and nothing
/// the caller sent goes into it.
struct IssueReport: Sendable {
    let layout: EnvironmentLayout
    /// What the device calls itself on the network, which no report names.
    var hostName: String? = Self.currentHostName()
    var osVersion = Self.currentOSVersion()

    static let maximumInfoPlistBytes = 1 << 20

    /// `FeedbackRules.problem` with this device's own paths and name.
    func problem(title: String, body: String) -> String? {
        FeedbackRules.problem(title: title, body: body, paths: privatePaths, names: names)
    }

    /// `FeedbackRules.editProblem` with this device's own paths and name.
    func editProblem(title: String?, body: String?) -> String? {
        FeedbackRules.editProblem(title: title, body: body, paths: privatePaths, names: names)
    }

    func footer() -> String {
        let version = appVersion()
        return FeedbackRules.footer(
            appVersion: version.short,
            appBuild: version.build,
            osVersion: osVersion,
            bootstrap: BuildBootstrap.resolve(installRoot: layout.installRoot, home: layout.home),
        )
    }

    /// Mobile's home and the install root, as the host gave them and
    /// canonical.
    private var privatePaths: [String] {
        let paths = [layout.home, layout.installRoot]
        return paths + paths.compactMap(CanonicalPath.resolve)
    }

    private var names: [String] {
        hostName.map { [$0] } ?? []
    }

    /// The marketing version and build of the app apelind authenticates,
    /// `<install root>/Applications/Apelin.app`, read only from inside the
    /// install root; nil for one that does not read.
    func appVersion() -> (short: String?, build: String?) {
        guard let root = CanonicalPath.resolve(layout.installRoot),
              let data = BoundedFile.read(
                  layout.installRoot + "/Applications/Apelin.app/Info.plist",
                  inside: root,
                  limit: Self.maximumInfoPlistBytes,
              ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (Self.versionText(plist["CFBundleShortVersionString"]), Self.versionText(plist["CFBundleVersion"]))
    }

    /// A version as Apelin spells one, else nil: nothing else reaches the
    /// issue from the file.
    static func versionText(_ value: Any?) -> String? {
        guard let text = value as? String, (1 ... 32).contains(text.count),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) })
        else { return nil }
        return text
    }

    /// `17.3.1`, or `26.0` with no patch.
    static func currentOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 {
            text += ".\(version.patchVersion)"
        }
        return text
    }

    static func currentHostName() -> String? {
        PrivateShapes.currentHostName()
    }
}
