import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Owns chat history, drafts and live sessions independently of the selected page.
@MainActor
final class ChatRuntime {
    var onChange: (() -> Void)?
    /// The saved conversations could not be read.
    var onError: ((Error) -> Void)?
    /// A conversation could not be written; it goes on in memory and is
    /// written again with the next save that gets through.
    var onSaveFailure: ((Error) -> Void)?
    /// A save got through after one had failed.
    var onSaveRecovered: (() -> Void)?
    /// A conversation's draft was put back from outside the composer.
    var onDraftRestored: ((UUID) -> Void)?
    /// Queued messages a stopped run never took went back to a
    /// conversation's composer, which the reader has yet to be told.
    var onUnsentReturned: ((UUID, DroppedMessages.Returned) -> Void)?
    /// Builds an agent ran completed, counted once each from the events a
    /// conversation had not read before (`CompletedBuilds`).
    var onBuildsCompleted: ((Int) -> Void)?
    private(set) var isLoaded = false
    /// The saved conversations have been checked against the host's live
    /// sessions once: what says working is working.
    private(set) var isReconciled = false
    private(set) var records: [UUID: ChatRecord] = [:]
    private let store = ChatStore(folder: .app)
    private var revision = 0
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var opening: [UUID: Task<AgentOpenResponse, Error>] = [:]
    private var attachmentCache: [String: ComposerAttachment] = [:]
    private var transcripts = ChatTranscriptCache()
    /// Conversations whose latest state is in memory only.
    private var unsaved: Set<UUID> = []
    /// Conversations being written, and those changed again meanwhile. A
    /// conversation is written once at a time and then once more with what
    /// it holds by then, so one that streams faster than it can be written
    /// queues no save, nor a copy of its whole history, per batch.
    private var saving: Set<UUID> = []
    private var savesPending: Set<UUID> = []
    /// Pending saves that go as soon as the write under way ends: a turn
    /// began or ended, or the reader changed something.
    private var savesUrgent: Set<UUID> = []
    /// When each conversation's last write ended. A streamed or typed
    /// change waits until `saveInterval` after it, so a long history is
    /// written at most once in that time, and a write that took longer
    /// pushes the next one back as far.
    private var savedAt: [UUID: ContinuousClock.Instant] = [:]
    /// Saves waiting for their interval, by conversation.
    private var savesDeferred: [UUID: Task<Void, Never>] = [:]
    /// Called once no conversation is being written (`saveNow`).
    private var savesDrained: [() -> Void] = []
    private static let saveInterval: Duration = .seconds(3)
    /// Who waits for a conversation's compaction to end, by conversation.
    private var compactions: [UUID: CheckedContinuation<AgentCompactionResult, Error>] = [:]

    var summaries: [ChatSummary] {
        records.values.map(\.summary)
    }

    /// The conversation the reader is looking at, nil while they look at
    /// none (`RootInterfaceController.syncViewedChat`). A reply that comes
    /// while another is looked at, or none, leaves it unread; looking at
    /// one reads it (`ChatUnread`).
    var viewedChat: UUID? {
        didSet {
            guard let viewedChat, viewedChat != oldValue, records[viewedChat]?.summary.markRead() == true else { return }
            changed(viewedChat)
        }
    }

