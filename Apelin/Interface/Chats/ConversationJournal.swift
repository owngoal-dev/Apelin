import ApelinCore
import ApelinProtocol
import Dog
import Foundation

/// What the app's own journal says of a conversation: each problem the app
/// sees arrive — an `error` event, a compaction that failed, a Compact…
/// that could not be asked for — one line each, with the session, for
/// Settings ▸ Logs. Only events as they arrive, never a reopened session's
/// replay, which `ChatRecord.take` reads past. The agent's own journal of
/// the conversation (`Journal/Agent/<session>.log`) has the rest.
///
/// Every text is redacted (`AppJournal.redaction`) and put on one line
/// (`LogText`), so an error that holds a line break cannot write an entry
/// or a category of its own; both happen on a queue of their own, never
/// on the main thread.
enum ConversationJournal {
    private static let category = "Conversation"
    private static let messageBytes = 4096
    private static let queue = DispatchQueue(label: "wiki.qaq.apelin.conversation-journal", qos: .utility)

    /// Notes the problems among `events`, events the conversation of
    /// `session` had not read before.
    static func note(_ events: [TaskEvent], session: String?) {
        for event in events {
            switch event.kind {
            case "error":
                let message = event.payload?["message"]?.stringValue ?? "no message"
                write("Error in session=\(session ?? "-"): \(message)")
            case "compactionFinished":
                guard let result = try? event.payload?.decode(AgentCompactionResult.self),
                      result.outcome == .failed else { continue }
                write("Compaction failed in session=\(session ?? "-"): \(result.message ?? "no message")")
            default:
                continue
            }
        }
    }

    /// Compact… could not be asked for, or its answer never came.
    static func compactFailed(_ error: any Error, session: String?) {
        // the code and the host's words, which an alert puts in the reader's
        let description = (error as? ApelinError)?.description ?? error.localizedDescription
        write("Compact could not run in session=\(session ?? "-"): \(description)")
    }

    private static func write(_ message: String) {
        queue.async {
            let line = LogText.oneLine(AppJournal.redaction.text(message, limit: messageBytes))
            Dog.shared.join(category, line, level: .error)
        }
    }
}
