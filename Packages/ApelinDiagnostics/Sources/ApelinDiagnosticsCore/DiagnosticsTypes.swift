import Foundation

/// A crash report on the device, by path, newest first in a listing.
public struct CrashReportReference: Codable, Hashable, Sendable {
    public var path: String
    public var name: String {
        (path as NSString).lastPathComponent
    }

    public init(path: String) {
        self.path = path
    }
}

public struct CrashReportListRequest: Codable, Hashable, Sendable {
    /// Keep reports whose file name contains this bundle id or its
    /// executable's name, as icli matches them.
    public var bundleIdentifier: String?
    /// Also keep only names containing this process name (case-insensitive).
    public var processName: String?
    public var limit: Int

    public static let limitRange: ClosedRange<Int> = 1 ... 500
    public static let maximumNameBytes = 256

    public init(bundleIdentifier: String? = nil, processName: String? = nil, limit: Int = 50) {
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.limit = limit
    }
}

public struct CrashReportText: Codable, Hashable, Sendable {
    public var path: String
    public var text: String
    /// The whole file's length in bytes.
    public var size: Int
    public var truncated: Bool

    public init(path: String, text: String, size: Int, truncated: Bool) {
        self.path = path
        self.text = text
        self.size = size
        self.truncated = truncated
    }
}

/// A bounded screenshot attachment: JPEG bytes in memory, never a path.
public struct Screenshot: Codable, Hashable, Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int

    public init(jpeg: Data, width: Int, height: Int) {
        self.jpeg = jpeg
        self.width = width
        self.height = height
    }

    /// The attachment cap. icli's own capture aims under 800 kB.
    public static let maximumBytes = 2 * 1024 * 1024
}

public struct UIRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One accessibility element of the frontmost app. Coordinates are points in
/// the orientation shown on screen.
public struct UIElement: Codable, Hashable, Sendable {
    public var label: String
    public var identifier: String
    public var value: String
    public var role: String
    public var enabled: Bool
    public var clickable: Bool
    public var visible: Bool
    public var frame: UIRect
    /// Where a tap lands: the element's activation point.
    public var tapPoint: UIPoint

    public init(
        label: String,
        identifier: String,
        value: String,
        role: String,
        enabled: Bool,
        clickable: Bool,
        visible: Bool,
        frame: UIRect,
        tapPoint: UIPoint,
    ) {
        self.label = label
        self.identifier = identifier
        self.value = value
        self.role = role
        self.enabled = enabled
        self.clickable = clickable
        self.visible = visible
        self.frame = frame
        self.tapPoint = tapPoint
    }
}

public struct UITree: Codable, Hashable, Sendable {
    public var pid: Int32
    public var elements: [UIElement]
    public var truncated: Bool

    public init(pid: Int32, elements: [UIElement], truncated: Bool) {
        self.pid = pid
        self.elements = elements
        self.truncated = truncated
    }
}

public struct UITreeRequest: Codable, Hashable, Sendable {
    public var maxElements: Int
    public var visibleOnly: Bool
    public var clickableOnly: Bool

    public static let maxElementsRange: ClosedRange<Int> = 1 ... 2000

    public init(maxElements: Int = 250, visibleOnly: Bool = true, clickableOnly: Bool = false) {
        self.maxElements = maxElements
        self.visibleOnly = visibleOnly
        self.clickableOnly = clickableOnly
    }
}

public struct UIPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// How an element is picked for a tap: by its text or identifier, never by
/// a script.
public struct UIElementSelector: Codable, Hashable, Sendable {
    public enum Match: String, Codable, Sendable {
        case contains, exact
    }

    public var text: String?
    public var identifier: String?
    public var role: String?
    public var match: Match
    /// Which hit, when several match, in tree order.
    public var index: Int

    public static let indexRange: ClosedRange<Int> = 0 ... 100
    public static let maximumFieldBytes = 256

    public init(
        text: String? = nil,
        identifier: String? = nil,
        role: String? = nil,
        match: Match = .contains,
        index: Int = 0,
    ) {
        self.text = text
        self.identifier = identifier
        self.role = role
        self.match = match
        self.index = index
    }
}

