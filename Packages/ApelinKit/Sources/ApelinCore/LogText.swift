import Foundation

/// A text as one line of a journal written Dog's way, where a line that
/// begins `[` is a category and one that begins `* |` an entry: every line
/// break in it — `\n`, `\r`, `\r\n`, U+2028 and the rest — is written `\n`,
/// so nothing a tool printed or an error said starts a line of its own.
/// Foundation only, so that the Mac harness compiles it beside the agent's
/// journal writer and the app's reader.
public enum LogText {
    public static func oneLine(_ text: String) -> String {
        guard text.contains(where: \.isNewline) else { return text }
        var line = ""
        line.reserveCapacity(text.utf8.count)
        for character in text {
            if character.isNewline {
                line += "\\n"
            } else {
                line.append(character)
            }
        }
        return line
    }
}
