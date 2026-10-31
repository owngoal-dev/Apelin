import struct ApelinProtocol.AgentAttachment
import struct ApelinProtocol.ApelinError
import Foundation
import KWWKAgent
import KWWKAI

/// The tool sessions the host opened for this agent session, one per
/// extension: each opened on the first call of one of its tools and kept
/// until the agent session closes. The host keeps at most 16 for the whole
/// device, so none is opened before it is needed.
actor ToolExtensionSessions {
    private enum Entry {
        case opening(Task<String, Error>)
        case open(String)
    }

    private let backend: any AgentHostBackend
    /// By extension ID.
    private var entries: [String: Entry] = [:]
    private var closed = false

    init(backend: any AgentHostBackend) {
        self.backend = backend
    }

    /// Calls `tool` in its extension's session. One the host no longer has
    /// (the extension exited, and the host let its session go) is opened
    /// again, once, and the call made in the new one.
    func call(_ tool: ExtensionTool, arguments: JSONValue) async throws -> ToolExtensionCallResponse {
        let session = try await session(for: tool.extensionID)
        do {
            return try await backend.callToolExtension(Self.request(tool, arguments, in: session))
        } catch let error as ApelinError where error.code == .notFound {
            if case .open(session)? = entries[tool.extensionID] {
                entries[tool.extensionID] = nil
            }
            let reopened = try await self.session(for: tool.extensionID)
            return try await backend.callToolExtension(Self.request(tool, arguments, in: reopened))
        }
    }

    /// Closes every open session; a call after this is refused, and one
    /// still opening is closed by its opener once it is open. The host
    /// closes whatever is left when the worker exits.
    func closeAll() async {
        closed = true
        let closing = entries
        entries = [:]
        for id in closing.keys.sorted() {
            if case let .open(session)? = closing[id] {
                try? await backend.closeToolExtension(sessionID: session)
            }
        }
    }

    private func session(for extensionID: String) async throws -> String {
        guard !closed else { throw Self.closing }
        switch entries[extensionID] {
        case let .open(session)?:
            return session
        case let .opening(task)?:
            let session = try await task.value
            guard !closed else { throw Self.closing }
            return session
        case nil:
            let backend = backend
            let task = Task { try await backend.openToolExtension(id: extensionID) }
            entries[extensionID] = .opening(task)
            let session: String
            do {
                session = try await task.value
            } catch {
                if case .opening(task)? = entries[extensionID] {
                    entries[extensionID] = nil
                }
                throw error
            }
            guard !closed else {
                try? await backend.closeToolExtension(sessionID: session)
                throw Self.closing
            }
            entries[extensionID] = .open(session)
            return session
        }
    }

    private static let closing = ConversationClosingError()

    private static func request(_ tool: ExtensionTool, _ arguments: JSONValue, in session: String) -> ToolExtensionCallRequest {
        ToolExtensionCallRequest(sessionID: session, tool: tool.name, arguments: arguments, timeoutSeconds: tool.timeoutSeconds)
    }
}

/// An extension's error answer, as the call's failed result.
struct ToolExtensionError: Error, LocalizedError {
    var message: String
    /// The extension's code: `timeout` when it did not answer in time.
    var code: String
    var errorDescription: String? {
        message
    }

    init(_ tool: ExtensionTool, _ failure: ToolExtensionFailure) {
        message = "\(tool.extensionName) answered \(failure.code): \(failure.message)"
        code = failure.code
    }
}

extension ToolRunner {
    /// One call of an extension's tool. The files it returned are copied
    /// into the workspace's `Attachments/`, named in the text so file_read
    /// reads them, and listed in `details` for the app to show, as
    /// file_show's copies are; an image is put before the model as well.
    func runExtension(
        _ tool: ExtensionTool,
        arguments: JSONValue,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let sessions = toolExtensions
        let response = try await Self.untilCancelled(cancellation) {
            try await sessions.call(tool, arguments: arguments)
        }
        if let failure = response.failure {
            throw ToolExtensionError(tool, failure)
        }
        var copies: [AgentAttachment] = []
        var images: [ToolResultBlock] = []
        var listed: [String] = []
        do {
            for file in response.files {
                let data = try Self.read(file)
                let name = String((file.name ?? "file").prefix(255))
                let mimeType = file.mimeType ?? FileShow.mimeType(of: name, data: data)
                // Named as the session names a tool's image (`saveAttachment`).
                let path = "Attachments/" + UUID().uuidString.lowercased()
                try root.resolveForWrite(path).commit(data, exclusive: true)
                copies.append(AgentAttachment(path: path, name: name, mimeType: mimeType))
                listed.append("- \(path): \(name), \(mimeType), \(data.count) bytes")
                if let image = try? FileImage.read(data, frame: nil, name: name) {
                    images.append(.image(ImageContent(data: image.data.base64EncodedString(), mimeType: image.mimeType)))
                }
            }
        } catch {
            for copy in copies {
                unlink((root.path as NSString).appendingPathComponent(copy.path))
            }
            throw error
        }
        var parts = response.text.isEmpty ? [] : [response.text]
        if !listed.isEmpty {
            parts.append("Files it returned, shown to the user in this conversation and saved for file_read:\n"
                + listed.joined(separator: "\n"))
        }
        let text = parts.isEmpty ? "\(tool.name) answered with nothing." : parts.joined(separator: "\n\n")
        return AgentToolResult(content: [.text(TextContent(text: text))] + images, details: FileShow.details(copies))
    }

    /// A returned file whole, as large as an attachment may be.
    private static func read(_ file: ToolExtensionFile) throws -> Data {
        defer { file.descriptor.close() }
        let limit = AgentSession.maximumAttachmentBytes
        let handle = FileHandle(fileDescriptor: file.descriptor.rawValue, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw ToolArgumentError("\(file.name ?? "A file") the tool returned is over the \(limit >> 20) MB an attachment may be")
        }
        return data
    }
}
