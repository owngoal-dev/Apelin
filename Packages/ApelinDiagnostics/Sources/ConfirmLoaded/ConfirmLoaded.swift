import ApelinDiagnosticsCore
import Foundation

/// What to confirm: a tweak, the process it should be in, and the marker line
/// its constructor logs (templates log `<marker>` once from their constructor;
/// ApelinHello logs `ApelinHello: loaded into <process>`).
public struct LoadConfirmationRequest: Codable, Hashable, Sendable {
    /// Case-sensitive text the tweak's constructor logs.
    public var marker: String
    /// The subsystem the marker is logged under, when the template uses one.
    public var markerSubsystem: String?
    /// The target's executable name, `SpringBoard`.
    public var targetExecutable: String
    /// The target's main bundle identifier, for the filter check.
    public var targetBundleIdentifier: String?
    /// The installed dylib, spelled any way that resolves on this device.
    /// Reported, never looked up in the target: see `ConfirmLoaded`.
    public var dylibPath: String
    /// The filter plist's bytes, as installed beside the dylib.
    public var filterPlist: Data?
    /// The device's `kCFCoreFoundationVersionNumber`, for a filter that asks.
    public var coreFoundationVersion: Double?
    /// How long to listen for the marker at most, in seconds; the listen
    /// ends as soon as the target logs it.
    public var logWindow: TimeInterval

    public init(
        marker: String,
        markerSubsystem: String? = nil,
        targetExecutable: String,
        targetBundleIdentifier: String? = nil,
        dylibPath: String,
        filterPlist: Data? = nil,
        coreFoundationVersion: Double? = nil,
        logWindow: TimeInterval = 15,
    ) {
        self.marker = marker
        self.markerSubsystem = markerSubsystem
        self.targetExecutable = targetExecutable
        self.targetBundleIdentifier = targetBundleIdentifier
        self.dylibPath = dylibPath
        self.filterPlist = filterPlist
        self.coreFoundationVersion = coreFoundationVersion
        self.logWindow = logWindow
    }

    /// The fixed log request the marker check makes. A listen keeps its own
    /// window (`logWindow`), so `duration` is only kept within its range.
    public var markerFilter: LogFilter {
        LogFilter(
            subsystem: markerSubsystem,
            process: targetExecutable,
            messageContains: marker,
            duration: min(logWindow, LogFilter.durationRange.upperBound),
            maxEntries: 20,
        )
    }
}

public enum EvidenceStatus: String, Codable, Sendable {
    /// This evidence says the tweak is loaded (or, for the filter, selects
    /// the target).
    case confirmed
    /// It was looked for and is not there.
    case absent
    /// It could not be looked for: the log read failed, the filter plist is
    /// missing or unreadable, or the filter cannot be decided without looking
    /// inside the process.
    case unavailable
    /// It is deliberately never looked for: the target's image list.
    case notRead
}

public struct MarkerEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

/// Always `notRead`: kept so a caller still sees the three answers apart.
public struct ImageEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

public struct FilterEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
}

/// What the check saw of the target process, by name and pid alone:
/// `confirmed` when it ran while the check looked, `absent` when it was
/// never seen, `unavailable` when the process list could not be read.
public struct ProcessEvidence: Codable, Hashable, Sendable {
    public var status: EvidenceStatus
    public var detail: String
    /// The target's pids when the check began.
    public var runningAtStart: [Int32]
    /// The target's pids that appeared after that, in the order seen.
    public var startedDuring: [Int32]
    /// From the first look to the end of the check, in seconds.
    public var watchedSeconds: TimeInterval
}

/// The answers, kept apart: none of them alone is proof, and a caller
/// shows each with its own reason.
public struct LoadConfirmation: Codable, Hashable, Sendable {
    public var marker: MarkerEvidence
    public var image: ImageEvidence
    public var filter: FilterEvidence
    /// Nil when the check was given no process list to look at.
    public var process: ProcessEvidence?
    /// The trigger threw: the respring or relaunch may not have happened.
    public var triggerFailure: String?

    /// Loaded if the process says so itself, by its marker line. The filter
    /// only explains a miss.
    public var isLoaded: Bool {
        marker.status == .confirmed
    }
}

/// The marker, the filter and the target process. The target's image list
/// is never read: on the iOS 27.0.1 vphone (roothide), reading SpringBoard's
/// image list from apelin-diagnostics panicked the kernel ("VM entry … lock
/// is invalid", vm_entry_lock.c:168) on 2026-10-17: twice while the
/// task-port read of dyld's image infos was in place, then once more through
/// the kernel's region paths (`proc_pidinfo PROC_PIDREGIONPATHINFO`) alone.
/// Both readers are gone. The process list names each process by its pid,
/// name and executable path, and nothing inside one is read.
/// Documents/Research/Device-Validation.md has the record.
public struct ConfirmLoaded: Sendable {
    private let logs: any LiveLogSource
    private let processes: (any ProcessListSource)?
    private let lookInterval: TimeInterval

    /// What `run` reports as it goes, so a caller can record where it was if
    /// the device goes down under it.
    public enum Stage: String, Sendable {
        /// The marker read has started.
        case listening
        /// The trigger is about to run.
        case trigger
    }

    /// How often the process list is looked at while a check listens.
    public static let defaultLookInterval: TimeInterval = 1

    /// `processes`, when given, is looked at when a check begins and every
    /// `lookInterval` until it ends.
    public init(
        logs: any LiveLogSource,
        processes: (any ProcessListSource)? = nil,
        lookInterval: TimeInterval = defaultLookInterval,
    ) {
        self.logs = logs
        self.processes = processes
        self.lookInterval = lookInterval
    }

