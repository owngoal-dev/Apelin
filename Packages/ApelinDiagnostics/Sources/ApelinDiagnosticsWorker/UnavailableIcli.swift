import ApelinDiagnostics

/// Unavailable everywhere icli is not linked (the Mac the harness runs on).
struct UnavailableIcli: IcliSurface {
    private func missing() -> DiagnosticsError {
        .unavailable("Device diagnostics are not available on this platform.")
    }

    func captureSyslog(seconds _: Double, filter _: IcliSyslogFilter, maxLines _: Int) throws -> [String: Any] {
        throw missing()
    }

    func openSyslogStream(
        filter _: IcliSyslogFilter,
        seconds _: Double,
        handler _: @escaping @Sendable (LogEntry) -> Bool,
        onEnd _: @escaping @Sendable (String) -> Void,
    ) throws -> any IcliSyslogStream {
        throw missing()
    }

    func crashLogs(bundleID _: String?) throws -> [String: Any] {
        throw missing()
    }

    func readCrashLog(_: String, maxBytes _: Int) throws -> [String: Any] {
        throw missing()
    }

    func takeScreenshot() throws -> [String: Any] {
        throw missing()
    }

    func uiElements(maxElements _: Int, visibleOnly _: Bool, clickableOnly _: Bool) throws -> [String: Any] {
        throw missing()
    }

    func tap(x _: Double, y _: Double) throws -> [String: Any] {
        throw missing()
    }

    func tapElement(
        text _: String?,
        identifier _: String?,
        role _: String?,
        match _: String,
        index _: Int,
    ) throws -> [String: Any] {
        throw missing()
    }

    func waitForElement(
        text _: String?,
        identifier _: String?,
        role _: String?,
        match _: String,
        index _: Int,
        appear _: Bool,
        timeout _: Double,
        interval _: Double,
    ) throws -> [String: Any] {
        throw missing()
    }

    func swipe(x1 _: Double, y1 _: Double, x2 _: Double, y2 _: Double, seconds _: Double) throws -> [String: Any] {
        throw missing()
    }

    func typeText(_: String, delayMS _: Double) throws -> [String: Any] {
        throw missing()
    }

    func pressButton(_: String) throws -> [String: Any] {
        throw missing()
    }

    func frontmostApp() -> [String: Any] {
        [:]
    }

    func lockState() -> [String: Any] {
        [:]
    }

    func screenInfo() -> [String: Any] {
        [:]
    }

    func runningApps() throws -> [String: Any] {
        throw missing()
    }

    func respring() throws -> [String: Any] {
        throw missing()
    }
}
