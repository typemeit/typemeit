import Foundation

/// A meeting's folder name: pure, tested (docs/meetings.md 7.9). The file
/// operations that move a meeting between staging and the published folder
/// are added alongside this later.
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
