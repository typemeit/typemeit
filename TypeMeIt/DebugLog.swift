import AppKit
import Foundation
import os

/// The opt-in debug log: what each dictation and paste did, in a file the
/// user can send with a bug report and delete. Nothing is written while the
/// "debug logs" setting is off. Lines carry app names and the start of
/// transcripts unredacted; the field pasted into is never written out.
enum DebugLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/TypeMeIt/debug.log")
    static let displayPath = "~/Library/Logs/TypeMeIt/debug.log"

    /// Past this the older half of the file is dropped before a write.
    static let maxBytes = 1 << 20

    /// Mirrors `Settings.debugLogs`, readable off the main actor.
    private static let enabledState = OSAllocatedUnfairLock(initialState: false)
    static var enabled: Bool {
        get { enabledState.withLock { $0 } }
        set { enabledState.withLock { $0 = newValue } }
    }

    private static let queue = DispatchQueue(label: "it.typeme.typemeit.debuglog")
    private static let stamp = Date.ISO8601FormatStyle(dateSeparator: .dash, dateTimeSeparator: .space, timeSeparator: .colon, includingFractionalSeconds: true, timeZone: .current)

    static func write(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let text = line()
        let at = Date()
        queue.async { append("\(at.formatted(stamp)) \(text)\n") }
    }

    /// The build and OS, so a sent file says what produced it. Written when
    /// the setting is turned on and at each launch while it is.
    static func writeHeader() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        write("\(Bundle.main.bundleIdentifier ?? "type me it") \(AppVersion.current) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    static func delete() {
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    static func reveal() {
        queue.sync {}  // pending lines land first
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The first `limit` characters of `text` on one line, for a line that
    /// identifies a dictation without carrying all of it.
    static func excerpt(_ text: String, limit: Int = 40) -> String {
        let oneLine = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)) + "…"
    }

    /// The last `bytes` of `data`, starting on a line boundary.
    static func trimmed(_ data: Data, to bytes: Int) -> Data {
        guard data.count > bytes else { return data }
        var tail = data.suffix(bytes)
        if let newline = tail.firstIndex(of: UInt8(ascii: "\n")) {
            tail = tail[tail.index(after: newline)...]
        }
        return Data(tail)
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                try trimmed(Data(contentsOf: url), to: maxBytes / 2).write(to: url, options: .atomic)
            }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            Log.app.error("Debug log not written: \(error.localizedDescription)")
        }
    }
}
