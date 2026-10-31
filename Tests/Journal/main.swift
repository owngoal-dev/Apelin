import Foundation

// Settings ▸ Logs lists Dog's journals: regular `Dog_` … `.log` files only,
// newest launch first, undated names last, nothing followed through a link.

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-journal-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }

func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(name))
}

try write("Dog_2026-10-20_10-00-00_AAAAAAAA.log", "a")
try write("Dog_2026-10-22_09-30-00_BBBBBBBB.log", "bbb")
try write("Dog_2026-10-21_23-59-59_CCCCCCCC.log", "cc")
try write("Dog_undated.log", "dddd")
try write("notes.txt", "not a journal")
try write("Dog_2026-10-23_00-00-00_DDDDDDDD.txt", "not a journal either")
try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("Dog_2026-10-24_00-00-00_EEEEEEEE.log"),
    withDestinationURL: directory.appendingPathComponent("Dog_2026-10-20_10-00-00_AAAAAAAA.log"),
)
try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("Dog_2026-10-25_00-00-00_FFFFFFFF.log"),
    withIntermediateDirectories: false,
)

let files = JournalFiles.list(in: directory)
require(
    files.map(\.name) == [
        "Dog_2026-10-22_09-30-00_BBBBBBBB.log",
        "Dog_2026-10-21_23-59-59_CCCCCCCC.log",
        "Dog_2026-10-20_10-00-00_AAAAAAAA.log",
        "Dog_undated.log",
    ],
    "newest launch first, undated last, only regular Dog_….log files: \(files.map(\.name))",
)
require(files.map(\.size) == [3, 2, 1, 4], "each file's size")
let newest = Calendar(identifier: .gregorian).dateComponents(
    [.year, .month, .day, .hour, .minute, .second],
    from: files[0].started ?? .distantPast,
)
require(
    (newest.year, newest.month, newest.day, newest.hour, newest.minute, newest.second) == (2026, 10, 22, 9, 30, 0),
    "the launch is read off the name, in local time",
)
require(files[3].started == nil, "a name Dog did not date has no launch")
require(JournalFiles.started(fromName: "Dog_2026-13-40_99-99-99_AAAAAAAA.log") == nil, "an impossible date reads as none")
require(JournalFiles.list(in: directory.appendingPathComponent("missing")).isEmpty, "a missing folder lists nothing")
print("ok: the journal list (Dog's files only, newest launch first, links not followed)")

// The conversations' journals the agent writes in `Journal/Agent/`: named
// for a session, written last first, each with the file it rotated out.

let agent = directory.appendingPathComponent("Agent", isDirectory: true)
try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: false)
let older = "0B1A2C3D-0000-4000-8000-000000000001"
let newer = "0B1A2C3D-0000-4000-8000-000000000002"
try Data("old".utf8).write(to: agent.appendingPathComponent(older + ".log"))
try Data("rotated".utf8).write(to: agent.appendingPathComponent(newer + ".old.log"))
try Data("new".utf8).write(to: agent.appendingPathComponent(newer + ".log"))
try Data("not a session".utf8).write(to: agent.appendingPathComponent("notes.log"))
try FileManager.default.createSymbolicLink(
    at: agent.appendingPathComponent("0B1A2C3D-0000-4000-8000-000000000003.log"),
    withDestinationURL: agent.appendingPathComponent(older + ".log"),
)
try FileManager.default.setAttributes(
    [.modificationDate: Date(timeIntervalSinceNow: -3600)],
    ofItemAtPath: agent.appendingPathComponent(older + ".log").path,
)
let conversations = JournalFiles.conversations(in: agent)
require(
    conversations.map(\.sessionID) == [newer, older],
    "sessions' regular files only, written last first: \(conversations.map(\.name))",
)
require(conversations[0].previous?.lastPathComponent == newer + ".old.log", "the rotated file goes with its journal")
require(conversations[1].previous == nil, "a journal that never rotated has none")
require(conversations[0].shareName == "apelin-agent-\(newer).log", "a conversation's journal is shared under its session")
require(files[0].shareName == "apelin-2026-10-22_09-30-00_BBBBBBBB.log", "a launch's under its launch")
print("ok: the conversations' journals (sessions only, written last first, rotated file attached)")

// What the agent writes is what the log page reads: Dog's lines, a message
// on one line whatever it held, the category with each change.

let session = DiagnosticJournal(folder: agent, name: "0B1A2C3D-0000-4000-8000-000000000004")
session.write("Session", "Opened session=4", level: .info)
session.write("Tool", "Started call=call_1 tool=shell_run session=4 at=10:00:00.000 arguments={}", level: .info)
session.write(
    "Tool",
    "Ended call=call_1 status=failed result=line one\n[Fake]\n* |critical| 2026-01-01_00-00-00| fake",
    level: .warning,
)
session.write("Compaction", "Failed trigger=requested status=400", level: .error)
let entries = JournalLines.parse(session.contents())
require(entries.count == 4, "one entry a write: \(entries.map(\.message))")
require(entries.map(\.category) == ["Session", "Tool", "Tool", "Compaction"], "each entry under its category")
require(entries.map(\.level) == [.info, .info, .warning, .error], "each entry at its level")
require(
    entries[2].message == #"Ended call=call_1 status=failed result=line one\n[Fake]\n* |critical| 2026-01-01_00-00-00| fake"#,
    "a line break is written, never broken: \(entries[2].message)",
)
require(
    entries.allSatisfy { JournalFiles.started(fromName: "Dog_\($0.timestamp)_AAAAAAAA.log") != nil },
    "each entry dated as Dog dates it: \(entries.map(\.timestamp))",
)
require(entries[3].fullText.hasPrefix("[Compaction] * |error| "), "copied with its category")

/// a rotated journal reads as one, the rotated file first
let written = DiagnosticJournal(folder: agent, name: "0B1A2C3D-0000-4000-8000-000000000005", rotationBytes: 4096)
for index in 0 ..< 200 {
    written.write("Tool", "line \(index)")
}

let rotated = JournalLines.parse(written.contents())
require(rotated.allSatisfy { $0.category == "Tool" && $0.level == .info }, "every entry of a rotated journal reads")
require(rotated.last?.message == "line 199", "the newest entry last: \(rotated.suffix(3).map(\.fullText))")
let numbers = rotated.compactMap { Int($0.message.dropFirst("line ".count)) }
require(!numbers.isEmpty && numbers == Array(numbers[0] ... 199), "nothing lost between the two files: \(numbers.prefix(3))…")
print("ok: the agent's journal reads back as Dog's (one line a message, its category and level, rotation)")