    /// Looks at the process list, listens for the marker while `trigger` (a
    /// respring, a relaunch) runs, looking again every `lookInterval`, then
    /// checks the filter. The listen ends when the target logs the marker,
    /// when the window ends or when `stop` is told to, and a check stopped
    /// before its trigger does not run it. With no trigger, the marker must
    /// be logged inside the window by something the caller set going: the
    /// live log has no history.
    public func run(
        _ request: LoadConfirmationRequest,
        trigger: (@Sendable () throws -> Void)? = nil,
        stage: (@Sendable (Stage) -> Void)? = nil,
        stop: LoadCheckStop? = nil,
    ) -> LoadConfirmation {
        let filter = Self.evaluateFilter(request)
        var watch = processes.map {
            ProcessWatch(source: $0, target: request.targetExecutable, interval: lookInterval)
        }

        let markerFilter = request.markerFilter
        let heard = Heard()
        let deadline = Date().addingTimeInterval(request.logWindow)
        stage?(.listening)
        // `listen` returns once the stream has been open for its first
        // second, so it is listening before the event it waits for.
        let listening = Result {
            try logs.listen(markerFilter, until: deadline) { entry in
                // The source may filter more loosely than the request.
                guard markerFilter.matches(entry) else { return true }
                heard.append(entry)
                return false
            }
        }
        if case let .success(listener) = listening {
            stop?.watch(listener)
        }
        var triggerError: Error?
        if trigger != nil, stop?.isStopped != true {
            stage?(.trigger)
            triggerError = Self.runTrigger(trigger)
        }
        let ended: Result<Bool, Error> = switch listening {
        case let .success(listener):
            Result {
                while !listener.isFinished, Date() < deadline {
                    listener.settle(until: min(deadline, Date().addingTimeInterval(lookInterval)))
                    if !listener.isFinished {
                        watch?.look()
                    }
                }
                return try listener.wait()
            }
        case let .failure(error):
            .failure(error)
        }
        let entries = heard.entries
        // A pid that logged the marker ran, whether or not a look saw it.
        watch?.saw(entries.map(\.pid))

        return LoadConfirmation(
            marker: Self.evaluateMarker(heard: entries, ended: ended, request: request),
            image: Self.imageNotRead,
            filter: filter,
            process: watch?.evidence(),
            triggerFailure: triggerError.map { "\($0)" },
        )
    }

    private static func runTrigger(_ trigger: (@Sendable () throws -> Void)?) -> Error? {
        do {
            try trigger?()
            return nil
        } catch {
            return error
        }
    }

    /// The marker lines heard, handed over from the stream's thread.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [LogEntry] = []

        func append(_ entry: LogEntry) {
            lock.lock()
            stored.append(entry)
            lock.unlock()
        }

        var entries: [LogEntry] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: Pure evaluation, one per evidence

    /// The image evidence, always. It names no iOS version: it holds on
    /// every one, and an agent on iOS 17 read "the iOS 27 kernel" as a
    /// rule for another system.
    public static let imageNotRead = ImageEvidence(
        status: .notRead,
        detail: "The target's image list is never read, on any iOS version: reading it panicked the kernel on a test device.",
    )

    /// `heard` is what the listen delivered, `ended` how it ended: whether
    /// the source lost lines (the system ended its stream before the window
    /// did), or the read that failed. A marker heard counts however the
    /// listen ended; a miss counts only from a listen that ran whole.
    public static func evaluateMarker(
        heard: [LogEntry],
        ended: Result<Bool, Error>,
        request: LoadConfirmationRequest,
    ) -> MarkerEvidence {
        // The source may filter more loosely than the request; this is the
        // check that counts.
        let hits = heard.filter(request.markerFilter.matches)
        if !hits.isEmpty {
            let pids = Set(hits.map(\.pid)).sorted().map(String.init).joined(separator: ", ")
            return MarkerEvidence(status: .confirmed, detail: "Marker logged by pid \(pids).")
        }
        switch ended {
        case let .failure(error):
            return MarkerEvidence(status: .unavailable, detail: "The log read failed: \(error.localizedDescription)")
        case .success(true):
            return MarkerEvidence(
                status: .unavailable,
                detail: "The system ended the log stream before the window did, and no line containing \"\(request.marker)\" from \(request.targetExecutable) was heard while it ran.",
            )
        case .success(false):
            return MarkerEvidence(
                status: .absent,
                detail: "No line containing \"\(request.marker)\" from \(request.targetExecutable) in \(Int(request.logWindow)) s.",
            )
        }
    }

    public static func evaluateFilter(_ request: LoadConfirmationRequest) -> FilterEvidence {
        guard let data = request.filterPlist else {
            return FilterEvidence(status: .unavailable, detail: "No filter plist was given.")
        }
        let filter: InjectionFilter
        do {
            filter = try InjectionFilter(data: data)
        } catch {
            return FilterEvidence(status: .unavailable, detail: "The filter plist could not be read: \(error).")
        }
        let match = filter.evaluate(for: FilterTarget(
            bundleIdentifier: request.targetBundleIdentifier,
            executableName: request.targetExecutable,
            coreFoundationVersion: request.coreFoundationVersion,
        ))
        let status: EvidenceStatus = switch match.verdict {
        case .matches: .confirmed
        case .doesNotMatch: .absent
        case .undetermined: .unavailable
        }
        return FilterEvidence(status: status, detail: match.notes.joined(separator: " "))
    }
}
