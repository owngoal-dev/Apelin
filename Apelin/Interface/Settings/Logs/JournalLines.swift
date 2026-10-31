import Foundation

/// A line's level as Dog writes it: Dog's own `DogLevel` raw values, which
/// the agent's journals write too (`DiagnosticJournal`).
enum JournalLevel: String, CaseIterable, Sendable {
    case verbose
    case info
    case warning
    case error
    case critical
}

/// One entry of a journal: its time, level and category, and its message
/// with any line written after it that starts no entry of its own.
struct JournalLine: Hashable, Sendable {
    let timestamp: String
    let level: JournalLevel
    let category: String
    let message: String
    let fullText: String

    func appending(_ line: String) -> JournalLine {
        JournalLine(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message + "\n" + line,
            fullText: fullText + "\n" + line,
        )
    }
}

/// Reads a journal written Dog's way — the app's own, and the agent's for
/// each conversation — into its entries.
enum JournalLines {
    static func parse(_ text: String) -> [JournalLine] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // what follows the last line's newline is no line of the last entry
        if lines.last == "" {
            lines.removeLast()
        }

        var parsedLines: [JournalLine] = []
        var currentCategory = "System"
        var building: JournalLine?

        func flush() {
            guard let logLine = building else { return }
            parsedLines.append(logLine)
            building = nil
        }

        for line in lines {
            if let category = category(line) {
                flush()
                currentCategory = category
                continue
            }
            if let logLine = entry(line, category: currentCategory) {
                flush()
                building = logLine
                continue
            }
            if let current = building {
                building = current.appending(line)
            } else if !line.isEmpty {
                building = JournalLine(
                    timestamp: "",
                    level: .info,
                    category: currentCategory,
                    message: line,
                    fullText: line,
                )
            }
        }
        flush()

        return parsedLines
    }

    /// Dog writes `[Kind]` on its own line when the tag changes.
    private static func category(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count >= 3, !line.contains("|") else {
            return nil
        }
        let name = String(line.dropFirst().dropLast())
        return name.isEmpty ? nil : name
    }

    /// Dog writes `* |level| yyyy-MM-dd_HH-mm-ss| message`.
    private static func entry(_ line: String, category: String) -> JournalLine? {
        guard line.hasPrefix("* |") else { return nil }
        let body = line.dropFirst(3)
        guard let levelSep = body.firstIndex(of: "|") else { return nil }
        let levelStr = body[..<levelSep].trimmingCharacters(in: .whitespaces)
        guard let level = JournalLevel(rawValue: levelStr) else { return nil }
        var rest = body[body.index(after: levelSep)...]
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        guard let timeSep = rest.firstIndex(of: "|") else { return nil }
        let timestamp = rest[..<timeSep].trimmingCharacters(in: .whitespaces)
        var message = rest[rest.index(after: timeSep)...]
        if message.first == " " {
            message = message.dropFirst()
        }
        return JournalLine(
            timestamp: String(timestamp),
            level: level,
            category: category,
            message: String(message),
            fullText: "[\(category)] \(line)",
        )
    }
}
