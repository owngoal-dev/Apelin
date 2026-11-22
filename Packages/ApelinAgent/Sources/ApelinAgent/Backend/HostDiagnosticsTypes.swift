import Foundation

// MARK: - apelin_package_confirm_loaded

public struct ConfirmLoadedRequest: Sendable, Hashable, Codable {
    /// The longest listen a call asks for: three minutes, as
    /// apelin_conversation_read waits (`ConversationReadToolRequest`). The
    /// provider keeps the conversation's prompt cached for five minutes
    /// from the request that last used it, and the model's next request
    /// after a longer call writes the whole conversation into the cache
    /// again; calling again costs a read of it instead. The host takes up
    /// to ten minutes, for the app and the console.
    public static let maximumWaitSeconds = 180

    public var context: HostCallContext
    public var buildID: String
    /// Process name or bundle id the tweak should be loaded in.
    public var target: String
    /// Listen for the marker, then respring, in one call: the marker is
    /// logged once, when the target starts, and the live log has no history.
    public var respring: Bool
    /// How long to listen at most, 1 to `maximumWaitSeconds`; nil for the
    /// host's default (15 s, 30 s with a respring). The listen ends as soon
    /// as the marker is heard.
    public var waitSeconds: Int?

    public init(context: HostCallContext, buildID: String, target: String, respring: Bool = false, waitSeconds: Int? = nil) {
        self.context = context
        self.buildID = buildID
        self.target = target
        self.respring = respring
        self.waitSeconds = waitSeconds
    }
}

/// The tool's answer, encoded as its result: the host's verdict and what it
/// rests on. The target's image list is never read, on any iOS version, so
/// nothing here says whether the image is mapped.
public struct ConfirmLoadedResponse: Sendable, Hashable, Codable {
    public static let markerBasis =
        "Judged by the marker line alone: the target's image list is never read, on any iOS version."

    /// The host's verdict, from the marker line.
    public var loaded: Bool
    /// What `loaded` rests on, said where the model reads it.
    public var basis: String
    /// The build's marker line appeared in the target's log.
    public var markerLogged: Bool
    /// The tweak's filter selects the target; nil when not determined.
    public var filterMatches: Bool?
    /// Whether the target process ran while the call listened, in a
    /// sentence the model can repeat: a target that never ran could not
    /// load anything, apart from one that ran and logged no marker. Nil
    /// when the host could not read its process list.
    public var targetProcess: String?
    public var logEvidence: [String]
    public var notes: String

    public init(
        loaded: Bool,
        markerLogged: Bool,
        filterMatches: Bool? = nil,
        targetProcess: String? = nil,
        logEvidence: [String] = [],
        notes: String = "",
    ) {
        self.loaded = loaded
        basis = Self.markerBasis
        self.markerLogged = markerLogged
        self.filterMatches = filterMatches
        self.targetProcess = targetProcess
        self.logEvidence = logEvidence
        self.notes = notes
    }
}

// MARK: - logs and crashes

/// A listen to the live log: iOS keeps no history, so only lines logged
/// during the call are heard, for at most `maximumListenSeconds`.
public struct ReadLogsRequest: Sendable, Hashable, Codable {
    public static let maximumListenSeconds = 10

    public var context: HostCallContext
    public var process: String?
    public var subsystem: String?
    public var listenSeconds: Int
    public var limit: Int

    public init(context: HostCallContext, process: String?, subsystem: String?, listenSeconds: Int, limit: Int) {
        self.context = context
        self.process = process
        self.subsystem = subsystem
        self.listenSeconds = listenSeconds
        self.limit = limit
    }
}

public struct LogEntry: Sendable, Hashable, Codable {
    public var date: Date
    public var process: String
    public var subsystem: String?
    public var level: String
    public var message: String

    public init(date: Date, process: String, subsystem: String? = nil, level: String, message: String) {
        self.date = date
        self.process = process
        self.subsystem = subsystem
        self.level = level
        self.message = message
    }
}

public struct ReadLogsResponse: Sendable, Hashable, Codable {
    public var entries: [LogEntry]
    public var truncated: Bool
    public init(entries: [LogEntry], truncated: Bool = false) {
        self.entries = entries
        self.truncated = truncated
    }
}

public struct ListCrashesRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var process: String?
    public var limit: Int
    public init(context: HostCallContext, process: String?, limit: Int) {
        self.context = context
        self.process = process
        self.limit = limit
    }
}

public struct CrashSummary: Sendable, Hashable, Codable {
    public var id: String
    public var process: String
    public var date: Date
    public var exceptionType: String?
    public init(id: String, process: String, date: Date, exceptionType: String? = nil) {
        self.id = id
        self.process = process
        self.date = date
        self.exceptionType = exceptionType
    }
}

public struct ListCrashesResponse: Sendable, Hashable, Codable {
    public var reports: [CrashSummary]
    public init(reports: [CrashSummary]) {
        self.reports = reports
    }
}

