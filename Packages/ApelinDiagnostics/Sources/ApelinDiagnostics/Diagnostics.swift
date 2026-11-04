@_exported import ApelinDiagnosticsCore
import Foundation

/// The mobile diagnostics worker's capabilities, every one of them through
/// icli (the owner's rule: what icli can do is done with icli). This type
/// adds what a closed protocol needs on top: typed parameters with bounds,
/// a crash-report path allowlist, attachment caps, and typed results.
///
/// Calls are synchronous and may block for their window; run them off the
/// main thread.
public struct Diagnostics: LogEvidenceSource, LiveLogSource {
    private let icli: any IcliSurface
    /// How long a UI read or element tap waits for the foreground to settle
    /// (`settledForegroundApp`), and how often it asks.
    public var settleTimeout: TimeInterval = 3
    public var settleInterval: TimeInterval = 0.25
    /// How long an element tap waits for its element to be in the tree (a
    /// menu still animating in), and how often icli looks.
    public var elementTimeout: TimeInterval = 3
    public var elementInterval: TimeInterval = 0.3

    public init(icli: any IcliSurface) {
        self.icli = icli
    }

    #if os(iOS) && canImport(IcliKit)
        /// IcliKit in this process.
        public init() {
            self.init(icli: IcliKitSurface())
        }
    #endif

    // MARK: Logs

    /// What icli is asked to match before it caps or delivers anything.
    /// Subsystem (with its dotted children), message substring (case-sensitive)
    /// and minimum level mean in icli exactly what they mean in `LogFilter`.
    /// Two fields differ and stay Apelin's: icli's `process`
    /// is a substring where Apelin's is the whole name (so icli gets it as a
    /// narrowing and `LogFilter.matches` decides), and icli has no `since`.
    /// Every entry icli hands back still passes through `LogFilter.matches`,
    /// the one definition both log readers share.
    static func icliFilter(_ filter: LogFilter) -> IcliSyslogFilter {
        IcliSyslogFilter(
            process: filter.process,
            subsystem: filter.subsystem,
            messageContains: filter.messageContains,
            level: filter.minimumLevel.rawValue,
        )
    }

    /// One bounded read. icli's cap counts what its own filter kept, so when
    /// a field only Apelin checks is set (process, since) icli is asked for
    /// its full 5000, and if the cap still falls first `truncated` says so.
    public func readLogs(_ filter: LogFilter) throws -> LogReadResult {
        try filter.validate()
        let narrowedHere = filter.process != nil || filter.since != nil
        let rawCap = narrowedHere
            ? LogFilter.maxEntriesRange.upperBound
            : min(filter.maxEntries + 1, LogFilter.maxEntriesRange.upperBound)
        let raw = try icli.captureSyslog(seconds: filter.duration, filter: Self.icliFilter(filter), maxLines: rawCap)
        return Self.decodeLogs(raw, filter: filter)
    }

    /// How long `listen` waits for the system to refuse the stream.
    public static let refusalProbeSeconds: TimeInterval = 1

    /// One icli `SyslogStream` for the whole window: no seam, nothing read
    /// twice. A stream the system ends (`interrupted`) within the first
    /// second, before anything matched, is a refusal — this process may not
    /// read the live log — and throws `unavailable`, which `logStream`
    /// answers as `denied` so the host turns to the root reader. Ended that
    /// way later, it lost the rest of its window, and says so as dropped.
    public func listen(
        _ filter: LogFilter,
        until deadline: Date,
        deliver: @escaping @Sendable (LogEntry) -> Bool,
    ) throws -> LiveLogListener {
        try filter.validateMatchFields()
        let seconds = max(0.1, deadline.timeIntervalSinceNow)
        let listener = LiveLogListener(deadline: deadline, deliver: deliver)
        let heard = Heard()
        let stream = try icli.openSyslogStream(
            filter: Self.icliFilter(filter),
            seconds: seconds,
            handler: { entry in
                guard filter.matches(entry) else { return true }
                heard.matched()
                return listener.offer(entry)
            },
            onEnd: { reason in
                if reason == "interrupted" {
                    heard.interrupted()
                    listener.markDropped()
                }
                listener.finish()
            },
        )
        listener.onEnd { stream.cancel() }
        listener.settle(until: Date().addingTimeInterval(min(Self.refusalProbeSeconds, seconds)))
        if heard.refused {
            throw DiagnosticsError.unavailable("The unified log ended the live stream at once: this process may not read it.")
        }
        return listener
    }

