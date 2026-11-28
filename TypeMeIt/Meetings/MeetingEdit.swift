import Foundation

/// A new title or summary for a meeting, asked for over MCP (`edit_meeting`,
/// docs/meetings.md 7.15). The app is the only writer of `meeting.json`: a
/// hook that runs the tool finishes by saving its own result into the
/// meeting, from the app's copy, which would undo a change written straight
/// to the file. So the server leaves each edit as a hidden file in the
/// published folder, which `MeetingStore` watches; the store applies it with
/// its own rename and deletes it. Compiled into the app and `typemeit-mcp`.
struct MeetingEdit: Codable, Equatable, Sendable {
    var meeting: UUID
    var title: String?
    var summary: String?

    /// Hidden, so neither the app's scan nor the server's lists it as a meeting.
    static let filePrefix = ".edit-"
    static let fileExtension = "json"

    /// Writes `edit` into `root` under a name that sorts by when it was
    /// written, so two edits to one meeting apply in order.
    static func write(_ edit: MeetingEdit, into root: URL, at time: Date = Date()) throws -> URL {
        let millis = Int64((time.timeIntervalSince1970 * 1000).rounded())
        let file = root.appendingPathComponent("\(filePrefix)\(millis)-\(UUID().uuidString)").appendingPathExtension(fileExtension)
        try JSONEncoder().encode(edit).write(to: file, options: .atomic)
        return file
    }

    /// Every edit waiting in `root`, oldest first. A file that does not
    /// decode comes back with a nil edit, so the caller deletes it too.
    static func pending(in root: URL) -> [(file: URL, edit: MeetingEdit?)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".\(fileExtension)") }
            .sorted()
            .map { name in
                let file = root.appendingPathComponent(name)
                return (file, (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(MeetingEdit.self, from: $0) })
            }
    }
}
