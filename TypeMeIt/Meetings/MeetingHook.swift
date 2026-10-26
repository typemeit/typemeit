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

    /// The hooks kept in `defaults`; none when there are none or they can't be read.
    static func stored(in defaults: UserDefaults) -> [MeetingHook] {
        defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode([MeetingHook].self, from: $0) } ?? []
    }

    static func store(_ hooks: [MeetingHook], in defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(hooks), forKey: defaultsKey)
    }
}
