import OSLog

enum Log {
    static let subsystem = "it.typeme.typemeit"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let transcriber = Logger(subsystem: subsystem, category: "transcriber")
    static let postProcess = Logger(subsystem: subsystem, category: "postprocess")
    static let output = Logger(subsystem: subsystem, category: "output")
    static let learning = Logger(subsystem: subsystem, category: "learning")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let model = Logger(subsystem: subsystem, category: "model")
    static let updates = Logger(subsystem: subsystem, category: "updates")
    static let screenContext = Logger(subsystem: subsystem, category: "screencontext")

    /// Lines the unified log keeps, written only while the "debug logs"
    /// setting is on. They name the app pasted into, what the clipboard
    /// held and the start of the transcript, unredacted, which is why they
    /// are opt-in. Read them back with
    /// `log show --predicate 'subsystem == "it.typeme.typemeit" AND category == "debug"'`.
    private static let debugLogger = Logger(subsystem: subsystem, category: "debug")

    @MainActor
    static func debug(_ line: @autoclosure () -> String) {
        guard Settings.shared.debugLogs else { return }
        let text = line()
        debugLogger.notice("\(text, privacy: .public)")
    }

    /// The first `limit` characters of `text` on one line, for a log line
    /// that identifies a dictation without carrying all of it.
    static func excerpt(_ text: String, limit: Int = 40) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }
}
