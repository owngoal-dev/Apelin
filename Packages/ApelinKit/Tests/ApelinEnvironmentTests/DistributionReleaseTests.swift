import ApelinCore
import ApelinDebArchive
import ApelinDebian
@testable import ApelinEnvironment
@testable import ApelinGit
import ApelinProject
@testable import ApelinProtocol
import CryptoKit
import Foundation
import XCTest

/// A project's release builds as a GitHub Release (issue #77): GitHub's
/// releases, references and uploads answered by a fake that keeps them as
/// GitHub's REST API describes them, the repository a bare one on disk.
final class DistributionReleaseTests: XCTestCase {
    /// GitHub as far as a release asks it: the repository, its tags, its
    /// releases and their files, noting each request.
    final class FakeGitHub: @unchecked Sendable {
        struct Asset {
            var id: Int
            var name: String
            var state = "uploaded"
            var contentType = "application/octet-stream"
            var bytes: Data
            /// Whether GitHub says the file's digest.
            var digested = true

            var json: [String: Any] {
                [
                    "id": id, "name": name, "state": state, "size": bytes.count, "content_type": contentType,
                    "digest": digested ? "sha256:" + Self.hex(bytes) as Any : NSNull(),
                    "url": "https://api.github.com/repos/x/y/releases/assets/\(id)",
                    "browser_download_url": "https://github.com/x/y/releases/download/v/\(name)",
                ]
            }

            static func hex(_ data: Data) -> String {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }

        struct Release {
            var id: Int
            var tag: String
            var target: String
            var name: String?
            var body: String?
            var draft: Bool
            var prerelease = false
            var immutable: Bool?
            var assets: [Asset] = []
            var makeLatest: String?
            var uploadHost = "uploads.github.com"

            func json(_ fullName: String) -> [String: Any] {
                var object: [String: Any] = [
                    "id": id, "tag_name": tag, "target_commitish": target, "name": name as Any? ?? NSNull(),
                    "body": body as Any? ?? NSNull(), "draft": draft, "prerelease": prerelease,
                    "html_url": draft ? "https://github.com/\(fullName)/releases/tag/untagged-\(id)" : "https://github.com/\(fullName)/releases/tag/\(tag)",
                    "upload_url": "https://\(uploadHost)/repos/\(fullName)/releases/\(id)/assets{?name,label}",
                    "url": "https://api.github.com/repos/\(fullName)/releases/\(id)",
                    "assets": assets.map(\.json),
                ]
                if let immutable {
                    object["immutable"] = immutable
                }
                return object
            }
        }

        private let lock = NSLock()
        let fullName = "someone/tweak"
        var push = true
        /// Tags by name: what each names, `commit` or an annotated `tag`.
        var tags: [String: (type: String, sha: String)] = [:]
        /// Annotated tag objects by their sha: the commit each names.
        var tagObjects: [String: String] = [:]
        var releases: [Release] = []
        var latestTag: String?
        private var nextID = 100
        private(set) var requests: [(method: String, path: String, body: [String: Any]?)] = []
        private(set) var downloads: [Int] = []

        var changes: [String] {
            requests.filter { $0.method != "GET" }.map { "\($0.method) \($0.path)" }
        }

        func newID() -> Int {
            nextID += 1
            return nextID
        }

        func release(tag: String) -> Release? {
            lock.withLock { releases.first { $0.tag == tag } }
        }

        var exchange: GitHubAPI.Exchange {
            { request in try self.answer(request) }
        }

        var upload: GitHubAPI.Upload {
            { request, file in try self.receive(request, file) }
        }

        var download: GitHubAPI.Download {
            { request in try self.send(request) }
        }