/// What a press can name: two buttons and icli's wake.
public enum HardwareButton: String, Codable, Hashable, Sendable, CaseIterable {
    /// Lights a dark screen and takes a device without a passcode past its
    /// lock screen; on a device already awake it presses nothing. The one
    /// action that runs while the device is locked or its screen is off.
    case wake
    /// The home button: the front app goes to the home screen.
    case home
    /// The side button: the screen goes off and the device locks.
    case lock

    /// icli's name for it.
    public var icliName: String {
        self == .lock ? "power" : rawValue
    }
}

/// The closed list of UI actions. Each case carries typed parameters; there
/// is no case that takes a command.
public enum UIAction: Codable, Hashable, Sendable {
    case tap(UIPoint)
    case tapElement(UIElementSelector)
    case swipe(from: UIPoint, to: UIPoint, seconds: Double)
    /// Typed one grapheme at a time into the focused field.
    case type(text: String, delayMilliseconds: Double)
    case press(HardwareButton)

    public static let maximumTextBytes = 4 * 1024
    public static let swipeSecondsRange: ClosedRange<Double> = 0.05 ... 5
    public static let typeDelayRange: ClosedRange<Double> = 0 ... 500
    /// icli's own pause between characters. Sent with none, a field dropped
    /// some of them ("Hello world" arrived as "Hello wrd").
    public static let defaultTypeDelayMilliseconds: Double = 30
    /// Points; larger than any screen, smaller than anything absurd.
    public static let coordinateRange: ClosedRange<Double> = 0 ... 10000

    public func validate() throws {
        func check(_ point: UIPoint) throws {
            guard point.x.isFinite, point.y.isFinite, Self.coordinateRange.contains(point.x),
                  Self.coordinateRange.contains(point.y)
            else {
                let range = Self.coordinateRange
                throw DiagnosticsError.invalidParameter(
                    String(format: "coordinates must be %g–%g points", range.lowerBound, range.upperBound),
                )
            }
        }
        switch self {
        case let .tap(point):
            try check(point)
        case let .tapElement(selector):
            guard selector.text?.isEmpty == false || selector.identifier?.isEmpty == false else {
                throw DiagnosticsError.invalidParameter("a selector needs text or an identifier")
            }
            let indexRange = UIElementSelector.indexRange
            guard indexRange.contains(selector.index) else {
                throw DiagnosticsError.invalidParameter("index must be \(indexRange.lowerBound)–\(indexRange.upperBound)")
            }
            let maximumFieldBytes = UIElementSelector.maximumFieldBytes
            for value in [selector.text, selector.identifier, selector.role].compactMap(\.self) {
                guard value.utf8.count <= maximumFieldBytes, !value.contains("\0") else {
                    throw DiagnosticsError.invalidParameter(
                        "selector fields must be at most \(maximumFieldBytes) bytes with no NUL",
                    )
                }
            }
        case let .swipe(from, to, seconds):
            try check(from)
            try check(to)
            guard seconds.isFinite, Self.swipeSecondsRange.contains(seconds) else {
                let range = Self.swipeSecondsRange
                throw DiagnosticsError.invalidParameter(
                    String(format: "swipe must take %g–%g seconds", range.lowerBound, range.upperBound),
                )
            }
        case let .type(text, delay):
            guard !text.isEmpty, text.utf8.count <= Self.maximumTextBytes, !text.contains("\0") else {
                throw DiagnosticsError.invalidParameter("text must be 1–\(Self.maximumTextBytes) bytes with no NUL")
            }
            guard delay.isFinite, Self.typeDelayRange.contains(delay) else {
                let range = Self.typeDelayRange
                throw DiagnosticsError.invalidParameter(
                    String(format: "delay must be %g–%g ms", range.lowerBound, range.upperBound),
                )
            }
        case .press:
            break
        }
    }
}

/// Whether the device is locked and whether its screen is off, as icli's
/// `lockState()` and its wake read them.
public struct LockState: Codable, Hashable, Sendable {
    public var locked: Bool
    public var screenOff: Bool

    public init(locked: Bool, screenOff: Bool) {
        self.locked = locked
        self.screenOff = screenOff
    }

    /// A lit screen past the lock screen: what the UI tree and every action
    /// but a wake need.
    public var allowsInput: Bool {
        !locked && !screenOff
    }
}

/// What an action left: a wake, the lock state (`lock`); a `type`, what it
/// left in the fields (`typed`). Every other action leaves neither, and
/// `Diagnostics.perform` answers nil for it.
public struct UIActionOutcome: Codable, Hashable, Sendable {
    public var lock: LockState?
    public var typed: TypedText?

