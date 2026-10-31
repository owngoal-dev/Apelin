import ApelinCore
import ApelinProtocol
import Dog
import Foundation

/// What the app's own journal says of a conversation: each problem the app
/// sees arrive — an `error` event, a compaction that failed, a Compact…
/// that could not be asked for — one line each, with the session, for
/// Settings ▸ Logs. Only events as they arrive, never a reopened session's
/// replay, which `ChatRecord.take` reads past. The agent's own journal of
/// the conversation (`Journal/Agent/<session>.log`) has the rest. Every
/// text is redacted first (`LogRedaction`).
enum ConversationJournal {
    private static let category = "Conversation"
    private static let messageBytes = 4096

    /// Notes the problems among `events`, events the conversation of
    /// `session` had not read before.
    static func note(_ events: [TaskEvent], session: String?) {
        for event in events {
            switch event.kind {
            case "error":
                let message = event.payload?["message"]?.stringValue ?? "no message"
                write("Error in session=\(session ?? "-"): \(message)", level: .error)
            case "compactionFinished":
                guard let result = try? event.payload?.decode(AgentCompactionResult.self),
                      result.outcome == .failed else { continue }
                write("Compaction failed in session=\(session ?? "-"): \(result.message ?? "no message")", level: .error)
            default:
                continue
            }
        }
    }

    /// Compact… could not be asked for, or its answer never came.
    static func compactFailed(_ error: any Error, session: String?) {
        // the code and the host's words, which an alert puts in the reader's
        let description = (error as? ApelinError)?.description ?? error.localizedDescription
        write("Compact could not run in session=\(session ?? "-"): \(description)", level: .error)
    }

    private static func write(_ message: String, level: Dog.DogLevel) {
        Dog.shared.join(category, AppJournal.redaction.text(message, limit: messageBytes), level: level)
    }
}
