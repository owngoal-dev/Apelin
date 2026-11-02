import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// apelin_package_publish → `distributionPublish` with every file's digest
/// and the repository the card named, read to its end. What the tool checks
/// before anyone is asked is read here, as mobile, from the data folder —
/// the link the app made (`Settings/distribution.json`, while its project
/// is there) and each build's record (`Builds/artifacts/<id>.json`) — and
/// whether a github.com sign-in is saved, from the host's git settings.
extension ChannelHostBackend {
    /// `~/Documents/wiki.qaq.apelin`, where `Projects/` is.
    var dataFolder: URL {
        projectsURL.deletingLastPathComponent()
    }

    public func packagePublication(_ request: PackagePublicationRequest) async throws -> PackagePublication {
        let settings = try? await service.gitSettings()
        let signedIn = settings.map { $0.credentials.contains { $0.host == "github.com" } }
        let repository = await linkedRepository()
        return PackagePublication(
            repository: repository,
            signedIn: signedIn,
            builds: request.buildIDs.map { packageRecord($0) },
        )
    }

    /// Without a github.com sign-in, or with one GitHub refused, the model
    /// hears where the user signs in, read from the reply's reason; any
    /// other refusal is the host's or apelin-environment's, in their words.
    public func publishPackages(_ request: PackagePublishToolRequest) async throws -> PackagePublishToolResponse {
        let publication = request.publication
        let handle: TaskHandle
        do {
            handle = try await service.distributionPublish(
                files: publication.packages.map(\.file),
                digests: publication.packages.map(\.digest),
                repository: publication.repository,
            )
        } catch let error as ApelinError {
            throw Self.publishFailure(message: error.message, reason: error.reason?.rawValue)
        }
        var result: ApelinCore.JSONValue?
        var reason: String?
        let end = try await read(handle) { event in
            if event.kind == "result" {
                result = event.payload
            } else if event.kind == TaskEvent.stateKind {
                result = event.payload?["result"] ?? result
                reason = event.payload?["reason"]?.stringValue
            }
        }
        switch end.state {
        case .succeeded:
            return Self.published(result, publication: publication)
        case .cancelled, .interrupted:
            throw PackagePublishToolFailure(message: "Publishing stopped before it finished. Publish the same builds again: a package already there with the same bytes is left as it is.")
        default:
            throw Self.publishFailure(message: GitFailure.split(end.message).1, reason: reason)
        }
    }

    static func publishFailure(message: String, reason: String?) -> PackagePublishToolFailure {
        if reason == ApelinError.Reason.authenticationRequired.rawValue {
            return PackagePublishToolFailure(message: PackagePublish.signInNeeded)
        }
        return PackagePublishToolFailure(message: "Nothing was published: " + (message.isEmpty ? "no reason was given." : message))
    }

    /// What the task's `result` names, and what happens next.
    static func published(_ result: ApelinCore.JSONValue?, publication: PackagePublishApproval) -> PackagePublishToolResponse {
        func names(_ key: String) -> [String] {
            guard case let .array(items)? = result?[key] else { return [] }
            return items.compactMap(\.stringValue)
        }
        let published = names("published")
        let repository = result?["repository"]?.stringValue ?? publication.repository
        let source = result?["sourceURL"]?.stringValue ?? publication.sourceURL
        let next = if published.isEmpty {
            "Every package was in \(repository) already, with the same bytes; nothing new was published."
        } else {
            "Package managers see \(published.count == 1 ? "it" : "them") once the repository's workflow on GitHub has indexed debs/, usually within a few minutes\(source.map { "; the source to add is \($0)" } ?? "")."
        }
        return PackagePublishToolResponse(
            repository: repository,
            sourceURL: source,
            published: published,
            alreadyPublished: names("skipped"),
            commit: result?["commit"]?.stringValue,
            next: next,
        )
    }

    /// The link the app made, while its project is there.
    private func linkedRepository() async -> PackagePublication.Repository? {
        guard let link = Self.boundedJSON(dataFolder.appendingPathComponent("Settings/distribution.json")),
              let fullName = link["fullName"]?.stringValue, !fullName.isEmpty,
              let projectID = link["projectID"]?.stringValue, !projectID.isEmpty,
              await (try? resolveProject(projectID))?.id == projectID
        else { return nil }
        return PackagePublication.Repository(fullName: fullName, sourceURL: link["sourceURL"]?.stringValue)
    }

    /// What a build recorded of its package; nil for an id no build left a
    /// whole record under.
    private func packageRecord(_ buildID: String) -> PackageBuildRecord? {
        guard !buildID.isEmpty, buildID.count <= 128,
              buildID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let record = Self.boundedJSON(dataFolder.appendingPathComponent("Builds/artifacts/\(buildID).json")),
              let projectID = record["projectID"]?.stringValue,
              let configuration = record["configuration"]?.stringValue,
              let bootstrap = record["bootstrap"]?.stringValue,
              let packageID = record["packageID"]?.stringValue,
              let version = record["packageVersion"]?.stringValue,
              let architecture = record["architecture"]?.stringValue,
              let recorded = record["path"]?.stringValue, recorded.hasPrefix("/"),
              let digest = record["digest"]?.stringValue
        else { return nil }
        // a build from before roothide renamed its root (issue #34)
        let file = BootstrapRootPath.rebased(recorded, onto: dataFolder.path)
        var metadata = stat()
        let present = lstat(file, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
        return PackageBuildRecord(
            buildID: record["buildID"]?.stringValue ?? buildID,
            projectID: projectID,
            configuration: configuration,
            bootstrap: bootstrap,
            packageID: packageID,
            version: version,
            architecture: architecture,
            file: file,
            digest: digest,
            present: present,
        )
    }

    /// A regular file, not a link, of at most 1 MB, read as JSON.
    private static func boundedJSON(_ url: URL) -> ApelinCore.JSONValue? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 1 << 20,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONCoding.decode(ApelinCore.JSONValue.self, from: data)
    }
}
