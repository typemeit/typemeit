import Foundation

/// A prompt Claude Code runs on a meeting after it ends, when the user
/// presses run hooks. The app keeps the list in its UserDefaults under
/// `defaultsKey`; `typemeit-mcp` compiles this file too, and reads and writes
/// the same key.
struct MeetingHook: Codable, Identifiable, Equatable, Sendable {
    static let defaultsKey = "meetingHooks"

    var id = UUID()
    var name: String
    var prompt = ""
    /// Off, run hooks leaves it out.
    var on = true
}
