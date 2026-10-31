import ApelinCore
import ApelinProtocol
import Foundation

/// An environment task as the progress page shows it, folded from its
/// events in order: the stage, how far it is and, while it downloads, how
/// fast; then how it ended. Replaying a task from its first event lands on
/// the same state as having watched it, so a page opened late, or again
/// after the app came back, starts from the beginning of the log.
struct EnvironmentTaskProgress {
    /// Which task this is, for the stages it goes through and its words.
    enum Work: Equatable {
        case toolchainSetup
        case toolchainRemoval
        /// Self-Tests ▸ Run Again.
        case toolchainSelfTest
        case sdkImport
        /// Writing a transfer file (`.apetc`, `.apesdk`, `.apeproj`).
        case transferExport
        /// Reading one and bringing in what it holds.
        case transferImport(TransferKind)
        /// The package repository: made on GitHub, linked, published to.
        case distributionCreate
        case distributionLink
        case distributionPublish
        /// Open in Apelin for a repository: `gitCloneInto` into the
        /// workspace made for it.
        case repositoryImport

        var includesDownload: Bool {
            switch self {
            case .toolchainSetup, .sdkImport, .transferImport(.toolchain), .distributionLink, .distributionPublish,
                 .repositoryImport: true
            default: false
            }
        }

        /// In the order the worker goes through them (`ToolchainStage`,
        /// `SDKManager`). An SDK import skips what its source does not
        /// need: a folder is not fetched, a repository not extracted.
        var stages: [String] {
            switch self {
            case .toolchainSetup:
                ["downloading", "extracting", "adapting", "packaging", "installing", "validating"]
            case .toolchainRemoval:
                ["removing"]
            case .toolchainSelfTest:
                ["validating"]
            case .sdkImport:
                ["fetching", "extracting", "inspecting", "registering"]
            case .transferExport:
                ["collecting", "hashing", "packing", "verifying"]
            case .transferImport(.toolchain):
                ["reading", "packaging", "installing", "validating"]
            case .transferImport(.sdk):
                ["reading", "inspecting", "registering"]
            case .transferImport(.project):
                ["reading", "placing"]
            case .distributionCreate:
                ["creating", "preparing", "pushing", "publishing"]
            case .distributionLink:
                ["fetching", "preparing", "pushing", "publishing"]
            case .distributionPublish:
                ["fetching", "preparing", "pushing"]
            case .repositoryImport:
                ["fetching"]
            }
        }
    }

    /// How far a stage is, for its row in the list.
    enum StageState: Equatable {
        case pending
        /// Its share done, or nil while that is not known.
        case running(Double?)
        case done
        /// Gone past without running: what this source did not need.
        case skipped
        case failed
    }

    /// A toolchain task listed as running says only that it is one: it is
    /// taken for a setup until its first stage says it is a removal.
    private(set) var work: Work

    private(set) var stage: String?
    /// SDK import phases count bytes while fetching and files while checking.
    private(set) var phase: String?
    /// Bytes for a download or an extraction, files for an inspection.
    private(set) var completed: Int64 = 0
    private(set) var total: Int64?
    private(set) var detail: String?
    private(set) var bytesPerSecond: Double?
    private(set) var downloadedBytes: Int64?
    private(set) var downloadTotalBytes: Int64?
    private(set) var state: TaskState = .running
    /// Why it failed, as the worker put it.
    private(set) var message: String?
    private(set) var warnings: [String] = []
    private var reached: Set<String> = []

    /// A download's last few seconds, for its speed.
    private var samples: [(time: Date, bytes: Int64)] = []
    private static let speedWindow: TimeInterval = 3

    init(work: Work) {
        self.work = work
    }