public struct ReadCrashRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var reportID: String
    public var maxBytes: Int
    public init(context: HostCallContext, reportID: String, maxBytes: Int) {
        self.context = context
        self.reportID = reportID
        self.maxBytes = maxBytes
    }
}

public struct ReadCrashResponse: Sendable, Hashable, Codable {
    public var reportID: String
    public var text: String
    public var truncated: Bool
    public init(reportID: String, text: String, truncated: Bool = false) {
        self.reportID = reportID
        self.text = text
        self.truncated = truncated
    }
}

public struct SymbolicateCrashRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var reportID: String
    /// The build whose dSYM to match; nil lets the host match by image UUID.
    public var buildID: String?
    public init(context: HostCallContext, reportID: String, buildID: String?) {
        self.context = context
        self.reportID = reportID
        self.buildID = buildID
    }
}

public struct SymbolicatedFrame: Sendable, Hashable, Codable {
    public var index: Int
    public var image: String
    public var address: String
    public var symbol: String?
    public var file: String?
    public var line: Int?
    public init(
        index: Int,
        image: String,
        address: String,
        symbol: String? = nil,
        file: String? = nil,
        line: Int? = nil,
    ) {
        self.index = index
        self.image = image
        self.address = address
        self.symbol = symbol
        self.file = file
        self.line = line
    }
}

public struct SymbolicateCrashResponse: Sendable, Hashable, Codable {
    public var reportID: String
    /// The dSYM UUID that matched the report's image, if any.
    public var matchedImageUUID: String?
    public var crashedThread: [SymbolicatedFrame]
    /// Suspects, most likely first.
    public var suspects: [String]
    public init(
        reportID: String,
        matchedImageUUID: String?,
        crashedThread: [SymbolicatedFrame],
        suspects: [String] = [],
    ) {
        self.reportID = reportID
        self.matchedImageUUID = matchedImageUUID
        self.crashedThread = crashedThread
        self.suspects = suspects
    }
}

// MARK: - UI

public struct CaptureScreenRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// nil for the whole screen.
    public var targetID: String?
    public init(context: HostCallContext, targetID: String?) {
        self.context = context
        self.targetID = targetID
    }
}

public struct CaptureScreenResponse: Sendable, Hashable, Codable {
    /// Host-side attachment handle; the event log records only this.
    public var attachmentID: String
    public var mimeType: String
    public var width: Int
    public var height: Int
    /// The image itself, already bounded by the host; handed to the model
    /// only, never written into the session's event log.
    public var imageData: Data?
    public init(attachmentID: String, mimeType: String, width: Int, height: Int, imageData: Data? = nil) {
        self.attachmentID = attachmentID
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.imageData = imageData
    }
}

public struct ReadUITreeRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var targetID: String?
    public var maxDepth: Int
    public init(context: HostCallContext, targetID: String?, maxDepth: Int) {
        self.context = context
        self.targetID = targetID
        self.maxDepth = maxDepth
    }
}

public struct UIElementNode: Sendable, Hashable, Codable {
    public var id: String
    public var role: String
    public var label: String?
    public var value: String?
    /// x, y, width, height in points.
    public var frame: [Double]
    public var children: [UIElementNode]
    public init(
        id: String,
        role: String,
        label: String? = nil,
        value: String? = nil,
        frame: [Double] = [],
        children: [UIElementNode] = [],
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.children = children
    }
}

public struct ReadUITreeResponse: Sendable, Hashable, Codable {
    public var root: UIElementNode
    public init(root: UIElementNode) {
        self.root = root
    }
}

/// The fixed set of UI actions. No free-form command.
public enum UIAction: Sendable, Hashable, Codable {
    case tap(x: Double, y: Double)
    case tapElement(id: String)
    case typeText(String)
    case swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMilliseconds: Int)
    case pressButton(String)

    /// A swipe's duration when the call names none.
    public static let defaultSwipeMilliseconds = 300
}

public struct UIActionRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var targetID: String?
    public var action: UIAction
    public init(context: HostCallContext, targetID: String?, action: UIAction) {
        self.context = context
        self.targetID = targetID
        self.action = action
    }
}

public struct UIActionResponse: Sendable, Hashable, Codable {
    public var performed: Bool
    public var message: String
    /// A type_text's read-back: whether a value that changed while the text
    /// went in holds it, and those values. Absent for other actions, and
    /// when the UI tree could not be read.
    public var typedTextMatches: Bool?
    public var fieldValues: [String]?

    public init(
        performed: Bool,
        message: String = "",
        typedTextMatches: Bool? = nil,
        fieldValues: [String]? = nil,
    ) {
        self.performed = performed
        self.message = message
        self.typedTextMatches = typedTextMatches
        self.fieldValues = fieldValues
    }
}
