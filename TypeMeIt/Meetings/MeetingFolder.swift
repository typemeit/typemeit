import AppKit
import AVFoundation
import Foundation

/// A meeting's folder: its name, pure and tested, and the file operations
/// that move one between staging and the published folder (docs/meetings.md 7.9).
enum MeetingFolder {
    // MARK: Naming

    /// `yyyy-MM-dd HHmm`; a fixed length so `titlePart(of:)` can find where
    /// the title starts.
    static let timeFormat = "yyyy-MM-dd HHmm"

    private static func timeFormatter(zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = timeFormat
        return formatter
    }

    /// `8m`, `45m`, `1h20m`, rounded to the nearest minute; a duration under
    /// a minute is `0m`.
    static func durationLabel(_ duration: Duration) -> String {
        let seconds = duration.timeInterval
        guard seconds >= 60 else { return "0m" }
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        guard hours > 0 else { return "\(minutes)m" }
        return "\(hours)h\(minutes)m"
    }

    /// Replaces `/` and `:` with `-`, drops non-whitespace control
    /// characters, collapses whitespace (newlines included) to one space,
    /// trims, strips leading dots and precomposes to NFC. `#` stays.
    static func sanitised(_ title: String) -> String {
        var slashesReplaced = title.replacingOccurrences(of: "/", with: "-")
        slashesReplaced = slashesReplaced.replacingOccurrences(of: ":", with: "-")

        var collapsed = ""
        var lastWasSpace = true // trims the leading edge for free
        for scalar in slashesReplaced.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasSpace {
                    collapsed.append(" ")
                    lastWasSpace = true
                }
                continue
            }
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            collapsed.unicodeScalars.append(scalar)
            lastWasSpace = false
        }
        if collapsed.hasSuffix(" ") { collapsed.removeLast() }

        while collapsed.hasPrefix(".") { collapsed.removeFirst() }
        while collapsed.hasPrefix(" ") { collapsed.removeFirst() }

        return collapsed.precomposedStringWithCanonicalMapping
    }

    /// Cuts `string` to at most `maxBytes` UTF-8 bytes on a `Character`
    /// boundary, then trims trailing whitespace.
    private static func byteCapped(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard string.utf8.count > maxBytes else { return string }
        var result = ""
        var bytes = 0
        for character in string {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= maxBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Whether `token` is a duration label this module could have produced:
    /// `(\d+h)?\d+m`.
    private static func isDurationLabel(_ token: String) -> Bool {
        var chars = Substring(token)
        func digits() -> Bool {
            let before = chars.count
            while let first = chars.first, first.isASCII, first.isNumber { chars.removeFirst() }
            return chars.count < before
        }
        guard digits() else { return false }
        if chars.first == "h" {
            chars.removeFirst()
            guard digits() else { return false }
        }
        guard chars.first == "m" else { return false }
        chars.removeFirst()
        return chars.isEmpty
    }

    /// NFC-precomposed and case-folded, so a collision check ignores case
    /// and composed-vs-decomposed accents alike.
    private static func foldedForCompare(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil)
    }

    /// Assembles `timePart [durationPart] titlePart[suffix]`, shrinking
    /// `titlePart` so the whole name (suffix included) fits
    /// `Fixed.meetingFolderNameMax` bytes.
    private static func assemble(timePart: String, durationPart: String?, titlePart: String, suffix: String) -> String {
        let prefix = [timePart, durationPart].compactMap { $0 }.joined(separator: " ") + " "
        let maxBytes = Fixed.meetingFolderNameMax
        let budget = max(0, maxBytes - prefix.utf8.count - suffix.utf8.count)
        let cappedTitle = byteCapped(titlePart, maxBytes: budget)
        var assembled = prefix + cappedTitle + suffix
        while assembled.hasSuffix(" ") { assembled.removeLast() }
        return assembled
    }

    /// A meeting folder's name: the start time in `zone`, the duration when
    /// known, then the title, unique against `existing` (the published
    /// folder's current names) by appending ` 2`, ` 3`, … .
    static func name(started: Date, zone: TimeZone, duration: Duration?, title: String, existing: [String]) -> String {
        let timePart = timeFormatter(zone: zone).string(from: started)
        let durationPart = duration.map(durationLabel)
        var titlePart = sanitised(title)
        if titlePart.isEmpty { titlePart = "meeting" }

        let existingFolded = Set(existing.map(foldedForCompare))
        var suffix = ""
        var attempt = 1
        while true {
            let candidate = assemble(timePart: timePart, durationPart: durationPart, titlePart: titlePart, suffix: suffix)
            guard existingFolded.contains(foldedForCompare(candidate)) else { return candidate }
            attempt += 1
            suffix = " \(attempt)"
        }
    }

    /// The title part of a name produced by `name(...)`, for a rename that
    /// rewrites only the title.
    static func titlePart(of name: String) -> String? {
        guard name.count > timeFormat.count else { return nil }
        let afterTime = name.index(name.startIndex, offsetBy: timeFormat.count)
        guard name[afterTime] == " " else { return nil }
        var rest = name[name.index(after: afterTime)...]
        if let spaceIndex = rest.firstIndex(of: " "), isDurationLabel(String(rest[rest.startIndex..<spaceIndex])) {
            rest = rest[rest.index(after: spaceIndex)...]
        }
        return String(rest)
    }
}