        private func reply(_ request: URLRequest, _ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.url?.host, "api.github.com")
            let method = request.httpMethod ?? "GET"
            let path = request.url!.path
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return lock.withLock {
                requests.append((method, path, body))
                let notFound = reply(request, 404, ["message": "Not Found", "documentation_url": "https://docs.github.com"])
                let prefix = "/repos/\(fullName)"
                guard path.hasPrefix(prefix) else { return notFound }
                let rest = String(path.dropFirst(prefix.count))
                if rest.isEmpty, method == "GET" {
                    return reply(request, 200, [
                        "name": "tweak", "full_name": fullName, "owner": ["login": "someone"], "private": false,
                        "description": NSNull(), "html_url": "https://github.com/\(fullName)",
                        "clone_url": "https://github.com/\(fullName).git", "default_branch": "main",
                        "permissions": ["push": push],
                    ])
                }
                if rest.hasPrefix("/git/ref/tags/"), method == "GET" {
                    let tag = String(rest.dropFirst("/git/ref/tags/".count))
                    guard let target = tags[tag] else { return notFound }
                    return reply(request, 200, [
                        "ref": "refs/tags/\(tag)", "node_id": "n",
                        "object": ["type": target.type, "sha": target.sha, "url": "u"],
                    ])
                }
                if rest.hasPrefix("/git/tags/"), method == "GET" {
                    let sha = String(rest.dropFirst("/git/tags/".count))
                    guard let commit = tagObjects[sha] else { return notFound }
                    return reply(request, 200, ["sha": sha, "tag": "t", "object": ["type": "commit", "sha": commit, "url": "u"]])
                }
                if rest == "/releases/latest", method == "GET" {
                    guard let latestTag, let release = releases.first(where: { $0.tag == latestTag }) else { return notFound }
                    return reply(request, 200, release.json(fullName))
                }
                if rest.hasPrefix("/releases/tags/"), method == "GET" {
                    let tag = String(rest.dropFirst("/releases/tags/".count))
                    // "Get a published release with the specified tag."
                    guard let release = releases.first(where: { $0.tag == tag && !$0.draft }) else { return notFound }
                    return reply(request, 200, release.json(fullName))
                }
                if rest == "/releases", method == "GET" {
                    let page = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
                    let perPage = Int(query.first { $0.name == "per_page" }?.value ?? "30") ?? 30
                    let slice = releases.dropFirst((page - 1) * perPage).prefix(perPage)
                    return reply(request, 200, slice.map { $0.json(fullName) })
                }
                if rest == "/releases", method == "POST" {
                    guard let tag = body?["tag_name"] as? String else { return reply(request, 422, ["message": "Validation Failed"]) }
                    if releases.contains(where: { $0.tag == tag && !$0.draft }) {
                        return reply(request, 422, [
                            "message": "Validation Failed",
                            "errors": [["resource": "Release", "code": "already_exists", "field": "tag_name"]],
                        ])
                    }
                    let release = Release(
                        id: newID(),
                        tag: tag,
                        target: body?["target_commitish"] as? String ?? "main",
                        name: body?["name"] as? String,
                        body: body?["body"] as? String,
                        draft: body?["draft"] as? Bool ?? false,
                        prerelease: body?["prerelease"] as? Bool ?? false,
                    )
                    releases.append(release)
                    return reply(request, 201, release.json(fullName))
                }
                let parts = rest.split(separator: "/").map(String.init)
                if parts.count == 2, parts[0] == "releases", let id = Int(parts[1]), method == "PATCH",
                   let index = releases.firstIndex(where: { $0.id == id })
                {
                    if let draft = body?["draft"] as? Bool {
                        releases[index].draft = draft
                    }
                    if let prerelease = body?["prerelease"] as? Bool {
                        releases[index].prerelease = prerelease
                    }
                    if let target = body?["target_commitish"] as? String {
                        releases[index].target = target
                    }
                    if let text = body?["body"] as? String {
                        releases[index].body = text
                    }
                    releases[index].makeLatest = body?["make_latest"] as? String
                    // publishing makes the tag from target_commitish when it is not there
                    if !releases[index].draft, tags[releases[index].tag] == nil {
                        tags[releases[index].tag] = ("commit", releases[index].target)
                    }
                    return reply(request, 200, releases[index].json(fullName))
                }
                if parts.count == 3, parts[0] == "releases", parts[2] == "assets", let id = Int(parts[1]), method == "GET",
                   let release = releases.first(where: { $0.id == id })
                {
                    let page = Int(query.first { $0.name == "page" }?.value ?? "1") ?? 1
                    return reply(request, 200, page == 1 ? release.assets.map(\.json) : [])
                }
                if parts.count == 3, parts[0] == "releases", parts[1] == "assets", let id = Int(parts[2]), method == "DELETE" {
                    for index in releases.indices {
                        releases[index].assets.removeAll { $0.id == id }
                    }
                    return reply(request, 204, [String: Any]())
                }
                return notFound
            }
        }

        private func receive(_ request: URLRequest, _ file: URL) throws -> (Data, HTTPURLResponse) {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.host, "uploads.github.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer gho_token")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Content-Type"))
            let bytes = try Data(contentsOf: file)
            let path = request.url!.path
            let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
            return lock.withLock {
                requests.append(("UPLOAD", path + "?name=" + name, nil))
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count == 6, let id = Int(parts[4]), let index = releases.firstIndex(where: { $0.id == id }) else {
                    return reply(request, 404, ["message": "Not Found"])
                }
                if releases[index].assets.contains(where: { $0.name == name }) {
                    return reply(request, 422, [
                        "message": "Validation Failed",
                        "errors": [["resource": "ReleaseAsset", "code": "already_exists", "field": "name"]],
                    ])
                }
                let asset = Asset(
                    id: newID(),
                    name: name,
                    contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "",
                    bytes: bytes,
                )
                releases[index].assets.append(asset)
                return reply(request, 201, asset.json)
            }
        }

