import Foundation

/// Where the app keeps its data, and the names of the files in it.
/// `typemeit-mcp` compiles this file too, so it reads the same places.
enum SupportPaths {
    /// `~/Library/Application Support/TypeMeIt`. TYPEMEIT_SUPPORT_DIR points a
    /// build at another store, so a screenshot run can show made-up history
    /// without touching the real one.
    static let directory: URL = {
        if let dir = ProcessInfo.processInfo.environment["TYPEMEIT_SUPPORT_DIR"] {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TypeMeIt", isDirectory: true)
    }()

    /// Every dictation kept, as `[HistoryEntry]`.
    static let historyFile = directory.appendingPathComponent("history.json")

    /// The published meetings, one folder each (docs/meetings.md 7.9).
    static let meetingsRoot = directory.appendingPathComponent("Meetings", isDirectory: true)

    /// The folder inside `meetingsRoot` that holds recordings not yet
    /// published; never listed as a meeting.
    static let stagingFolderName = ".in-progress"

    /// A meeting folder's record of the meeting, as `Meeting`.
    static let meetingFile = "meeting.json"

    /// A meeting folder's transcript, rendered by `TranscriptRender`.
    static let transcriptFile = "transcript.md"
}
