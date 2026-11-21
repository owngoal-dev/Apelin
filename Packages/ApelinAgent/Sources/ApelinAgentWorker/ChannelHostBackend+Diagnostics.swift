import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation

public extension ChannelHostBackend {
    // MARK: logs and crashes

    func readLogs(_ request: ReadLogsRequest) async throws -> ReadLogsResponse {
        let limit = min(5000, max(1, request.limit))
        let filter = ApelinProtocol.LogFilter(
            subsystem: request.subsystem,
            process: request.process,
            limit: limit,
            windowSeconds: Double(min(ReadLogsRequest.maximumListenSeconds, max(1, request.listenSeconds))),
        )
        let first = try await service.logStream(LogStreamRequest(filter: filter, waitMilliseconds: 0))
        var entries: [ApelinAgent.LogEntry] = []
        var truncated = false
        func take(_ event: TaskEvent) {
            switch event.kind {
            case "log":
                guard entries.count < limit else { truncated = true; return }
                if let entry = Self.logEntry(event) {
                    entries.append(entry)
                }
            case "truncated":
                truncated = true
            default:
                break
            }
        }
        first.events.forEach(take)
        if !first.finished {
            for try await event in service.events(of: TaskHandle(taskID: first.taskID, kind: .logStream), afterSeq: first.lastSeq) {
                take(event)
            }
        }
        return ReadLogsResponse(entries: entries, truncated: truncated)
    }

