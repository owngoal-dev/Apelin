import Foundation
import notify

/// What Apelin shows on the reader's Discord profile through Menzen
/// (`MenzenStatus` in the session host). The app writes these to
/// `MenzenStatus.json` in the data folder and posts `changedNotification`;
/// the session host, which holds the Menzen client, reads them back.
public struct MenzenStatusOptions: Codable, Equatable, Sendable {
    /// The open conversation's project.
    public var showsProject = true
    /// What the agent is doing: thinking, building, waiting for approval…
    public var showsActivity = true
    /// How long the agent has been working.
    public var showsElapsedTime = true

    public static let changedNotification = "wiki.qaq.apelin.menzen-status"
    /// Far more than the three switches take.
    static let maximumBytes = 4096

    public init() {}

    /// A switch the file does not hold is on.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsProject = try values.decodeIfPresent(Bool.self, forKey: .showsProject) ?? true
        showsActivity = try values.decodeIfPresent(Bool.self, forKey: .showsActivity) ?? true
        showsElapsedTime = try values.decodeIfPresent(Bool.self, forKey: .showsElapsedTime) ?? true
    }

    /// The saved options, or every one on when there are none. Opened
    /// without following a link and bounded: the session host reads what
    /// mobile wrote.
    public static func read(from folder: DataFolder) -> MenzenStatusOptions {
        let descriptor = open(folder.menzenStatus.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return MenzenStatusOptions() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size <= maximumBytes,
              let data = try? handle.readToEnd(),
              // persisted-read: nothing is written back from here.
              let options = try? JSONDecoder().decode(MenzenStatusOptions.self, from: data)
        else { return MenzenStatusOptions() }
        return options
    }

    /// Saves the options as the app's user and tells the session host. A
    /// file there that does not read is set aside first, never written over.
    public func write(to folder: DataFolder) throws {
        let url = folder.menzenStatus
        if FileManager.default.fileExists(atPath: url.path),
           (try? JSONDecoder().decode(MenzenStatusOptions.self, from: Data(contentsOf: url))) == nil
        {
            UnreadableFile.setAside(url)
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        notify_post(Self.changedNotification)
    }
}