    /// 0…1 while the stage knows how much there is, else nil.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    var isFinished: Bool {
        state.isTerminal
    }

    var stages: [String] {
        switch work {
        case .toolchainSetup: ["sdk"] + work.stages
        // a toolchain brought in a file fetches its self-test's SDK after reading it
        case .transferImport(.toolchain): ["reading", "sdk"] + work.stages.dropFirst()
        default: work.stages
        }
    }

    /// Keep skipped steps in place so progress never rearranges the list.
    var shownStages: [String] {
        stages
    }

    var isDownloading: Bool {
        stage == "downloading" || stage == "fetching" || stage == "sdk" && phase == "fetching"
    }

    /// Whether `completed` and `total` are bytes.
    var countsBytes: Bool {
        guard let stage else { return false }
        return ["downloading", "fetching", "extracting", "reading", "hashing", "packing", "verifying"]
            .contains(stage == "sdk" ? phase ?? "" : stage)
    }

    func state(of stage: String) -> StageState {
        if stage == self.stage {
            if state == .succeeded {
                return .done
            }
            return state.isTerminal ? .failed : .running(fraction)
        }
        let stages = stages
        guard let index = stages.firstIndex(of: stage) else { return .pending }
        let current = self.stage.flatMap(stages.firstIndex(of:)) ?? -1
        if index < current || state == .succeeded {
            return reached.contains(stage) ? .done : .skipped
        }
        return .pending
    }

    mutating func apply(_ event: TaskEvent) {
        let payload = event.payload
        switch event.kind {
        case "stage":
            if let name = payload?["stage"]?.stringValue {
                enter(name)
            }
        case "progress":
            if let name = payload?["stage"]?.stringValue, name != stage {
                enter(name)
            }
            let phase = payload?["phase"]?.stringValue
            if phase != self.phase {
                self.phase = phase
                samples.removeAll()
                bytesPerSecond = nil
            }
            completed = Int64(payload?["completed"]?.doubleValue ?? 0)
            total = payload?["total"]?.doubleValue.map { Int64($0) }
            detail = payload?["detail"]?.stringValue
            sample(at: event.time)
            if isDownloading {
                downloadedBytes = completed
                downloadTotalBytes = total
            }
        case "warning":
            if let message = payload?["message"]?.stringValue {
                warnings.append(message)
            }
        case TaskEvent.stateKind:
            if let name = payload?["state"]?.stringValue, let value = TaskState(rawValue: name) {
                state = value
            }
            message = payload?["message"]?.stringValue
            if state.isTerminal {
                bytesPerSecond = nil
            }
        default:
            // `resumed`, `artifact`, `result` and the install task's
            // `install.*` say nothing the stage does not
            break
        }
    }

    /// The task could not be read at all: gone from the host, or refused.
    mutating func lost(_ reason: String) {
        state = .failed
        message = reason
        bytesPerSecond = nil
    }

    private mutating func enter(_ name: String) {
        // `ready` is the toolchain's last word, not a stage of its own
        guard name != "ready" else { return }
        if work == .toolchainSetup, name == "removing" {
            work = .toolchainRemoval
        }
        stage = name
        phase = nil
        reached.insert(name)
        completed = 0
        total = nil
        detail = nil
        bytesPerSecond = nil
        samples.removeAll()
    }

    /// Bytes over the last few seconds, by the times the worker stamped on
    /// its events, so a replayed download shows the speed it had then.
    private mutating func sample(at time: Date) {
        guard stage == "downloading" || stage == "fetching" || stage == "sdk" && phase == "fetching" else { return }
        if let last = samples.last, completed < last.bytes {
            // a download that started over
            samples.removeAll()
        }
        samples.append((time, completed))
        samples.removeAll { time.timeIntervalSince($0.time) > Self.speedWindow }
        guard let first = samples.first else { return }
        let elapsed = time.timeIntervalSince(first.time)
        guard elapsed >= 0.5 else { return }
        bytesPerSecond = Double(completed - first.bytes) / elapsed
    }
}

extension EnvironmentTaskProgress {
    /// A stage's name in the reader's language, as a step in the list.
    /// Each stage has words of its own: building the toolchain's package is
    /// not writing a transfer file, and checking an SDK is not reading one.
    static func title(of stage: String) -> String {
        switch stage {
        case "sdk": String(localized: "Getting SDK")
        case "downloading", "fetching": String(localized: "Downloading")
        case "extracting": String(localized: "Extracting")
        case "adapting": String(localized: "Adapting for iOS")
        case "packaging": String(localized: "Building Package")
        case "installing": String(localized: "Installing")
        case "validating": String(localized: "Running Self-Tests")
        case "removing": String(localized: "Removing")
        case "inspecting": String(localized: "Checking SDK")
        case "registering": String(localized: "Registering")
        case "collecting": String(localized: "Collecting Files")
        case "hashing": String(localized: "Checking Files")
        case "packing": String(localized: "Writing File")
        case "verifying": String(localized: "Checking File")
        case "reading": String(localized: "Reading File")
        case "placing": String(localized: "Adding Project")
        case "creating": String(localized: "Creating Repository")
        case "preparing": String(localized: "Adding Files")
        case "pushing": String(localized: "Pushing")
        case "publishing": String(localized: "Turning On GitHub Pages")
        default: stage.capitalized
        }
    }

    /// The same words while the stage is under way: "Downloading…".
    static func activeTitle(of stage: String) -> String {
        String(localized: "\(title(of: stage))…")
    }

    /// Keep transport wrappers in the full log, not in the user's explanation.
    static func readableDetail(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while !text.isEmpty {
            if let colon = text.firstIndex(of: ":"),
               ApelinError.Code(rawValue: String(text[..<colon])) != nil
            {
                text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let prefix = ["install bridge:", "[!!]"].first(where: { text.hasPrefix($0) }) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                break
            }
        }
        if text.contains("Unknown statoverride account") {
            return String(localized: "Installation stopped because a package permission record refers to an unknown user or group.")
        }
        guard let first = text.first else { return String(localized: "Something went wrong. Try again.") }
        let productNames = ["iOS", "iPadOS", "macOS", "tvOS", "watchOS", "visionOS", "iPhone", "iPad"]
        if productNames.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) {
            return text
        }
        return first.isLowercase ? first.uppercased() + text.dropFirst() : text
    }

    /// Why the task did not succeed, in the worker's words when it gave
    /// some, else what its state means; never the state's raw name.
    var outcomeMessage: String {
        if let message, !message.isEmpty {
            return message
        }
        switch state {
        case .cancelled: return String(localized: "The task was cancelled.")
        case .interrupted: return String(localized: "The task was interrupted. Try again.")
        default: return String(localized: "Something went wrong. Try again.")
        }
    }
}