    /// Reads every saved conversation. An untouched one left by an earlier
    /// launch is dropped, unless it is `selected`, the one to show again.
    func load(keeping selected: UUID?) async {
        do {
            for var record in try await store.load() {
                let unsent = record.sending != nil
                record.reclaimUnsent()
                records[record.summary.id] = record
                if unsent {
                    persist(record.summary.id, urgent: true)
                }
            }
            for record in records.values where isUntouched(record) && record.summary.id != selected {
                try? await removeRecord(record.summary.id)
                if record.summary.projectName == nil {
                    // the folder the menu's Open in iGhostVT or Fila made, if
                    // it was left empty; rmdir takes nothing else
                    rmdir(DataFolder.app.root.appendingPathComponent("Temporary/" + record.summary.id.uuidString).path)
                }
            }
            // a project deleted while the app was away
            await forget(DeletedProjects.gone(from: summaries, listed: DeletedProjects.listing(in: .app)))
            isLoaded = true
            onChange?()
            // A host that does not answer yet is not an error, and runs
            // nothing this app could follow: every saved row stops working.
            let live = await (try? ApelinService.app.agentList().sessions) ?? []
            for record in records.values {
                if let session = live.first(where: { $0.sessionID == record.sessionID }) {
                    records[record.summary.id]?.reopen(as: session.task)
                    follow(record.summary.id, task: session.task)
                } else if record.summary.isWorking {
                    records[record.summary.id]?.summary.isWorking = false
                    changed(record.summary.id)
                }
            }
            isReconciled = true
            onChange?()
            // What agents opened while the app was not following their
            // openers; the list is oldest first, so an opener comes first.
            for session in live {
                adopt(ChatAdoption.record(session: session, records: Array(records.values)))
            }
        } catch { onError?(error) }
    }

    /// Lists and follows a conversation an agent opened, leaving the
    /// selection where it is.
    private func adopt(_ record: ChatRecord?) {
        guard let record, let task = record.task else { return }
        records[record.summary.id] = record
        changed(record.summary.id)
        follow(record.summary.id, task: task)
    }

    /// Lists and follows a session an `apelin://` link named that had no
    /// row (`ChatLinkTarget`), and returns its row.
    func adoptLinked(_ record: ChatRecord) -> ChatSummary? {
        guard !records.values.contains(where: { $0.sessionID == record.sessionID }) else { return nil }
        adopt(record)
        return records[record.summary.id]?.summary
    }

    /// A conversation to start in `project`: its untouched one, `current`
    /// first, brought to now, or else a new one.
    func newChat(project: String?, preferring current: UUID?) -> ChatSummary {
        let untouched = records.values.filter { $0.summary.projectName == project && isUntouched($0) }
        let reused = untouched.first { $0.summary.id == current }
            ?? untouched.max { $0.summary.lastInteraction < $1.summary.lastInteraction }
        let summary = reused?.summary ?? ChatSummary.untitled(lastInteraction: Date(), projectName: project)
        if reused == nil {
            records[summary.id] = ChatRecord(summary: summary)
        }
        records[summary.id]?.summary.lastInteraction = Date()
        changed(summary.id)
        return records[summary.id]?.summary ?? summary
    }

    /// Nothing sent, typed or attached, no session opening, not pinned and
    /// not named: a row that holds nothing but its place.
    private func isUntouched(_ record: ChatRecord) -> Bool {
        record.events.isEmpty && record.sessionID == nil && record.task == nil && opening[record.summary.id] == nil
            && record.sending == nil && record.draft.text.isEmpty && record.draft.attachments.isEmpty
            && !record.summary.isPinned && record.summary.isNamedByReader != true
    }

    func saveDraft(_ draft: ComposerDraft, for id: UUID) {
        records[id]?.draft = draft
        persist(id)
    }

    func togglePin(_ id: UUID) {
        records[id]?.summary.isPinned.toggle()
        changed(id)
    }

    /// `name` as the conversation's title from now on: the agent's titles
    /// no longer replace it (`ChatSummary.rename(to:)`).
    func rename(_ id: UUID, to name: String) {
        guard records[id]?.summary.rename(to: name) == true else { return }
        changed(id)
    }

    func delete(_ id: UUID) async throws {
        let session = records[id]?.sessionID
        try await closeSession(id)
        let isTemporary = records[id].map { $0.summary.projectName == nil } ?? false
        try await removeRecord(id)
        onChange?()
        // its banners would open a conversation that is no longer there
        ConversationNotices.shared.withdraw(session: session)
        // a temporary conversation's working folder, its files with it, once
        // the row is gone: a file it cannot remove leaves the folder behind,
        // never a row Delete can no longer take away
        if isTemporary {
            let folder = DataFolder.app
            try? await Task.detached { try folder.removeTemporaryFolder(of: id) }.value
        }
    }

