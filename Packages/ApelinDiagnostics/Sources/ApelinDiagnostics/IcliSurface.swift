import ApelinDiagnosticsCore
import Foundation

/// The IcliKit calls the diagnostics worker makes, one for one, with icli's
/// own parameter names and its JSON-shaped dictionaries. `IcliKitSurface` is
/// the real one and exists only where IcliKit builds (iOS); the Mac tests
/// pass a fake that returns recorded dictionaries, so everything above this
/// line — validation, bounds, decoding — runs in `swift test`.
///
/// A thrown error is either `IcliError` (mapped by the surface into
/// `DiagnosticsError`) or a Foundation error.
public protocol IcliSurface: Sendable {
    func captureSyslog(seconds: Double, filter: IcliSyslogFilter, maxLines: Int) throws -> [String: Any]
    /// icli's `SyslogStream`: `handler` gets each entry icli's filter keeps,
    /// one at a time and in arrival order, until `seconds` pass, `handler`
    /// answers false, the system ends the stream or `cancel()` is called;
    /// `onEnd` then runs once, with icli's `SyslogStreamEnd` raw value
    /// (`cancelled`, `duration`, `handler`, `interrupted`). Entries come as
    /// `LogEntry`, since icli's `SyslogEntry` needs IcliKit to name.
    func openSyslogStream(
        filter: IcliSyslogFilter,
        seconds: Double,
        handler: @escaping @Sendable (LogEntry) -> Bool,
        onEnd: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream
    func crashLogs(bundleID: String?) throws -> [String: Any]
    func readCrashLog(_ path: String, maxBytes: Int) throws -> [String: Any]
    func takeScreenshot() throws -> [String: Any]
    func uiElements(maxElements: Int, visibleOnly: Bool, clickableOnly: Bool) throws -> [String: Any]
    func tap(x: Double, y: Double) throws -> [String: Any]
    func tapElement(
        text: String?,
        identifier: String?,
        role: String?,
        match: String,
        index: Int,
    ) throws -> [String: Any]
    /// icli's `waitForElement`: polls the tree every `interval` until the
    /// selected element is present (`appear`) or gone, and answers its
    /// result, whose `found` says which. Where icli throws because
    /// `timeout` passed first, this answers `found: !appear` instead.
    func waitForElement(
        text: String?,
        identifier: String?,
        role: String?,
        match: String,
        index: Int,
        appear: Bool,
        timeout: Double,
        interval: Double,
    ) throws -> [String: Any]
    func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double) throws -> [String: Any]
    func typeText(_ text: String, delayMS: Double) throws -> [String: Any]
    /// icli's `pressButton`, by icli's name (`home`, `power`, `wake`). It
    /// checks no lock state itself; a wake answers `locked` and `screen_off`
    /// as they are after it.
    func pressButton(_ name: String) throws -> [String: Any]
    func frontmostApp() -> [String: Any]
    func lockState() -> [String: Any]
    /// icli's `screenInfo`: `width` and `height` in points in the
    /// orientation shown, with `locked` and `screen_off`.
    func screenInfo() -> [String: Any]
    func runningApps() throws -> [String: Any]
    func respring() throws -> [String: Any]
}

/// The fields of icli's `SyslogFilter` Apelin sets: what icli matches before
/// it counts or delivers anything.
public struct IcliSyslogFilter: Sendable, Hashable {
    /// A case-insensitive substring of the process name.
    public var process: String?
    /// The subsystem or a dotted child of it.
    public var subsystem: String?
    /// A case-sensitive substring of the message.
    public var messageContains: String?
    /// The minimum level in icli's names: `all`, `debug`, `info`, `default`,
    /// `error`, `fault`.
    public var level: String

    public init(
        process: String? = nil,
        subsystem: String? = nil,
        messageContains: String? = nil,
        level: String = "all",
    ) {
        self.process = process
        self.subsystem = subsystem
        self.messageContains = messageContains
        self.level = level
    }
}

/// One open icli `SyslogStream`. No entry reaches the handler once `cancel()`
/// has returned; a second call does nothing.
public protocol IcliSyslogStream: AnyObject, Sendable {
    func cancel()
}