        private func send(_ request: URLRequest) throws -> (digest: String, size: Int) {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
            let id = Int(request.url!.lastPathComponent) ?? 0
            return try lock.withLock {
                downloads.append(id)
                guard let asset = releases.flatMap(\.assets).first(where: { $0.id == id }) else {
                    throw ApelinError(.unavailable, "GitHub answered 404 for a release file.")
                }
                return ("sha256:" + Asset.hex(asset.bytes), asset.bytes.count)
            }
        }

        func add(_ release: Release) {
            lock.withLock { releases.append(release) }
        }

        func asset(_ name: String, _ bytes: Data, digested: Bool = true, state: String = "uploaded") -> Asset {
            Asset(id: newID(), name: name, state: state, bytes: bytes, digested: digested)
        }
    }

    private struct Fixture {
        let home: TemporaryHome
        let github = FakeGitHub()
        let service: DistributionService
        let store = MemoryGitCredentialStore()
        let project: ProjectCreateResponse
        let repository: GitRepository
        let bare: URL

        init(_ test: XCTestCase, signedIn: Bool = true) throws {
            home = try TemporaryHome(test)
            let remotes = home.home.appendingPathComponent("remotes", isDirectory: true)
            if signedIn {
                try store.save(GitCredential(username: "someone", token: "gho_token"), forHost: "github.com")
            }
            var git = GitService(layout: home.layout, credentials: store)
            git.acceptsLocalRemotes = true
            var service = DistributionService(layout: home.layout, git: git, credentials: store)
            service.exchange = github.exchange
            service.upload = github.upload
            service.download = github.download
            service.remoteURL = { remotes.appendingPathComponent($0 + ".git").path }
            self.service = service
            bare = remotes.appendingPathComponent("someone/tweak.git", isDirectory: true)
            try GitRepository.createBare(at: bare)
            project = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Tweak")
            repository = try GitRepository(at: URL(fileURLWithPath: project.path, isDirectory: true))
            try repository.addRemote("origin", url: bare.path)
            try commit("First")
        }

        @discardableResult
        func commit(_ message: String) throws -> String {
            let file = URL(fileURLWithPath: project.path).appendingPathComponent("notes.txt")
            try Data((message + "\n").utf8).write(to: file)
            try repository.stageAll()
            return try repository.commit(message: message, author: GitSignature(name: "Someone", email: "someone@example.com"))
        }

        func push() throws {
            _ = try repository.push(remote: "origin", branch: "main")
        }

        var head: String {
            repository.head().commit ?? ""
        }

        /// A package as a build of the project leaves it, under
        /// `Builds/<projectID>/`.
        func build(
            _ package: String = "com.example.tweak",
            version: String = "1.0",
            architecture: String = "iphoneos-arm64",
            marker: UInt8 = 1,
            project projectID: String? = nil,
        ) throws -> URL {
            var control = DebianControlFile(package: package, version: version, architecture: architecture, description: "Test")
            control["Section"] = "Tweaks"
            var writer = DebPackageWriter(control: control)
            writer.controlCompression = .gzip
            writer.entries = [.file("/var/jb/usr/share/test/\(package)", contents: Data([marker]))]
            let folder = home.layout.data.root
                .appendingPathComponent("Builds/\(projectID ?? project.projectID)/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("out.deb")
            try writer.write(toPath: url.path)
            return url
        }

        func digest(_ url: URL) throws -> String {
            try CanonicalJSON.sha256Tag(Data(contentsOf: url))
        }

        func request(_ files: [URL], tag: String? = nil, commit: String? = nil, notes: String? = nil) throws -> DistributionReleaseRequest {
            try DistributionReleaseRequest(
                projectID: project.projectID,
                repository: "someone/tweak",
                files: files.map(\.path),
                digests: files.map { try digest($0) },
                tag: tag,
                commit: commit,
                notes: notes,
            )
        }

        /// A release in a task's own staging, as the worker runs one.
        func release(_ request: DistributionReleaseRequest, log: EventLog? = nil) async throws -> DistributionReleaseResult {
            let prepared = try service.prepareRelease(request)
            let staging = try home.layout.makeStaging(UUID().uuidString)
            let value = try await service.release(prepared, staging: staging, reporter: log?.reporter ?? .silent)
            return try value.decode(DistributionReleaseResult.self)
        }

        func both(version: String = "1.0", marker: UInt8 = 1) throws -> [URL] {
            try [
                build(version: version, architecture: "iphoneos-arm64e", marker: marker),
                build(version: version, architecture: "iphoneos-arm64", marker: marker),
            ]
        }
    }

    private static let roothideName = "com.example.tweak_1.0_iphoneos-arm64e.deb"
    private static let rootlessName = "com.example.tweak_1.0_iphoneos-arm64.deb"

    private func expectRefusal(
        _ code: ApelinError.Code,
        reason: ApelinError.Reason? = nil,
        saying words: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void,
    ) async {
        do {
            try await body()
            XCTFail("expected \(code)", file: file, line: line)
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, code, error.message, file: file, line: line)
            if let reason {
                XCTAssertEqual(error.reason, reason, error.message, file: file, line: line)
            }
            if let words {
                XCTAssertTrue(error.message.contains(words), error.message, file: file, line: line)
            }
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    // MARK: A new release

    func testReleaseMakesADraftUploadsEachPackageAndChecksumsThenPublishes() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        let log = EventLog()
        let result = try await fixture.release(fixture.request(files, notes: "First release."), log: log)

        let stages = log.events.filter { $0.0 == "stage" }.compactMap { $0.1?["stage"]?.stringValue }
        XCTAssertEqual(stages, ["fetching", "checking", "uploading", "releasing"])
        XCTAssertEqual(result.repository, "someone/tweak")
        XCTAssertEqual(result.tag, "v1.0")
        XCTAssertEqual(result.commit, fixture.head)
        XCTAssertEqual(result.url, "https://github.com/someone/tweak/releases/tag/v1.0")
        XCTAssertEqual(result.uploaded, [Self.roothideName, Self.rootlessName])
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.checksums, "added")
        XCTAssertTrue(result.created)

        // GitHub's order for a release whose files must not change: a draft,
        // its files, then publish
        let changes = fixture.github.changes
        XCTAssertEqual(changes.first, "POST /repos/someone/tweak/releases")
        XCTAssertEqual(changes.last, "PATCH /repos/someone/tweak/releases/101")
        XCTAssertEqual(changes.filter { $0.hasPrefix("UPLOAD") }.count, 3)
        let create = try XCTUnwrap(fixture.github.requests.first { $0.method == "POST" }?.body)
        XCTAssertEqual(create["tag_name"] as? String, "v1.0")
        XCTAssertEqual(create["target_commitish"] as? String, fixture.head, "the commit, not a branch")
        XCTAssertEqual(create["draft"] as? Bool, true)
        XCTAssertEqual(create["prerelease"] as? Bool, false)
        XCTAssertEqual(create["body"] as? String, "First release.")
        let publish = try XCTUnwrap(fixture.github.requests.last { $0.method == "PATCH" }?.body)
        XCTAssertEqual(publish["draft"] as? Bool, false)
        XCTAssertEqual(publish["prerelease"] as? Bool, false)
        XCTAssertEqual(publish["make_latest"] as? String, "true")

        let release = try XCTUnwrap(fixture.github.release(tag: "v1.0"))
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(fixture.github.tags["v1.0"]?.sha, fixture.head)
        XCTAssertEqual(release.assets.map(\.name), [Self.roothideName, Self.rootlessName, "SHA256SUMS"])
        XCTAssertEqual(release.assets[0].contentType, "application/vnd.debian.binary-package")
        XCTAssertEqual(release.assets[0].bytes, try Data(contentsOf: files[0]), "the package as its build made it")
        let sums = try XCTUnwrap(release.assets.last.map { String(decoding: $0.bytes, as: UTF8.self) })
        let expected = try [(Self.rootlessName, files[1]), (Self.roothideName, files[0])].map { name, file in
            try "\(fixture.digest(file).dropFirst(7))  \(name)\n"
        }.joined()
        XCTAssertEqual(sums, expected, "sha256sum's format, every package by name")
        XCTAssertEqual(release.assets.last?.contentType, "text/plain")
    }

    func testTheSameReleaseAgainUploadsNothing() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        _ = try await fixture.release(fixture.request(files))
        let before = fixture.github.changes.count
        let again = try await fixture.release(fixture.request(files))
        XCTAssertEqual(again.uploaded, [])
        XCTAssertEqual(again.skipped, [Self.roothideName, Self.rootlessName])
        XCTAssertEqual(again.checksums, "unchanged")
        XCTAssertFalse(again.created)
        XCTAssertEqual(fixture.github.changes.count, before, "nothing is changed on GitHub")
    }

    // MARK: The commit

    func testACommitNotOnTheRepositoryIsRefusedBeforeGitHubIsAsked() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        try fixture.commit("Not pushed")
        let files = try fixture.both()
        await expectRefusal(.conflict, reason: .notPushed, saying: "is on no branch of someone/tweak") {
            _ = try await fixture.release(fixture.request(files))
        }
        XCTAssertEqual(fixture.github.requests.map(\.path), ["/repos/someone/tweak"], "only the repository is read")
        // the check fetched the repository's history and wrote nothing else
        XCTAssertEqual(try fixture.repository.remotes().map(\.name), ["origin"], "no remote added")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.path + "/.git/FETCH_HEAD"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.path + "/.git/refs/apelin"), "no reference written")

        try fixture.push()
        let result = try await fixture.release(fixture.request(files))
        XCTAssertEqual(result.commit, fixture.head)
    }

    func testACommitOnAnyBranchOfTheRepositoryIsOnIt() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        // main moves on locally; only a branch of that name has it on the remote
        let commit = try fixture.commit("Released from a branch")
        try fixture.repository.createBranch("release", at: commit)
        _ = try fixture.repository.push(remote: "origin", branch: "release")
        let result = try await fixture.release(fixture.request(fixture.both(), commit: commit))
        XCTAssertEqual(result.commit, commit)
        XCTAssertEqual(fixture.github.tags["v1.0"]?.sha, commit)
    }

    func testAProjectWithNoCommitIsRefused() async throws {
        let home = try TemporaryHome(self)
        let store = MemoryGitCredentialStore()
        try store.save(GitCredential(username: "someone", token: "gho_token"), forHost: "github.com")
        var service = DistributionService(layout: home.layout, git: GitService(layout: home.layout, credentials: store), credentials: store)
        let github = FakeGitHub()
        service.exchange = github.exchange
        let project = try ProjectStore(dataFolder: home.layout.data).createEmpty(name: "Empty")
        let folder = home.layout.data.root.appendingPathComponent("Builds/\(project.projectID)/b", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var writer = DebPackageWriter(control: DebianControlFile(package: "com.example.a", version: "1", architecture: "iphoneos-arm64", description: "A"))
        writer.controlCompression = .gzip
        let file = folder.appendingPathComponent("a.deb")
        try writer.write(toPath: file.path)
        let request = try DistributionReleaseRequest(
            projectID: project.projectID,
            repository: "someone/tweak",
            files: [file.path],
            digests: [CanonicalJSON.sha256Tag(Data(contentsOf: file))],
        )
        let prepared = try service.prepareRelease(request)
        let staging = try home.layout.makeStaging("t")
        await expectRefusal(.conflict, reason: .notPushed, saying: "has no commit yet") {
            _ = try await service.release(prepared, staging: staging, reporter: .silent)
        }
    }

    func testHeadMovedSinceTheConfirmationIsRefused() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        await expectRefusal(.conflict, reason: .headChanged) {
            _ = try await fixture.release(fixture.request(files, commit: String(repeating: "a", count: 40)))
        }
        XCTAssertTrue(fixture.github.requests.isEmpty)
    }

    // MARK: The tag

    func testATagAtAnotherCommitIsNeverMovedAndNothingIsUploaded() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.tags["v1.0"] = ("commit", String(repeating: "b", count: 40))
        let files = try fixture.both()
        await expectRefusal(.conflict, saying: "names bbbbbbb, not \(fixture.head.prefix(7))") {
            _ = try await fixture.release(fixture.request(files))
        }
        XCTAssertEqual(fixture.github.changes, [], "nothing made, uploaded or moved")
    }

    func testAnAnnotatedTagIsFollowedToItsCommit() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.tags["v1.0"] = ("tag", String(repeating: "c", count: 40))
        fixture.github.tagObjects[String(repeating: "c", count: 40)] = fixture.head
        let result = try await fixture.release(fixture.request(fixture.both()))
        XCTAssertEqual(result.uploaded.count, 2)
        XCTAssertEqual(fixture.github.tags["v1.0"]?.type, "tag", "the tag stays as it was")
    }

    func testTheTagIsThePackagesVersion() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        await expectRefusal(.conflict, saying: "their tag is v1.0, not v1.1") {
            _ = try await fixture.release(fixture.request(fixture.both(), tag: "v1.1"))
        }
        await expectRefusal(.badRequest, saying: "one package at one version") {
            _ = try await fixture.release(fixture.request([fixture.build(version: "1.0"), fixture.build(version: "1.1")]))
        }
        await expectRefusal(.badRequest, saying: "one package at one version") {
            _ = try await fixture.release(fixture.request([fixture.build("com.example.a"), fixture.build("com.example.b")]))
        }
        await expectRefusal(.badRequest, saying: "cannot name a release") {
            _ = try await fixture.release(fixture.request([fixture.build(version: "1.0~beta1")]))
        }
        await expectRefusal(.badRequest, saying: "GitHub renames") {
            _ = try await fixture.release(fixture.request([fixture.build("com.example.c++")]))
        }
        XCTAssertEqual(fixture.github.changes, [])
    }

    // MARK: A release the tag has already

    func testAPublishedReleaseIsFilledInAndItsChecksumsReplaced() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        let roothide = try Data(contentsOf: files[0])
        let other = fixture.github.asset("notes.deb", Data("someone else's".utf8), digested: false)
        fixture.github.add(.init(
            id: 50,
            tag: "v1.0",
            target: fixture.head,
            body: "Written on GitHub.",
            draft: false,
            assets: [
                fixture.github.asset(Self.roothideName, roothide),
                other,
                fixture.github.asset("SHA256SUMS", Data("old\n".utf8)),
            ],
        ))
        fixture.github.tags["v1.0"] = ("commit", fixture.head)
        let log = EventLog()
        let result = try await fixture.release(fixture.request(files, notes: "Ignored."), log: log)
        XCTAssertEqual(result.uploaded, [Self.rootlessName])
        XCTAssertEqual(result.skipped, [Self.roothideName])
        XCTAssertEqual(result.checksums, "replaced")
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.warnings, ["The release v1.0 had notes of its own already, which were kept."])

        let release = try XCTUnwrap(fixture.github.release(tag: "v1.0"))
        XCTAssertEqual(release.body, "Written on GitHub.")
        XCTAssertEqual(release.assets.map(\.name), [Self.roothideName, "notes.deb", Self.rootlessName, "SHA256SUMS"])
        let sums = try String(decoding: XCTUnwrap(release.assets.last).bytes, as: UTF8.self)
        XCTAssertEqual(sums.split(separator: "\n").map { String($0.split(separator: " ").last ?? "") },
                       [Self.rootlessName, Self.roothideName, "notes.deb"], "every package on the release, by name")
        XCTAssertTrue(sums.contains(FakeGitHub.Asset.hex(Data("someone else's".utf8))), "a file GitHub gives no digest of is read back")
        XCTAssertEqual(fixture.github.downloads, [other.id])
        XCTAssertFalse(fixture.github.changes.contains { $0.hasPrefix("PATCH") }, "a published release is not published again")
    }

    func testOtherBytesUnderAPackagesNameAreRefusedAndNothingIsUploaded() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        fixture.github.add(.init(id: 50, tag: "v1.0", target: fixture.head, draft: true, assets: [
            fixture.github.asset(Self.rootlessName, Data("other bytes".utf8)),
        ]))
        await expectRefusal(.conflict, saying: "holds \(Self.rootlessName) already, with other contents") {
            _ = try await fixture.release(fixture.request(files))
        }
        XCTAssertEqual(fixture.github.changes, [], "the new roothide package is not uploaded either")
    }

    func testADraftIsFoundByListingAndFilledInThenPublished() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        let unfinished = fixture.github.asset(Self.roothideName, Data(), state: "starter")
        fixture.github.add(.init(id: 7, tag: "v0.9", target: "main", draft: false))
        fixture.github.add(.init(id: 50, tag: "v1.0", target: "main", draft: true, assets: [unfinished]))
        let result = try await fixture.release(fixture.request(files, notes: "Now with notes."))
        XCTAssertFalse(result.created)
        XCTAssertEqual(result.uploaded, [Self.roothideName, Self.rootlessName])
        XCTAssertTrue(fixture.github.changes.contains("DELETE /repos/someone/tweak/releases/assets/\(unfinished.id)"),
                      "an upload GitHub lost part way goes before the file is uploaded again")
        let release = try XCTUnwrap(fixture.github.release(tag: "v1.0"))
        XCTAssertFalse(release.draft)
        XCTAssertEqual(release.target, fixture.head, "the draft's target is the commit")
        XCTAssertEqual(release.body, "Now with notes.", "a release with no notes takes them")
        XCTAssertEqual(fixture.github.releases.count, 2, "no second release")
    }

    func testTwoDraftsOfOneTagAreTheUsersToSort() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.add(.init(id: 50, tag: "v1.0", target: "main", draft: true))
        fixture.github.add(.init(id: 51, tag: "v1.0", target: "main", draft: true))
        await expectRefusal(.conflict, saying: "2 draft releases of v1.0") {
            _ = try await fixture.release(fixture.request(fixture.both()))
        }
        XCTAssertEqual(fixture.github.changes, [])
    }

    func testAnImmutableReleaseTakesNoNewFiles() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        try fixture.github.add(.init(id: 50, tag: "v1.0", target: fixture.head, draft: false, immutable: true, assets: [
            fixture.github.asset(Self.roothideName, Data(contentsOf: files[0])),
        ]))
        fixture.github.tags["v1.0"] = ("commit", fixture.head)
        await expectRefusal(.conflict, saying: "published and immutable") {
            _ = try await fixture.release(fixture.request(files))
        }
        XCTAssertEqual(fixture.github.changes, [])
    }

    func testAnEarlierVersionReleasedLaterLeavesTheLatestAlone() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.add(.init(id: 9, tag: "v2.0", target: "main", draft: false))
        fixture.github.latestTag = "v2.0"
        _ = try await fixture.release(fixture.request(fixture.both()))
        XCTAssertEqual(fixture.github.release(tag: "v1.0")?.makeLatest, "false")
        fixture.github.latestTag = "v0.5"
        fixture.github.add(.init(id: 10, tag: "v0.5", target: "main", draft: false))
        _ = try await fixture.release(fixture.request(fixture.both(version: "1.1")))
        XCTAssertEqual(fixture.github.release(tag: "v1.1")?.makeLatest, "true")
    }

    func testAPublishedPrereleaseStaysOneAndSaysSo() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.add(.init(id: 50, tag: "v1.0", target: fixture.head, draft: false, prerelease: true))
        fixture.github.tags["v1.0"] = ("commit", fixture.head)
        let result = try await fixture.release(fixture.request(fixture.both()))
        XCTAssertTrue(result.warnings.contains { $0.contains("pre-release") })
        XCTAssertEqual(fixture.github.release(tag: "v1.0")?.prerelease, true)
    }

    // MARK: Refusals

    func testWhatCannotBeReleasedIsRefusedBeforeTheTaskStarts() throws {
        let fixture = try Fixture(self)
        let file = try fixture.build()
        let digest = try fixture.digest(file)
        func refused(_ request: DistributionReleaseRequest, _ code: ApelinError.Code, _ note: String) {
            XCTAssertThrowsError(try fixture.service.prepareRelease(request), note) {
                XCTAssertEqual(($0 as? ApelinError)?.code, code, "\(note): \($0)")
            }
        }
        let project = fixture.project.projectID
        refused(.init(projectID: project, repository: "no-owner", files: [file.path], digests: [digest]), .badRequest, "owner/name")
        refused(.init(projectID: project, repository: "someone/tweak", files: [], digests: []), .badRequest, "no files")
        refused(.init(projectID: project, repository: "someone/tweak", files: [file.path], digests: []), .badRequest, "a digest each")
        refused(.init(projectID: project, repository: "someone/tweak", files: [file.path], digests: ["sha256:x"]), .badRequest, "digest shape")
        refused(.init(projectID: project, repository: "someone/tweak", files: ["/etc/hosts"], digests: [digest]), .badRequest, "outside Builds")
        refused(.init(projectID: project, repository: "someone/tweak", files: [file.path], digests: [digest], tag: "1.0"), .badRequest, "a tag Apelin makes")
        refused(.init(projectID: project, repository: "someone/tweak", files: [file.path], digests: [digest], commit: "abc"), .badRequest, "a full commit")
        refused(
            .init(projectID: project, repository: "someone/tweak", files: [file.path], digests: [digest], notes: "Built in \(fixture.home.home.path)/x"),
            .badRequest,
            "notes with a home path",
        )
        let elsewhere = try fixture.build(project: "another-project")
        let elsewhereDigest = try fixture.digest(elsewhere)
        refused(
            .init(projectID: project, repository: "someone/tweak", files: [elsewhere.path], digests: [elsewhereDigest]),
            .badRequest,
            "another project's build",
        )
        refused(.init(projectID: "no-such-project", repository: "someone/tweak", files: [file.path], digests: [digest]), .notFound, "a project")

        let unsigned = try Fixture(self, signedIn: false)
        let theirs = try unsigned.build()
        XCTAssertThrowsError(try unsigned.service.prepareRelease(unsigned.request([theirs]))) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .denied)
            XCTAssertEqual(($0 as? ApelinError)?.reason, .authenticationRequired)
        }
    }

    func testAPackageChangedSinceItsBuildIsRefusedAndNothingIsUploaded() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        let files = try fixture.both()
        var request = try fixture.request(files)
        request.digests[1] = try fixture.digest(fixture.build(marker: 9))
        await expectRefusal(.conflict, saying: "the digest its build recorded") {
            _ = try await fixture.release(request)
        }
        XCTAssertEqual(fixture.github.changes, [])
    }

    func testARepositoryTheAccountCannotPushToIsRefused() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        fixture.github.push = false
        await expectRefusal(.denied, saying: "cannot push to someone/tweak") {
            _ = try await fixture.release(fixture.request(fixture.both()))
        }
        XCTAssertEqual(fixture.github.changes, [])
    }

    func testAnUploadAddressOffGitHubIsRefused() async throws {
        let fixture = try Fixture(self)
        try fixture.push()
        var draft = FakeGitHub.Release(id: 50, tag: "v1.0", target: "main", draft: true)
        draft.uploadHost = "uploads.example.com"
        fixture.github.add(draft)
        await expectRefusal(.unavailable, saying: "does not send the sign-in to") {
            _ = try await fixture.release(fixture.request(fixture.both()))
        }
        XCTAssertFalse(fixture.github.changes.contains { $0.hasPrefix("UPLOAD") })
    }

    // MARK: GitHub's words

    func testGitHubsRefusalsKeepItsWords() throws {
        let url = try XCTUnwrap(URL(string: "https://api.github.com/x"))
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        let invalid = try JSONSerialization.data(withJSONObject: [
            "message": "Validation Failed",
            "errors": [["resource": "Release", "code": "already_exists", "field": "tag_name"]],
        ])
        XCTAssertThrowsError(try GitHubAPI.releaseCheck(response(422), invalid, doing: "make the release v1.0", on: "a/b")) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .conflict)
            XCTAssertTrue("\($0)".contains("Validation Failed: tag_name already_exists"), "\($0)")
        }
        let forbidden = try JSONSerialization.data(withJSONObject: ["message": "Resource not accessible by integration"])
        XCTAssertThrowsError(try GitHubAPI.releaseCheck(response(403), forbidden, doing: "upload a.deb", on: "a/b")) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .denied)
            XCTAssertTrue("\($0)".contains("Resource not accessible by integration"), "\($0)")
        }
        let missing = try JSONSerialization.data(withJSONObject: ["message": "Not Found"])
        XCTAssertThrowsError(try GitHubAPI.releaseCheck(response(404), missing, doing: "make the release v1.0", on: "a/b")) {
            XCTAssertEqual(($0 as? ApelinError)?.code, .notFound)
        }
        XCTAssertThrowsError(try GitHubAPI.releaseCheck(response(401), missing, doing: "make the release v1.0", on: "a/b")) {
            XCTAssertEqual(($0 as? ApelinError)?.reason, .authenticationRequired)
        }
    }

    func testTagsAndNamesAreOnesGitHubKeeps() {
        XCTAssertEqual(DistributionReleaseRequest.tag(forVersion: "1.0.2"), "v1.0.2")
        XCTAssertEqual(DistributionReleaseRequest.tag(forVersion: "1.0-2"), "v1.0-2")
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: "1:1.0"), "git refuses : in a tag")
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: "1.0~beta"), "and ~")
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: "1.0+git"), "GitHub renames +")
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: "1..0"))
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: "1.0."))
        XCTAssertNil(DistributionReleaseRequest.tag(forVersion: ""))
        XCTAssertTrue(DistributionReleaseRequest.isAssetName("com.example.tweak_1.0_iphoneos-arm64e.deb"))
        XCTAssertFalse(DistributionReleaseRequest.isAssetName("libc++_1.0_iphoneos-arm64.deb"))
        XCTAssertFalse(DistributionReleaseRequest.isAssetName(".hidden.deb"))
        XCTAssertEqual(GitHubName.fullName(remoteURL: "https://github.com/Someone/Tweak.git"), "Someone/Tweak")
        XCTAssertEqual(GitHubName.fullName(remoteURL: "https://github.com/someone/tweak/"), "someone/tweak")
        XCTAssertNil(GitHubName.fullName(remoteURL: "https://gitlab.com/someone/tweak.git"))
        XCTAssertNil(GitHubName.fullName(remoteURL: "https://token@github.com/someone/tweak.git"))
        XCTAssertNil(GitHubName.fullName(remoteURL: "https://github.com/someone"))
    }
}
