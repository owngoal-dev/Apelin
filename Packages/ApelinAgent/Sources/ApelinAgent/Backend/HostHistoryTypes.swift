import struct ApelinProtocol.GitSquashResponse
import Foundation

// MARK: - git history

/// A squash of the session's project's checked-out branch. A preview reads
/// what it would combine, by `base` (a commit ID of at least seven digits)
/// or `count`, and changes nothing; a squash names the full `base` and
/// `expectedHead` the preview answered, and the `message`.
public struct GitSquashToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var base: String?
    public var count: Int?
    public var message: String?
    public var expectedHead: String?
    public var preview: Bool

    public init(
        context: HostCallContext,
        base: String? = nil,
        count: Int? = nil,
        message: String? = nil,
        expectedHead: String? = nil,
        preview: Bool,
    ) {
        self.context = context
        self.base = base
        self.count = count
        self.message = message
        self.expectedHead = expectedHead
        self.preview = preview
    }
}

/// What git_squash answers: the squash as the host did it, and what the
/// model is told besides.
public struct GitSquashToolResponse: Sendable, Hashable, Encodable {
    public var squashed: GitSquashResponse
    public var note: String

    public init(squashed: GitSquashResponse, note: String) {
        self.squashed = squashed
        self.note = note
    }
}
