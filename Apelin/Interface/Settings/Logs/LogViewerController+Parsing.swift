import UIKit

extension LogViewerController {
    func logText() -> String {
        Self.text(of: file, hiding: hiddenPrefixCount)
    }

    /// The journal as text, the file it rotated out first, without its
    /// first `count` characters. A line cut short mid-character is read
    /// with a replacement character rather than losing the whole file.
    nonisolated static func text(of file: JournalFile, hiding count: Int) -> String {
        let parts = [file.previous, file.url].compactMap { url -> String? in
            guard let url, let data = try? Data(contentsOf: url) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        return String(parts.joined().dropFirst(count))
    }

    /// Bytes in the log file, without reading it.
    var fileLength: Int {
        (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? -1
    }

    func reloadIfFileGrew() {
        guard fileLength != lastReadLength else { return }
        reload(growing: true)
    }

    func reload(growing: Bool) {
        // a first parse still running would land older lines over these
        work?.cancel()
        work = nil
        lastReadLength = fileLength
        parsed = JournalLines.parse(logText())
        applyFilters(stickToBottom: isNearBottom, growing: growing)
    }
}
