import Foundation

/// A package this build links, as the Collect Licenses build phase found it
/// (`Licenses.json`): what the app says of one comes from the checkout it
/// was built from, never from a number kept by hand.
enum LinkedPackage {
    /// The kwwk the agent's workers link, such as `0.1.121`; nil when the
    /// bundle's list does not say.
    static let kwwkVersion: String? = Bundle.main.url(forResource: "Licenses", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { version(of: "kwwk", in: $0) }

    /// The version `list` (a `Licenses.json`) gives the package named
    /// `name`. A package pinned by revision has that revision there unless
    /// its checkout states a version (`statedVersions` in
    /// `Licenses/review.json`): only a dotted number is a version to show.
    static func version(of name: String, in list: Data) -> String? {
        struct Entry: Decodable {
            let name: String
            let version: String?
        }
        // persisted-read: the bundle's own list, never written back
        guard let entries = try? JSONDecoder().decode([Entry].self, from: list),
              let version = entries.first(where: { $0.name == name })?.version,
              version.range(of: #"^[0-9]+(\.[0-9]+)+$"#, options: .regularExpression) != nil
        else { return nil }
        return version
    }
}