    public init(lock: LockState? = nil, typed: TypedText? = nil) {
        self.lock = lock
        self.typed = typed
    }
}

/// What a `type` left in the frontmost app, read back from its UI tree.
/// icli names no role for a text field, so the field is found by what
/// changed: the values the visible elements hold that they did not hold
/// before the text went in.
public struct TypedText: Codable, Hashable, Sendable {
    /// Whether one of the values that changed holds the typed text.
    public var matches: Bool
    /// The values that changed, in tree order, at most `maximumValues`,
    /// each cut to `maximumValueCharacters`.
    public var fieldValues: [String]

    public static let maximumValues = 8
    public static let maximumValueCharacters = 2000

    public init(matches: Bool, fieldValues: [String]) {
        self.matches = matches
        self.fieldValues = fieldValues
    }

    /// Compares two reads of every visible element's value. A value counts
    /// as changed when the earlier read held it fewer times, so a field
    /// that moved in the tree is not taken for one that changed.
    public init(typed text: String, before: [String], after: [String]) {
        var held = [String: Int]()
        for value in before where !value.isEmpty {
            held[value, default: 0] += 1
        }
        var changed = [String]()
        for value in after where !value.isEmpty {
            if let count = held[value], count > 0 {
                held[value] = count - 1
            } else {
                changed.append(value)
            }
        }
        self.init(
            matches: changed.contains { $0.contains(text) },
            fieldValues: changed.prefix(Self.maximumValues).map { String($0.prefix(Self.maximumValueCharacters)) },
        )
    }
}

public struct ForegroundApp: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    /// True only when RunningBoard named exactly one focal app. Act on the
    /// UI only when this is true.
    public var verified: Bool
    public var source: String

    public init(bundleIdentifier: String, verified: Bool, source: String) {
        self.bundleIdentifier = bundleIdentifier
        self.verified = verified
        self.source = source
    }
}

public struct ProcessRow: Codable, Hashable, Sendable {
    public var pid: Int32
    public var name: String
    public var executable: String
    /// The app's bundle id; empty only when icli's row carries none.
    public var bundleIdentifier: String

    public init(pid: Int32, name: String, executable: String, bundleIdentifier: String) {
        self.pid = pid
        self.name = name
        self.executable = executable
        self.bundleIdentifier = bundleIdentifier
    }

    /// The most bytes of a process's name the kernel keeps (`MAXCOMLEN`); a
    /// longer name is cut there.
    public static let kernelNameBytes = 16

    /// Whether this process runs the executable called `executableName`:
    /// the last component of its path, compared as the log's process names
    /// are (case aside), or, when the kernel gave no path (the file was
    /// replaced while it ran, or the path was not this process's to read),
    /// the kernel's name, which for a longer executable name is its first
    /// 16 bytes.
    public func runs(_ executableName: String) -> Bool {
        if !executable.isEmpty {
            return (executable as NSString).lastPathComponent.caseInsensitiveCompare(executableName) == .orderedSame
        }
        guard !name.isEmpty else { return false }
        if name.caseInsensitiveCompare(executableName) == .orderedSame {
            return true
        }
        let cut = Self.kernelNameBytes
        guard executableName.utf8.count > cut, name.utf8.count == cut else { return false }
        return String(decoding: executableName.utf8.prefix(cut), as: UTF8.self).caseInsensitiveCompare(name) == .orderedSame
    }
}

/// Anything that lists the processes running now, by pid, the kernel's
/// name and the executable's path: `Diagnostics`, through icli's process
/// list (sysctl `KERN_PROC_ALL` and `proc_pidpath`). Nothing inside a
/// process is read: never its image list, its task port or its memory map.
public protocol ProcessListSource: Sendable {
    /// Every process now; each row's `bundleIdentifier` is empty.
    func processes() throws -> [ProcessRow]
}

public struct RespringResult: Codable, Hashable, Sendable {
    /// `frontboard_relaunch` or `launchd_stop`.
    public var method: String
    public var previousPID: Int32
    public var pid: Int32

    public init(method: String, previousPID: Int32, pid: Int32) {
        self.method = method
        self.previousPID = previousPID
        self.pid = pid
    }
}