    func deleteProject(_ name: String) async throws {
        let ids = records.values.filter { $0.summary.projectName == name }.map(\.summary.id)
        for id in ids {
            ConversationNotices.shared.withdraw(session: records[id]?.sessionID)
            try await closeSession(id)
        }
        let folder = DataFolder.app
        try await Task.detached { try folder.removeProject(named: name) }.value
        defer { onChange?() }
        for id in ids {
            try await removeRecord(id)
        }
    }

    /// Takes away the conversations of every project whose folder has gone
    /// from `Projects/` (`DeletedProjects`), as `deleteProject` takes them
    /// once it has removed the folder itself. Answers the projects gone.
    @discardableResult
    func forgetDeletedProjects() async -> Set<String> {
        guard isLoaded else { return [] }
        let gone = DeletedProjects.gone(from: summaries, listed: DeletedProjects.listing(in: .app))
        guard !gone.conversations.isEmpty else { return [] }
        await forget(gone)
        onChange?()
        return gone.projects
    }

    /// Their banners withdrawn, any session the host left open closed —
    /// an agent's deletion closed its own, so nothing waits on the host
    /// here —, and their histories removed; a history that cannot be
    /// removed is tried again with the next change.
    private func forget(_ gone: DeletedProjects.Gone) async {
        for id in gone.conversations {
            let session = records[id]?.sessionID
            ConversationNotices.shared.withdraw(session: session)
            if let session {
                Task { try? await ApelinService.app.agentClose(sessionID: session) }
            }
            try? await removeRecord(id)
        }
    }

    private func closeSession(_ id: UUID) async throws {
        // A send may still be opening the session when Delete is tapped.
        var sessionID = records[id]?.sessionID
        if let pending = opening[id], let opened = try? await pending.value {
            sessionID = opened.sessionID
        }
        guard let sessionID else { return }
        do { try await ApelinService.app.agentClose(sessionID: sessionID) }
        catch let error as ApelinError where error.code == .notFound {
            // A finished session or one lost with the host is already closed.
        }
    }

    private func removeRecord(_ id: UUID) async throws {
        // Keep the in-memory row on disk failure, so Delete can be retried.
        try await store.remove(id)
        readers.removeValue(forKey: id)?.cancel()
        savesDeferred.removeValue(forKey: id)?.cancel()
        savedAt[id] = nil
        records.removeValue(forKey: id)
        transcripts.remove(id)
    }

    /// The conversation's rows, brought up to date only when its events, the
    /// messages it is sending, a sender's title or the turn's quiet changed
    /// (`ChatTranscriptCache`).
    func transcript(_ id: UUID) -> ChatTranscript {
        guard let record = records[id] else {
            return ChatTranscript(events: []) { _ in nil }
        }
        return transcripts.transcript(
            of: record,
            now: Date(),
            isFollowed: { readers[$0] != nil },
            conversationTitle: { title(ofSession: $0) },
        ) { [self] item in attachment(item, in: id) }
    }

    /// The title of the conversation `sessionID` is, which names a message
    /// its agent sent.
    private func title(ofSession sessionID: String) -> String? {
        records.values.first { $0.sessionID == sessionID }?.summary.displayTitle
    }

    /// A message's attachment, read from its file once and kept. One that
    /// cannot be read is tried again with the conversation's next change.
    private func attachment(_ item: AgentAttachment, in id: UUID) -> ComposerAttachment? {
        guard let path = attachmentPath(item, in: id) else { return nil }
        if let cached = attachmentCache[path] {
            return cached
        }
        guard let size = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 32 * 1024 * 1024, let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        let isText = item.mimeType.hasPrefix("text/")
            || UTType(mimeType: item.mimeType)?.conforms(to: .text) == true
        let file = ComposerAttachment(
            name: item.name,
            data: data,
            text: isText ? String(decoding: data.prefix(8192), as: UTF8.self) : nil,
            isImage: item.mimeType.hasPrefix("image/"),
        )
        attachmentCache[path] = file
        return file
    }

