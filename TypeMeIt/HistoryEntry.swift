import Foundation

/// One dictation as `history.json` keeps it. `typemeit-mcp` compiles this
/// file too, so it reads the entries `Store` writes.
struct HistoryEntry: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var starred: Bool = false
    /// Engine output after local cleanup (custom words, fillers, normalisation).
    var transcript: String
    /// Apple Intelligence output; nil when off, skipped, rejected or failed.
    var postProcessed: String?
    var postProcessRequested: Bool
    /// What was typed into the app: the transcript, or Apple Intelligence's
    /// output, after the local clean-up and the writing styles. nil on
    /// entries from before it was kept, which showed `postProcessed`.
    var typed: String?
    var edited: String?
    var editedAt: Date?
    var durationMs: Int?
    /// Wall-clock time the speech engine took, in milliseconds.
    var transcribeMs: Int?
    /// Wall-clock time Apple Intelligence took, in milliseconds; nil when it was not requested.
    var postProcessMs: Int?
    var appId: String?
    var appName: String?
    var windowTitle: String?
    var dictionaryFixes: Int
    /// File name in `RecordingArchive.directory`; nil when audio was not kept.
    var recordingFile: String?
    /// A dictation that asked Claude by name ("TMI, …?"), so nothing was
    /// typed: the request, and Claude's answer or what the user did instead.
    var question: Meeting.Question?

    var displayText: String { edited ?? typed ?? postProcessed ?? transcript }
}
