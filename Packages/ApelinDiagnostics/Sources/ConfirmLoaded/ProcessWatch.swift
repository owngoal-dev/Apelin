import ApelinDiagnosticsCore
import Foundation

/// The target process as a load check sees it from outside: the process
/// list looked at when the check begins and again while it listens, each
/// process known by its pid and executable name alone. It tells a target
/// that never ran, which nothing could load into, from one that ran and
/// logged no marker.
///
/// A list that cannot be read when the check begins is not read again: what
/// fails then fails every time, and the evidence says it could not look.
/// A later look that fails is skipped. A process that starts and exits
/// between two looks is not seen, unless it logged the marker (`saw`).
struct ProcessWatch {
    private let source: any ProcessListSource
    private let target: String
    private let interval: TimeInterval
    private let began = Date()
    private var failure: String?
    private var runningAtStart: [Int32] = []
    private var startedDuring: [Int32] = []

    /// Looks for the first time: what runs now is what ran when the check
    /// began.
    init(source: any ProcessListSource, target: String, interval: TimeInterval) {
        self.source = source
        self.target = target
        self.interval = interval
        do {
            runningAtStart = try Self.pids(of: target, in: source.processes())
        } catch {
            failure = (error as? DiagnosticsError)?.localizedDescription ?? "\(error)"
        }
    }

    /// Looks again; a pid not seen before started meanwhile.
    mutating func look() {
        guard failure == nil, let rows = try? source.processes() else { return }
        saw(Self.pids(of: target, in: rows))
    }

    /// Records pids of the target seen some other way: one that logged the
    /// marker ran, whether or not a look caught it.
    mutating func saw(_ pids: [Int32]) {
        guard failure == nil else { return }
        for pid in pids where !runningAtStart.contains(pid) && !startedDuring.contains(pid) {
            startedDuring.append(pid)
        }
    }

    func evidence(at end: Date = Date()) -> ProcessEvidence {
        let watched = max(0, end.timeIntervalSince(began))
        func evidence(_ status: EvidenceStatus, _ detail: String) -> ProcessEvidence {
            ProcessEvidence(
                status: status,
                detail: detail,
                runningAtStart: runningAtStart,
                startedDuring: startedDuring,
                watchedSeconds: watched,
            )
        }
        if let failure {
            return evidence(.unavailable, "The process list could not be read: \(failure)")
        }
        switch (runningAtStart.isEmpty, startedDuring.isEmpty) {
        case (false, true):
            return evidence(.confirmed, "\(target) was running when the check began (\(Self.pids(runningAtStart))).")
        case (false, false):
            return evidence(
                .confirmed,
                "\(target) was running when the check began (\(Self.pids(runningAtStart))) and started again during it (\(Self.pids(startedDuring))).",
            )
        case (true, false):
            return evidence(
                .confirmed,
                "\(target) was not running when the check began and started during it (\(Self.pids(startedDuring))).",
            )
        case (true, true):
            return evidence(
                .absent,
                "No process named \(target) ran while the check looked: none when it began, and none in \(Int(watched.rounded())) s of looks every \(String(format: "%g", interval)) s after it. A process that starts and exits between two looks without logging the marker is not seen.",
            )
        }
    }

    private static func pids(of target: String, in rows: [ProcessRow]) -> [Int32] {
        rows.filter { $0.runs(target) }.map(\.pid).sorted()
    }

    private static func pids(_ pids: [Int32]) -> String {
        (pids.count == 1 ? "pid " : "pids ") + pids.map(String.init).joined(separator: ", ")
    }
}