/// The file half: where meetings live, and moving, writing, transcoding and
/// recycling them (docs/meetings.md 7.9). Every path is built with
/// `appendingPathComponent`, never `URL(string:)`, so a title with `#` or
/// spaces is a plain folder name.
extension MeetingFolder {
    // MARK: Files

    static let meetingFile = "meeting.json"
    static let transcriptFile = "transcript.md"

    /// Raw tracks and the in-progress record, under Application Support and
    /// excluded from backup.
    nonisolated static var stagingRoot: URL {
        Store.directory.appendingPathComponent("Meetings", isDirectory: true).appendingPathComponent(".in-progress", isDirectory: true)
    }

    nonisolated static var defaultPublishedRoot: URL {
        Store.directory.appendingPathComponent("Meetings", isDirectory: true)
    }

    nonisolated static func staged(_ id: UUID) -> URL {
        stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Writes `meeting.json` atomically and renders `transcript.md` beside it.
    nonisolated static func write(_ meeting: Meeting, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try meeting.encoded().write(to: folder.appendingPathComponent(meetingFile), options: .atomic)
        try Data(TranscriptRender.markdown(meeting).utf8).write(to: folder.appendingPathComponent(transcriptFile), options: .atomic)
    }

    nonisolated static func read(_ folder: URL) -> Meeting? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(meetingFile)) else { return nil }
        return Meeting.decode(data)
    }

    /// Every meeting folder directly under `root`, with its meeting.
    nonisolated static func meetings(under root: URL) -> [(folder: URL, meeting: Meeting)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, let meeting = read(url) else { return nil }
            return (url, meeting)
        }
    }

    /// The names already taken under `root`, for collision handling.
    nonisolated static func existingNames(under root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
    }

    /// Moves `folder` under `root` as `name`, creating `root`. The parent of
    /// `root` must already resolve; a missing volume is the caller's cue to
    /// leave the folder staged.
    nonisolated static func move(_ folder: URL, under root: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: destination)
        return destination
    }

    nonisolated static func recycle(_ folders: [URL]) {
        guard !folders.isEmpty else { return }
        NSWorkspace.shared.recycle(folders) { _, error in
            if let error { Log.meetings.error("Could not move to the Trash: \(error.localizedDescription)") }
        }
    }

    nonisolated static func diskUsage(of root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// The folder is inside iCloud Drive's container.
    nonisolated static func isInICloudDrive(_ url: URL) -> Bool {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return url.standardizedFileURL.path.hasPrefix(cloud.standardizedFileURL.path)
    }

    /// The folder's parent resolves: not an ejected disk or an offline share.
    nonisolated static func parentResolves(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path)
    }

    /// Reads the CAF a second at a time and writes AAC at
    /// `Fixed.meetingAudioBitrate`. Returns false when the written file does
    /// not reopen with a frame count within one buffer of the source, in
    /// which case the caller keeps the CAF.
    nonisolated static func transcode(from source: URL, to destination: URL) throws -> Bool {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: Fixed.meetingAudioBitrate,
        ]
        try? FileManager.default.removeItem(at: destination)
        let frames = AVAudioFrameCount(format.sampleRate)
        do {
            let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return false }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer)
            }
        }
        // A header can claim the right length over a truncated tail, so the
        // last second has to decode too.
        let written = try AVAudioFile(forReading: destination)
        guard abs(written.length - input.length) <= AVAudioFramePosition(frames) else { return false }
        guard let tail = AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: frames) else { return false }
        written.framePosition = max(0, written.length - AVAudioFramePosition(frames))
        try written.read(into: tail, frameCount: frames)
        return tail.frameLength > 0
    }
}
