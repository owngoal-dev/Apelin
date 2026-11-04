#if os(iOS) && canImport(IcliKit)
    import ApelinDiagnosticsCore
    import Foundation
    import IcliKit
    import IcliLaunch
    import IcliSystem

    /// The real surface: IcliKit, in-process. iOS only — IcliKit is an
    /// on-device library and declares no macOS platform; the package links it
    /// for iOS alone, and on the Mac this file compiles to nothing.
    ///
    /// Every call is synchronous and some block (a log capture blocks for its
    /// whole window; a stream does not). Call from a worker thread, never the
    /// main thread.
    public struct IcliKitSurface: IcliSurface {
        public init() {}

        public func captureSyslog(seconds: Double, filter: IcliSyslogFilter, maxLines: Int) throws -> [String: Any] {
            try mapped {
                try IcliKit.captureSyslog(seconds: seconds, filter: Self.syslogFilter(filter), maxLines: maxLines)
            }
        }

        public func openSyslogStream(
            filter: IcliSyslogFilter,
            seconds: Double,
            handler: @escaping @Sendable (LogEntry) -> Bool,
            onEnd: @escaping @Sendable (String) -> Void,
        ) throws -> any IcliSyslogStream {
            try mapped {
                let stream = try SyslogStream(
                    filter: Self.syslogFilter(filter),
                    seconds: seconds,
                    handler: { entry in
                        handler(LogEntry(
                            date: entry.date,
                            process: entry.process,
                            pid: entry.pid,
                            subsystem: entry.subsystem,
                            category: entry.category,
                            level: LogLevel(icliName: entry.level),
                            message: entry.message,
                        ))
                    },
                    onEnd: { end in onEnd(end.rawValue) },
                )
                return OpenStream(stream)
            }
        }

        private static func syslogFilter(_ filter: IcliSyslogFilter) -> SyslogFilter {
            SyslogFilter(
                process: filter.process,
                subsystem: filter.subsystem,
                messageContains: filter.messageContains,
                level: filter.level,
            )
        }

        /// Keeps the stream alive: releasing an icli `SyslogStream` cancels it.
        private final class OpenStream: IcliSyslogStream, @unchecked Sendable {
            private let stream: SyslogStream

            init(_ stream: SyslogStream) {
                self.stream = stream
            }

            @objc dynamic func cancel() {
                stream.cancel()
            }
        }

        public func crashLogs(bundleID: String?) throws -> [String: Any] {
            try mapped { try IcliKit.crashLogs(bundleID: bundleID) }
        }

        public func readCrashLog(_ path: String, maxBytes: Int) throws -> [String: Any] {
            try mapped { try IcliKit.readCrashLog(path, maxBytes: maxBytes) }
        }

        public func takeScreenshot() throws -> [String: Any] {
            try mapped { try IcliKit.takeScreenshot(path: nil, base64: true, nativeResolution: false) }
        }

        public func uiElements(maxElements: Int, visibleOnly: Bool, clickableOnly: Bool) throws -> [String: Any] {
            try mapped {
                try IcliKit.uiElements(maxElements: maxElements, visibleOnly: visibleOnly, clickableOnly: clickableOnly)
            }
        }

        public func tap(x: Double, y: Double) throws -> [String: Any] {
            try mapped { try IcliKit.tap(x: x, y: y) }
        }

        public func tapElement(
            text: String?,
            identifier: String?,
            role: String?,
            match: String,
            index: Int,
        ) throws -> [String: Any] {
            try mapped {
                let selector = try ElementSelector(
                    text: text,
                    identifier: identifier,
                    role: role,
                    match: match,
                    index: index,
                )
                return try IcliKit.tapElement(selector)
            }
        }

        public func waitForElement(
            text: String?,
            identifier: String?,
            role: String?,
            match: String,
            index: Int,
            appear: Bool,
            timeout: Double,
            interval: Double,
        ) throws -> [String: Any] {
            try mapped {
                let selector = try ElementSelector(
                    text: text,
                    identifier: identifier,
                    role: role,
                    match: match,
                    index: index,
                )
                do {
                    return try IcliKit.waitForElement(selector, appear: appear, timeout: timeout, interval: interval)
                } catch let IcliError.failed(message) where message == Self.elementWaitTimedOut {
                    return ["found": !appear]
                }
            }
        }

        /// What icli 0.9.0's `waitForElement` throws when its time runs out.
        private static let elementWaitTimedOut = "element wait timed out"

        public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double) throws -> [String: Any] {
            try mapped { try IcliKit.swipe(x1: x1, y1: y1, x2: x2, y2: y2, seconds: seconds) }
        }

        public func typeText(_ text: String, delayMS: Double) throws -> [String: Any] {
            try mapped { try IcliKit.typeText(text, delayMS: delayMS) }
        }

        public func pressButton(_ name: String) throws -> [String: Any] {
            try mapped { try IcliKit.pressButton(name) }
        }

        public func frontmostApp() -> [String: Any] {
            IcliLaunch.frontmostApp()
        }

        public func lockState() -> [String: Any] {
            IcliLaunch.lockState()
        }

        public func runningApps() throws -> [String: Any] {
            try mapped { try IcliKit.runningApps() }
        }

        public func respring() throws -> [String: Any] {
            try mapped { try IcliKit.respring() }
        }

        private func mapped<T>(_ body: () throws -> T) throws -> T {
            do {
                return try body()
            } catch let error as IcliError {
                switch error {
                case .locked: throw DiagnosticsError.locked(screenOff: Diagnostics.decodeLock(lockState()).screenOff)
                case let .unavailable(message): throw DiagnosticsError.unavailable(message)
                default: throw DiagnosticsError.failed(error.message)
                }
            }
        }
    }
#endif