    /// What one stream has heard, for telling a refusal from a lost end.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        @objc private dynamic var anything = false
        @objc private dynamic var cut = false

        @objc dynamic func matched() {
            lock.lock()
            anything = true
            lock.unlock()
        }

        @objc dynamic func interrupted() {
            lock.lock()
            cut = true
            lock.unlock()
        }

        @objc dynamic var refused: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cut && !anything
        }
    }

    static func decodeLogs(_ raw: [String: Any], filter: LogFilter) -> LogReadResult {
        let rows = raw["entries"] as? [[String: Any]] ?? []
        let formatter = ISO8601DateFormatter()
        var kept = [LogEntry]()
        var overflow = false
        for row in rows {
            let entry = LogEntry(
                date: (row["date"] as? String).flatMap(formatter.date(from:)),
                process: row["process"] as? String ?? "",
                pid: Int32(clamping: (row["pid"] as? NSNumber)?.intValue ?? 0),
                subsystem: row["subsystem"] as? String ?? "",
                category: row["category"] as? String ?? "",
                level: LogLevel(icliName: row["level"] as? String ?? ""),
                message: row["message"] as? String ?? "",
            )
            guard filter.matches(entry) else { continue }
            if kept.count == filter.maxEntries {
                overflow = true
                break
            }
            kept.append(entry)
        }
        let sourceTruncated = raw["truncated"] as? Bool ?? false
        return LogReadResult(entries: kept, truncated: overflow || sourceTruncated, source: .icli)
    }

    // MARK: Crash reports

    /// Where icli looks, and the only places `readCrashReport` reads from.
    public static let crashDirectories = [
        "/var/mobile/Library/Logs/CrashReporter",
        "/var/mobile/Library/Logs/DiagnosticReports",
        "/var/mobile/Library/Logs/CrashReporter/Retired",
    ]

    /// What a crash report's file name ends with.
    public static let crashReportExtensions = [".ips", ".crash"]

    public func listCrashReports(_ request: CrashReportListRequest) throws -> [CrashReportReference] {
        guard CrashReportListRequest.limitRange.contains(request.limit) else {
            throw DiagnosticsError.invalidParameter("limit must be \(CrashReportListRequest.limitRange.lowerBound)–\(CrashReportListRequest.limitRange.upperBound)")
        }
        let maximumNameBytes = CrashReportListRequest.maximumNameBytes
        for value in [request.bundleIdentifier, request.processName].compactMap(\.self) {
            guard !value.isEmpty, value.utf8.count <= maximumNameBytes, !value.contains("/"), !value.contains("\0") else {
                throw DiagnosticsError.invalidParameter("names must be 1–\(maximumNameBytes) bytes with no slash or NUL")
            }
        }
        return try Self.decodeCrashList(icli.crashLogs(bundleID: request.bundleIdentifier), request: request)
    }

    static func decodeCrashList(_ raw: [String: Any], request: CrashReportListRequest) -> [CrashReportReference] {
        let paths = raw["crashes"] as? [String] ?? []
        return paths
            .filter { path in
                request.processName.map { (path as NSString).lastPathComponent.localizedCaseInsensitiveContains($0) }
                    ?? true
            }
            .prefix(request.limit)
            .map(CrashReportReference.init(path:))
    }

    /// The largest report read whole from the host's descriptor (the host's
    /// own `crashOpen` bound).
    public static let maximumCrashFileBytes = 16 * 1024 * 1024
    public static let crashTextRange: ClosedRange<Int> = 1 ... 4 * 1024 * 1024

    /// Reads one report, if it is a `.ips` or `.crash` directly inside one of
    /// `crashDirectories` after `realpath(3)`. icli reads at most `maxBytes`,
    /// cut back to a whole character, and refuses anything but a regular
    /// file. Protected reports (root-only) are not this call's: the session
    /// host opens those by report id and hands over a read-only descriptor.
    public func readCrashReport(path: String, maxBytes: Int = 1024 * 1024) throws -> CrashReportText {
        guard Self.crashTextRange.contains(maxBytes) else {
            let range = Self.crashTextRange
            throw DiagnosticsError.invalidParameter("maxBytes must be \(range.lowerBound) B–\(range.upperBound >> 20) MB")
        }
        guard let canonical = Self.allowedCrashPath(path) else {
            throw DiagnosticsError.invalidParameter("The path is not a crash report in a crash report directory.")
        }
        return try Self.decodeCrashText(icli.readCrashLog(canonical, maxBytes: maxBytes))
    }

    static func allowedCrashPath(_ path: String) -> String? {
        guard !path.contains("\0"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard crashReportExtensions.contains(where: canonical.hasSuffix) else { return nil }
        let parent = (canonical as NSString).deletingLastPathComponent
        for directory in crashDirectories {
            guard let root = realpath(directory, nil) else { continue }
            defer { free(root) }
            if String(cString: root) == parent {
                return canonical
            }
        }
        return nil
    }

    static func decodeCrashText(_ raw: [String: Any]) -> CrashReportText {
        let content = raw["content"] as? String ?? ""
        return CrashReportText(
            path: raw["path"] as? String ?? "",
            text: content,
            size: (raw["size"] as? NSNumber)?.intValue ?? content.utf8.count,
            truncated: raw["truncated"] as? Bool ?? false,
        )
    }

    // MARK: Screen and UI

    public func screenshot() throws -> Screenshot {
        try Self.decodeScreenshot(icli.takeScreenshot())
    }

    static func decodeScreenshot(_ raw: [String: Any]) throws -> Screenshot {
        guard let encoded = raw["data"] as? String,
              encoded.utf8.count <= (Screenshot.maximumBytes / 3 + 1) * 4,
              let jpeg = Data(base64Encoded: encoded)
        else {
            throw DiagnosticsError.failed("The screenshot is missing or larger than the attachment size limit.")
        }
        guard jpeg.count <= Screenshot.maximumBytes else {
            throw DiagnosticsError.failed("The screenshot is larger than the attachment size limit.")
        }
        return Screenshot(
            jpeg: jpeg,
            width: (raw["width"] as? NSNumber)?.intValue ?? 0,
            height: (raw["height"] as? NSNumber)?.intValue ?? 0,
        )
    }

    /// `settled` is a `settledForegroundApp()` read the caller already made
    /// (to bind the request to a target); without one, this waits itself.
    public func uiTree(
        _ request: UITreeRequest = UITreeRequest(),
        settled: ForegroundApp? = nil,
    ) throws -> UITree {
        guard UITreeRequest.maxElementsRange.contains(request.maxElements) else {
            throw DiagnosticsError.invalidParameter("maxElements must be \(UITreeRequest.maxElementsRange.lowerBound)–\(UITreeRequest.maxElementsRange.upperBound)")
        }
        try requireUnlocked()
        try requireSettledForeground(settled)
        return try Self.decodeTree(icli.uiElements(
            maxElements: request.maxElements,
            visibleOnly: request.visibleOnly,
            clickableOnly: request.clickableOnly,
        ))
    }

    static func decodeTree(_ raw: [String: Any]) -> UITree {
        let rows = raw["elements"] as? [[String: Any]] ?? []
        return UITree(
            pid: Int32(clamping: (raw["pid"] as? NSNumber)?.intValue ?? 0),
            elements: rows.map(decodeElement),
            truncated: raw["truncated"] as? Bool ?? false,
        )
    }

    static func decodeElement(_ row: [String: Any]) -> UIElement {
        func double(_ value: Any?) -> Double {
            (value as? NSNumber)?.doubleValue ?? 0
        }
        let frame = row["frame"] as? [String: Any] ?? [:]
        let value: String = switch row["value"] {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
        return UIElement(
            label: row["label"] as? String ?? "",
            identifier: row["identifier"] as? String ?? "",
            value: value,
            role: row["role"] as? String ?? "",
            enabled: row["enabled"] as? Bool ?? false,
            clickable: row["clickable"] as? Bool ?? false,
            visible: row["visible"] as? Bool ?? false,
            frame: UIRect(
                x: double(frame["x"]),
                y: double(frame["y"]),
                width: double(frame["width"]),
                height: double(frame["height"]),
            ),
            tapPoint: UIPoint(x: double(row["x"]), y: double(row["y"])),
        )
    }

    /// One action from the closed list, after its parameters pass and the
    /// device is unlocked. The caller has already bound it to a verified
    /// target (`foregroundApp().verified`); this does not re-decide that.
    /// `settled` is as for `uiTree`: an element tap waits for the foreground
    /// to settle only when the caller has not.
    ///
    /// A wake is the way back from a locked device or a dark screen, so it
    /// alone needs neither, and it answers the lock state it left: a device
    /// with a passcode stays on its lock screen until the user unlocks it.
    /// A `type` answers what it left in the fields (`typeReadingBack`).
    /// Every other action answers nil.
    @discardableResult
    public func perform(
        _ action: UIAction,
        settled: ForegroundApp? = nil,
    ) throws -> UIActionOutcome? {
        try action.validate()
        if action == .press(.wake) {
            return try UIActionOutcome(lock: Self.decodeLock(icli.pressButton(HardwareButton.wake.icliName)))
        }
        try requireUnlocked()
        switch action {
        case let .tap(point):
            _ = try icli.tap(x: point.x, y: point.y)
        case let .tapElement(selector):
            try requireSettledForeground(settled)
            try waitForElement(selector)
            _ = try icli.tapElement(
                text: selector.text,
                identifier: selector.identifier,
                role: selector.role,
                match: selector.match.rawValue,
                index: selector.index,
            )
        case let .swipe(from, to, seconds):
            _ = try icli.swipe(x1: from.x, y1: from.y, x2: to.x, y2: to.y, seconds: seconds)
        case let .type(text, delay):
            return try typeReadingBack(text, delayMilliseconds: delay).map { UIActionOutcome(typed: $0) }
        case let .press(button):
            // Home and the side button; the wake went above.
            _ = try icli.pressButton(button.icliName)
        }
        return nil
    }

    /// An element a tap names may not be in the tree yet: a menu or sheet
    /// still animating in. Waits for it up to `elementTimeout`, and taps
    /// once, after, so a tap is never sent twice.
    private func waitForElement(_ selector: UIElementSelector) throws {
        let wait = try icli.waitForElement(
            text: selector.text,
            identifier: selector.identifier,
            role: selector.role,
            match: selector.match.rawValue,
            index: selector.index,
            appear: true,
            timeout: elementTimeout,
            interval: elementInterval,
        )
        guard wait["found"] as? Bool == true else {
            let name = selector.identifier ?? selector.text ?? ""
            throw DiagnosticsError.failed("element \"\(name)\" did not appear within \(Int(elementTimeout)) s; read the UI tree again")
        }
    }

    /// Types `text`, then reads the frontmost app's values back
    /// (`TypedText`). The read after is taken again, `settleInterval` apart,
    /// until a value holds the text, two reads agree or `settleTimeout`
    /// passes, so a read taken while the app is still taking the last
    /// characters is not the answer. Nil when either read fails or reads
    /// another app (an app switch, a foreground icli cannot verify): the
    /// text is typed all the same.
    private func typeReadingBack(_ text: String, delayMilliseconds: Double) throws -> TypedText? {
        let before = try? visibleTree()
        _ = try icli.typeText(text, delayMS: delayMilliseconds)
        guard let before else { return nil }
        let deadline = Date().addingTimeInterval(settleTimeout)
        var previous: [String]?
        while true {
            guard let after = try? visibleTree(), after.pid == before.pid else { return nil }
            let values = after.elements.map(\.value)
            let typed = TypedText(typed: text, before: before.elements.map(\.value), after: values)
            if typed.matches || values == previous || Date() >= deadline {
                return typed
            }
            previous = values
            Thread.sleep(forTimeInterval: settleInterval)
        }
    }

    /// Every visible element, as many as icli reads: the field typed into
    /// can be anywhere in the tree.
    private func visibleTree() throws -> UITree {
        try Self.decodeTree(icli.uiElements(
            maxElements: UITreeRequest.maxElementsRange.upperBound,
            visibleOnly: true,
            clickableOnly: false,
        ))
    }

    private func requireUnlocked() throws {
        let lock = Self.decodeLock(icli.lockState())
        guard lock.allowsInput else {
            throw DiagnosticsError.locked(screenOff: lock.screenOff)
        }
    }

    /// icli's `locked` and `screen_off`, from `lockState()` or a wake; a
    /// field it leaves out reads as false.
    static func decodeLock(_ raw: [String: Any]) -> LockState {
        LockState(locked: raw["locked"] as? Bool ?? false, screenOff: raw["screen_off"] as? Bool ?? false)
    }

    // MARK: Apps

    public func foregroundApp() -> ForegroundApp {
        Self.decodeForeground(icli.frontmostApp())
    }

    /// The foreground app once an app switch has finished: the same verified
    /// app on two reads in a row, `settleInterval` apart. While SpringBoard
    /// moves between apps RunningBoard names no single focal app — for about
    /// a second after an app comes to the front — and icli's UI tree and
    /// element taps refuse with "frontmost application could not be
    /// verified". Gives up after `settleTimeout` and answers the last read,
    /// verified or not.
    ///
    /// With `expecting`, only that app settles it: the app a switch is
    /// leaving can be the verified front on two reads in a row, which says
    /// nothing of the app an action is bound to (one bound to Fila, sent
    /// right after Fila was opened, was refused while the front went
    /// between Fila and Apelin).
    public func settledForegroundApp(expecting bundleIdentifier: String? = nil) -> ForegroundApp {
        let deadline = Date().addingTimeInterval(settleTimeout)
        var previous: ForegroundApp?
        while true {
            let front = foregroundApp()
            if front.verified, front == previous, bundleIdentifier.map({ $0 == front.bundleIdentifier }) ?? true {
                return front
            }
            previous = front.verified ? front : nil
            if Date() >= deadline {
                return front
            }
            Thread.sleep(forTimeInterval: settleInterval)
        }
    }

    private func requireSettledForeground(_ settled: ForegroundApp?) throws {
        let front = settled ?? settledForegroundApp()
        guard front.verified else {
            throw DiagnosticsError.unavailable("the foreground app did not settle within \(Int(settleTimeout)) s (an app switch, a system alert or several apps on screen); try again")
        }
    }

    static func decodeForeground(_ raw: [String: Any]) -> ForegroundApp {
        ForegroundApp(
            bundleIdentifier: raw["bundle_id"] as? String ?? "",
            verified: raw["verified"] as? Bool ?? false,
            source: raw["source"] as? String ?? "unavailable",
        )
    }

    /// Running apps with their bundle ids, from RunningBoard when it answers.
    public func runningApps() throws -> [ProcessRow] {
        try Self.decodeRunningApps(icli.runningApps())
    }

    static func decodeRunningApps(_ raw: [String: Any]) -> [ProcessRow] {
        (raw["apps"] as? [[String: Any]] ?? []).map { row in
            ProcessRow(
                pid: Int32(clamping: (row["pid"] as? NSNumber)?.intValue ?? 0),
                name: row["name"] as? String ?? "",
                executable: row["executable"] as? String ?? "",
                bundleIdentifier: row["bundle_id"] as? String ?? "",
            )
        }
    }

    // MARK: Respring

    /// The fallback respring. The normal path is apelind's closed operation;
    /// this is for when the worker must do it itself. FrontBoard relaunch
    /// first, then launchd stop of `com.apple.SpringBoard`.
    public func respring() throws -> RespringResult {
        try Self.decodeRespring(icli.respring())
    }

    static func decodeRespring(_ raw: [String: Any]) -> RespringResult {
        RespringResult(
            method: raw["method"] as? String ?? "",
            previousPID: Int32(clamping: (raw["previous_pid"] as? NSNumber)?.intValue ?? 0),
            pid: Int32(clamping: (raw["pid"] as? NSNumber)?.intValue ?? 0),
        )
    }
}