    internal static func logEntry(_ event: TaskEvent) -> ApelinAgent.LogEntry? {
        guard let payload = event.payload, let message = payload["message"]?.stringValue else { return nil }
        let date = payload["time"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) } ?? event.time
        let subsystem = payload["subsystem"]?.stringValue
        return ApelinAgent.LogEntry(
            date: date,
            process: payload["process"]?.stringValue ?? "",
            subsystem: subsystem?.isEmpty == true ? nil : subsystem,
            level: payload["level"]?.stringValue ?? "default",
            message: message,
        )
    }

    func listCrashes(_ request: ListCrashesRequest) async throws -> ListCrashesResponse {
        let list = try await service.crashList(process: request.process)
        return ListCrashesResponse(reports: list.reports.prefix(max(1, request.limit)).map {
            CrashSummary(id: $0.id, process: $0.process, date: $0.date, exceptionType: $0.exceptionType)
        })
    }

    func readCrash(_ request: ReadCrashRequest) async throws -> ReadCrashResponse {
        let (response, descriptor) = try await service.crashOpen(id: request.reportID)
        guard let descriptor else { throw ApelinError(.internal, "the host returned no file for the crash report") }
        defer { descriptor.close() }
        let budget = min(max(1, request.maxBytes), 4 * 1024 * 1024)
        let data = try Self.read(descriptor.rawValue, upTo: budget)
        return ReadCrashResponse(
            reportID: request.reportID,
            text: String(decoding: data, as: UTF8.self),
            truncated: Int64(data.count) < response.size,
        )
    }

    func symbolicateCrash(_ request: SymbolicateCrashRequest) async throws -> SymbolicateCrashResponse {
        let response = try await service.crashSymbolicate(id: request.reportID, projectID: project.id)
        return SymbolicateCrashResponse(
            reportID: response.id,
            matchedImageUUID: response.matchedImageUUIDs.first,
            crashedThread: response.crashedThread.map {
                ApelinAgent.SymbolicatedFrame(
                    index: $0.index,
                    image: $0.image,
                    address: $0.address,
                    symbol: $0.symbol,
                    file: $0.file,
                    line: $0.line,
                )
            },
            suspects: response.suspects,
        )
    }

    // MARK: UI

    func captureScreen(
        _ request: ApelinAgent.CaptureScreenRequest,
    ) async throws -> ApelinAgent.CaptureScreenResponse {
        let (response, descriptor) = try await service.captureScreen(targetID: request.targetID)
        guard let descriptor else { throw ApelinError(.internal, "the host returned no file for the screenshot") }
        defer { descriptor.close() }
        let data = try Self.read(descriptor.rawValue, upTo: Self.maximumScreenshotBytes)
        return ApelinAgent.CaptureScreenResponse(
            attachmentID: UUID().uuidString.lowercased(),
            mimeType: data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg",
            width: response.width,
            height: response.height,
            imageData: data,
        )
    }

    func readUITree(_ request: ApelinAgent.ReadUITreeRequest) async throws -> ApelinAgent.ReadUITreeResponse {
        let response = try await service.readUITree(targetID: request.targetID)
        return ApelinAgent.ReadUITreeResponse(root: Self.tree(response.tree))
    }

    /// The diagnostics worker's flat element list as one root with children.
    /// An element's id is its accessibility identifier, or `text:<label>`.
    internal static func tree(_ json: ApelinCore.JSONValue) -> UIElementNode {
        var children: [UIElementNode] = []
        if case let .array(elements)? = json["elements"] {
            for (index, element) in elements.enumerated() {
                let identifier = element["identifier"]?.stringValue ?? ""
                let label = element["label"]?.stringValue ?? ""
                let frame = element["frame"]
                children.append(UIElementNode(
                    id: !identifier.isEmpty ? identifier : (!label.isEmpty ? "text:\(label)" : "index:\(index)"),
                    role: element["role"]?.stringValue ?? "",
                    label: label.isEmpty ? nil : label,
                    value: element["value"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                    frame: ["x", "y", "width", "height"].map { frame?[$0]?.doubleValue ?? 0 },
                ))
            }
        }
        let pid = json["pid"]?.doubleValue.map { Int($0) } ?? 0
        return UIElementNode(id: "screen", role: "application", label: pid > 0 ? "pid \(pid)" : nil, children: children)
    }

    func uiAction(_ request: ApelinAgent.UIActionRequest) async throws -> ApelinAgent.UIActionResponse {
        let response = try await service.uiAction(Self.action(request.action), targetID: request.targetID)
        // A wake or an unlock answers the lock state, a type what it read
        // back; no action answers both.
        let unlocked = request.action == .pressButton(DevicePasscode.unlockButton)
        let message = [
            unlocked ? Self.afterUnlock(response) : Self.afterWake(response),
            Self.readBackMessage(response),
        ].filter { !$0.isEmpty }
        return ApelinAgent.UIActionResponse(
            performed: true,
            message: message.joined(separator: " "),
            typedTextMatches: response.typedTextMatches,
            fieldValues: response.fieldValues,
        )
    }

    /// What a wake left, in words the model acts on; empty after any other
    /// action, which answers neither.
    internal static func afterWake(_ response: ApelinProtocol.UIActionResponse) -> String {
        if response.screenOff == true {
            return "The screen is still off. Press wake once more; if it stays off, ask the user to wake the device."
        }
        if response.locked == true {
            return "The screen is on, but the device is still locked: a device with a passcode stays on its lock screen after a wake. Press unlock to get past it with the passcode the user saved in Apelin's Settings; if that is refused, ask the user to unlock the device, and never ask for or type the passcode."
        }
        if response.locked == false {
            return "The screen is on and the device is unlocked."
        }
        return ""
    }

    /// What an unlock left, and the way it went, so the model reports what
    /// happened: a device without a passcode was not unlocked with one. Its
    /// refusals come back as errors that say why.
    internal static func afterUnlock(_ response: ApelinProtocol.UIActionResponse) -> String {
        if response.screenOff == true {
            return "The screen is still off. Press unlock once more; if it stays off, ask the user to wake the device."
        }
        if response.locked == true {
            return "The device's keybag is unlocked, but its lock screen is still up. Ask the user to swipe up or unlock the device, and never ask for or type the passcode."
        }
        switch response.unlockedBy {
        case .nothing?:
            return "The device was already unlocked with its screen on; nothing was pressed."
        case .wake?:
            return "The device was already unlocked; its screen was off, so it was woken."
        case .lockScreen?:
            return "No passcode was needed: the device was woken, taken past its lock screen and to the Home Screen."
        case .passcode?:
            return "The device was unlocked with the passcode saved in Apelin's Settings, taken past its lock screen and to the Home Screen."
        case nil:
            return "The device is unlocked and its screen is on."
        }
    }

    /// What to do when the text read back is not the text typed.
    internal static func readBackMessage(_ response: ApelinProtocol.UIActionResponse) -> String {
        guard response.typedTextMatches == false else { return "" }
        if response.fieldValues?.isEmpty ?? true {
            return "No field changed: the text did not go in. Tap the field to focus it, then type again."
        }
        return "The fields that changed do not hold the typed text; fieldValues is what they hold now. Correct it before going on."
    }

    internal static func action(_ action: ApelinAgent.UIAction) throws -> ApelinProtocol.UIAction {
        switch action {
        case let .tap(x, y): return .tap(x: x, y: y)
        case let .tapElement(id):
            if id.hasPrefix("text:") {
                return .tapElement(text: String(id.dropFirst(5)), identifier: nil)
            }
            if id.hasPrefix("index:") {
                throw ApelinError(
                    .badRequest,
                    "that element has no identifier or text to tap it by; tap its frame instead",
                )
            }
            return .tapElement(text: nil, identifier: id)
        case let .typeText(text): return .type(text: text)
        case let .swipe(fromX, fromY, toX, toY, durationMilliseconds):
            return .swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, durationMilliseconds: durationMilliseconds)
        case let .pressButton(button): return .press(button: button)
        }
    }
}
