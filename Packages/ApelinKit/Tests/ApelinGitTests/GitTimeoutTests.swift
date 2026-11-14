@testable import ApelinGit
import Darwin
import Foundation
import XCTest

/// libgit2 waits on a silent remote for ever unless told otherwise. A
/// transfer that stalled never ended its task, and the conversation reading
/// that task could be neither stopped nor continued (#59).
final class GitTimeoutTests: XCTestCase {
    func testTheLibraryBoundsItsWaitsOnARemote() {
        GitLibrary.ensure()
        let timeouts = GitLibrary.timeouts
        XCTAssertEqual(timeouts.connect, GitLibrary.connectTimeout)
        XCTAssertEqual(timeouts.server, GitLibrary.serverTimeout)
        XCTAssertGreaterThan(GitLibrary.connectTimeout, 0)
        XCTAssertGreaterThan(GitLibrary.serverTimeout, 0)
    }

    func testARemoteThatSaysNothingFailsTheClone() throws {
        GitLibrary.ensure()
        GitLibrary.setServerTimeout(1500)
        defer { GitLibrary.setServerTimeout(GitLibrary.serverTimeout) }
        let silent = try SilentServer()
        defer { silent.stop() }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("apelin-git-timeout-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let started = Date()
        do {
            _ = try GitClone.shallow(
                url: "http://127.0.0.1:\(silent.port)/stalled.git",
                branch: "main",
                into: folder,
            )
            XCTFail("a remote that says nothing cloned")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the clone waited past its limit")
    }
}

/// Accepts connections on a loopback port and never answers them.
private final class SilentServer: @unchecked Sendable {
    let port: UInt16
    private let listener: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []

    init() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        guard bound == 0, listen(listener, 4) == 0 else {
            close(listener)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        var named = sockaddr_in()
        var length = size
        _ = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        port = UInt16(bigEndian: named.sin_port)
        self.listener = listener
        Thread.detachNewThread { [self] in
            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { return }
                lock.withLock { accepted.append(connection) }
            }
        }
    }

    func stop() {
        close(listener)
        lock.withLock {
            accepted.forEach { close($0) }
            accepted = []
        }
    }
}