    /// Where a message's attachment is: by its canonical path, inside the
    /// conversation's project or temporary folder.
    private func attachmentPath(_ item: AgentAttachment, in id: UUID) -> String? {
        let root: URL = if let name = records[id]?.summary.projectName,
                           let project = DataFolder.app.project(named: name)
        {
            project
        } else {
            DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString)
        }
        let url = root.appendingPathComponent(item.path)
        guard let rootPath = CanonicalPath.resolve(root.path),
              let path = CanonicalPath.resolve(url.path), CanonicalPath.isCanonical(path, inside: rootPath)
        else { return nil }
        return path
    }

    /// Shows `draft` at once as `id`'s next message, under the draft's id,
    /// which the host's `prompt` or `queued` event echoes; that event's row
    /// takes its place. The returned task sends it: when the send fails, the
    /// message is taken out again and the draft put back in an empty
    /// composer before the task throws.
    func submit(_ draft: ComposerDraft, to id: UUID) -> Task<Void, Error> {
        guard records[id] != nil else { return Task {} }
        records[id]?.submit(draft)
        changed(id)
        return Task {
            do {
                try await send(draft, to: id)
            } catch {
                takeBack(draft, from: id)
                throw error
            }
        }
    }

    /// A send that failed: its row goes, and its draft returns to an empty
    /// composer (`ChatRecord.takeBack`).
    private func takeBack(_ draft: ComposerDraft, from id: UUID) {
        guard let restored = records[id]?.takeBack(draft) else { return }
        changed(id)
        if restored {
            onDraftRestored?(id)
        }
    }

    private func send(_ draft: ComposerDraft, to id: UUID) async throws {
        guard records[id] != nil else { return }
        let opened = try await open(id)
        guard records[id] != nil else { return }
        var descriptors: [OwnedDescriptor] = []
        var inputs: [AgentInputAttachment] = []
        // only attachments need the disk: text still goes out when it is full
        let staging = DataFolder.app.root.appendingPathComponent("Chats/Uploads/" + UUID().uuidString)
        if !draft.attachments.isEmpty {
            try DataFolder.app.makeLevels(to: staging)
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in draft.attachments {
            guard descriptors.count < 8, file.data.count <= 32 * 1024 * 1024 else {
                throw ApelinError(.badRequest, String(localized: "Send up to 8 files, each no larger than 32 MB."))
            }
            let url = staging.appendingPathComponent(file.id.uuidString)
            try file.data.write(to: url, options: .atomic)
            let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            inputs.append(AgentInputAttachment(
                descriptor: DescriptorSlot(index: descriptors.count),
                name: file.name,
                mimeType: file.isImage
                    ? imageMIME(file.data)
                    : (UTType(filenameExtension: (file.name as NSString).pathExtension)?.preferredMIMEType
                        ?? "application/octet-stream"),
            ))
            descriptors.append(OwnedDescriptor(adopting: fd))
        }
        let selection = ComposerModelSelection.current
        _ = try await ApelinService.app.send(
            AgentPromptRequest(
                sessionID: opened.sessionID,
                text: draft.text,
                messageID: draft.id,
                attachments: inputs,
                provider: selection?.provider,
                model: selection?.model,
                reasoningEffort: selection?.effort,
                serviceTier: selection?.tier,
                approvalMode: AgentPermissions.mode,
                asksBeforeScreen: AgentPermissions.asksBeforeScreen,
            ),
            descriptors: descriptors,
        )
        records[id]?.summary.nameAfterFirstMessage(text: draft.text, attachmentName: draft.attachments.first?.name)
        changed(id)
    }

    /// `ownerVerified`: the reader passed the device owner's check for this
    /// decision, which the host requires to approve a command as root.
    func approve(_ messageID: UUID, in id: UUID, decision: ApprovalDecision, ownerVerified: Bool? = nil) async throws {
        guard let sessionID = records[id]?.sessionID,
              let approvalID = transcript(id).approvalIDs[messageID]
        else { return }
        try await ApelinService.app.agentApprove(
            sessionID: sessionID,
            approvalID: approvalID,
            decision: decision,
            ownerVerified: ownerVerified,
        )
    }

    func stop(_ id: UUID) async throws {
        guard let sessionID = records[id]?.sessionID else { return }
        try await ApelinService.app.agentAbort(sessionID: sessionID)
    }

    /// Between runs only: a session to compact, nothing running, waiting
    /// for an approval or on its way to the host.
    func canCompact(_ id: UUID) -> Bool {
        guard let record = records[id] else { return false }
        return record.sessionID != nil && !record.summary.isWorking && (record.sending ?? []).isEmpty
            && opening[id] == nil && compactions[id] == nil
    }

    /// Compacts the conversation, and returns how it went once the session
    /// says so. Cancelled, it stops the compaction.
    func compact(_ id: UUID) async throws -> AgentCompactionResult {
        let opened = try await open(id)
        // what the reader takes from here on, which may answer before the request does
        let seen = records[id]?.events.count ?? 0
        try await ApelinService.app.agentCompact(sessionID: opened.sessionID)
        if let event = records[id]?.events.dropFirst(seen).last(where: { $0.kind == "compactionFinished" }) {
            return Self.compactionResult(event)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                compactions[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.endCompaction(id, with: .failure(CancellationError()))
                try? await ApelinService.app.agentAbort(sessionID: opened.sessionID)
            }
        }
    }

    private func endCompaction(_ id: UUID, with result: Result<AgentCompactionResult, Error>) {
        compactions.removeValue(forKey: id)?.resume(with: result)
    }

    private static func compactionResult(_ event: TaskEvent) -> AgentCompactionResult {
        (try? event.payload?.decode(AgentCompactionResult.self)) ?? AgentCompactionResult(outcome: .failed)
    }

    private func open(_ id: UUID) async throws -> AgentOpenResponse {
        if let pending = opening[id] {
            return try await pending.value
        }
        guard let record = records[id] else { throw CancellationError() }
        if let sessionID = record.sessionID, let task = record.task, readers[id] != nil {
            return AgentOpenResponse(sessionID: sessionID, task: task)
        }
        let selected = ComposerModelSelection.current
        let mode = AgentPermissions.mode
        let request = AgentOpenRequest(
            projectName: record.summary.projectName,
            temporaryID: record.summary.projectName == nil ? id.uuidString : nil,
            sessionID: record.sessionID,
            provider: selected?.provider,
            model: selected?.model,
            approvalMode: mode,
            asksBeforeScreen: AgentPermissions.asksBeforeScreen,
            reasoningEffort: selected?.effort,
            serviceTier: selected?.tier,
        )
        if request.temporaryID != nil {
            try DataFolder.app.makeLevels(to: DataFolder.app.root.appendingPathComponent("Temporary/" + id.uuidString))
        }
        let pending = Task { try await ApelinService.app.agentOpen(request) }
        opening[id] = pending
        defer { opening[id] = nil }
        let result = try await pending.value
        guard records[id] != nil else {
            try? await ApelinService.app.agentClose(sessionID: result.sessionID)
            throw CancellationError()
        }
        records[id]?.sessionID = result.sessionID
        records[id]?.reopen(as: result.task)
        changed(id)
        follow(id, task: result.task)
        return result
    }

    private func follow(_ id: UUID, task: TaskHandle) {
        guard readers[id] == nil else { return }
        readers[id] = Task { [weak self] in
            defer {
                self?.readers[id] = nil
                self?.endCompaction(id, with: .failure(ApelinError(
                    .notFound,
                    String(localized: "This chat is no longer running."),
                )))
            }
            while !Task.isCancelled {
                // Only the cursor: a copy of the record held over the wait
                // would make the next batch copy every event to add to them.
                guard let self, records[id]?.task == task, let cursor = records[id]?.cursor else { return }
                do {
                    let batch = try await ApelinService.app.attach(task, afterSeq: cursor)
                    guard !Task.isCancelled, records[id]?.task == task else { return }
                    let fresh = records[id]?.take(batch.events) ?? []
                    // never the replay, which `take` reads past
                    records[id]?.summary.noteReplies(in: fresh, isViewed: id == viewedChat)
                    settleSending(in: id, against: fresh)
                    let builds = CompletedBuilds.count(in: fresh)
                    if builds > 0 {
                        onBuildsCompleted?(builds)
                    }
                    for event in fresh where event.kind == AgentConversations.openedEventKind {
                        if let parent = records[id] {
                            adopt(ChatAdoption.record(
                                opened: event.payload,
                                parent: parent,
                                records: Array(records.values),
                            ))
                        }
                    }
                    let dropped = fresh.filter { $0.kind == "queueDropped" }
                        .flatMap { (try? $0.payload?["ids"]?.decode([UUID].self)) ?? [] }
                    if !dropped.isEmpty {
                        restoreDropped(Set(dropped), in: id)
                    }
                    if let title = batch.events.last(where: { $0.kind == "title" })?.payload?["text"]?.stringValue {
                        records[id]?.summary.suggestTitle(title)
                    }
                    if let proposed = batch.events
                        .last(where: { $0.kind == "projectNameSuggested" })?.payload?["name"]?.stringValue,
                       let project = records[id]?.summary.projectName,
                       let name = ProjectDisplayName.candidate(proposed)
                    {
                        Task {
                            if let response = try? await ApelinService.app.projectRename(
                                .init(projectID: project, displayName: name, onlyIfAutomatic: true),
                            ), response.changed {
                                NotificationCenter.default.post(name: .apelinProjectsChanged, object: nil)
                            }
                        }
                    }
                    if let finished = fresh.last(where: { $0.kind == "compactionFinished" }) {
                        endCompaction(id, with: .success(Self.compactionResult(finished)))
                    }
                    let wasWorking = records[id]?.summary.isWorking
                    let current = transcript(id)
                    let isWorking = current.isWorking || current.isCompacting
                    // The row's state, never its place in the sidebar: only
                    // the reader's New Chat and messages move that
                    // (`lastInteraction`), however much the agent writes.
                    records[id]?.summary.isWorking = isWorking
                    // A wait that ran out with nothing, as an idle session's
                    // does every 20 s, has nothing to write or show. A turn's
                    // start and end are written at once, what streams between
                    // them at most every `saveInterval`.
                    let turnMoved = isWorking != wasWorking
                    if !batch.events.isEmpty || turnMoved {
                        changed(id, urgent: turnMoved || batch.finished)
                    }
                    if batch.finished {
                        if let end = records[id]?.missedEnd(of: batch, isWorking: isWorking) {
                            await takeMissedEnd(at: end, of: task, from: batch, in: id)
                        }
                        return
                    }
                } catch let error as ApelinError where error.code == .notFound {
                    records[id]?.summary.isWorking = false
                    changed(id)
                    return
                } catch is CancellationError { return }
                catch {
                    // A lost connection does not discard the cursor or stop a remote turn.
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    /// The end of `task` the conversation read past (`ChatRecord.missedEnd`),
    /// read again from just before it unless `batch` carries it, and taken.
    private func takeMissedEnd(at end: EventSeq, of task: TaskHandle, from batch: TaskEventBatch, in id: UUID) async {
        var event = batch.events.last { $0.seq == end }
        if event == nil {
            event = try? await ApelinService.app.attach(task, afterSeq: EventSeq(end.rawValue - 1), waitMilliseconds: 0)
                .events.first
        }
        guard records[id]?.task == task else { return }
        records[id]?.takeMissedEnd(event, at: end)
        changed(id)
    }

    /// Sent messages whose echo arrived leave `sending`, in the same
    /// update that adds the event, so the row never blinks out or doubles.
    /// Each echoed attachment is cached as the very one the local row
    /// showed, so its preview does not fade in again.
    private func settleSending(in id: UUID, against events: [TaskEvent]) {
        guard let draftID = records[id]?.draft.id,
              let echoed = records[id]?.takeEchoed(by: events) else { return }
        for (draft, event) in echoed {
            let saved = (try? event.payload?["attachments"]?.decode([AgentAttachment].self)) ?? []
            guard saved.count == draft.attachments.count else { continue }
            for (item, local) in zip(saved, draft.attachments) {
                if let path = attachmentPath(item, in: id) {
                    attachmentCache[path] = local
                }
            }
        }
        if records[id]?.draft.id != draftID {
            onDraftRestored?(id)
        }
    }

    /// What a stopped run never took goes back to the composer, ahead of
    /// what was typed since (`DroppedMessages`).
    private func restoreDropped(_ messages: Set<UUID>, in id: UUID) {
        guard let events = records[id]?.events, let draft = records[id]?.draft,
              let returned = DroppedMessages.returning(messages, from: events, to: draft, attachment: {
                  attachment($0, in: id)
              })
        else { return }
        records[id]?.draft = returned.draft
        onDraftRestored?(id)
        onUnsentReturned?(id, returned)
    }

    /// `urgent`: written at once rather than after the interval; see `persist`.
    private func changed(_ id: UUID, urgent: Bool = true) {
        persist(id, urgent: urgent); onChange?()
    }

    /// Writes `id`, atomically and off the main thread (`ChatStore`). An
    /// `urgent` save goes now, or as soon as the write under way ends; any
    /// other waits until `saveInterval` after the last write ended.
    private func persist(_ id: UUID, urgent: Bool = false) {
        guard records[id] != nil else {
            unsaved.remove(id)
            savesDeferred.removeValue(forKey: id)?.cancel()
            return
        }
        if saving.contains(id) {
            savesPending.insert(id)
            if urgent {
                savesUrgent.insert(id)
            }
            return
        }
        let due = savedAt[id].map { $0 + Self.saveInterval } ?? .now
        if urgent || due <= .now {
            savesDeferred.removeValue(forKey: id)?.cancel()
            write(id)
        } else if savesDeferred[id] == nil {
            savesDeferred[id] = Task { [weak self] in
                try? await Task.sleep(until: due)
                guard !Task.isCancelled, let self else { return }
                savesDeferred[id] = nil
                write(id)
            }
        }
    }

    /// Writes every conversation whose save is waiting for its interval,
    /// before the app is suspended; `drained` is called once none is being
    /// written.
    func saveNow(drained: @escaping () -> Void) {
        for id in Set(savesDeferred.keys).union(savesPending) {
            persist(id, urgent: true)
        }
        savesDrained.append(drained)
        drainSaves()
    }

    private func drainSaves() {
        guard saving.isEmpty else { return }
        let drained = savesDrained
        savesDrained = []
        drained.forEach { $0() }
    }

    private func write(_ id: UUID) {
        guard let record = records[id] else {
            unsaved.remove(id)
            return
        }
        saving.insert(id)
        revision += 1
        let revision = revision
        Task { [store, weak self] in
            do {
                try await store.save(record, revision: revision)
                self?.saved(id)
            } catch {
                self?.unsaved.insert(id)
                self?.onSaveFailure?(error)
            }
            self?.saveEnded(id)
        }
    }

    /// Writes what changed while `id` was being written.
    private func saveEnded(_ id: UUID) {
        saving.remove(id)
        savedAt[id] = .now
        if savesPending.remove(id) != nil {
            persist(id, urgent: savesUrgent.remove(id) != nil)
        }
        drainSaves()
    }

    /// Writes again every conversation a failed save left in memory only.
    func retryUnsaved() {
        for id in unsaved {
            persist(id, urgent: true)
        }
    }

    private func saved(_ id: UUID) {
        guard unsaved.remove(id) != nil else { return }
        onSaveRecovered?()
        retryUnsaved()
    }

    private func imageMIME(_ data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

private extension DataFolder {
    /// Removes a temporary conversation's one real directory directly inside
    /// `Temporary/`, as `removeProject` does a project's: links inside it are
    /// removed, never followed.
    func removeTemporaryFolder(of id: UUID) throws {
        let folder = root.appendingPathComponent("Temporary/" + id.uuidString)
        var metadata = stat()
        if lstat(folder.path, &metadata) != 0 {
            if errno == ENOENT {
                return
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              let rootPath = CanonicalPath.resolve(root.path),
              CanonicalPath.resolve(folder.path) == rootPath + "/Temporary/" + id.uuidString
        else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.removeItem(at: folder)
    }
}
