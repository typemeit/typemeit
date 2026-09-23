import Foundation

/// A spoken clock time, written the way it is read: "nine AM" → 9am, "five
/// thirty p.m." → 5:30pm, "9 A.M." → 9am. Part of the ordinary clean-up
/// rather than a writing style, because nobody writes a meridiem time in
/// words. The hour is read by `Digits`, so the number words live in one
/// place, and only a phrase that is a clock time on its own is taken: "we
/// need three PMs" and "that leaves one, am I right" keep their words.
enum ClockTime {
    /// A meridiem and the words before it, up to three, since an hour can
    /// carry its minutes ("five thirty"). The words are a candidate, not a
    /// promise; which of them is the time is settled in code.
    private static let meridiem = try! NSRegularExpression(
        pattern: #"(?i)((?:[\p{L}\d:]+[ -]){0,2}[\p{L}\d:]+)[ ]?([ap])\.?[ ]?m\b(\.)?(?![\p{L}])"#)
    /// What `Digits` has to make of those words for them to be an hour.
    nonisolated(unsafe) private static let time = /^(1[0-2]|[1-9])(:[0-5]\d)?$/

    static func apply(_ text: String) -> String {
        let ns = text as NSString
        var out = text
        for m in meridiem.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let words = ns.substring(with: m.range(at: 1)).split(separator: " ").map(String.init)
            guard let (hour, spoken) = figures(before: words) else { continue }
            // The dot of "a.m." is the sentence's when a capital follows it.
            let stop = m.range(at: 3).location != NSNotFound
                && ns.substring(from: m.range.location + m.range.length).first(where: { !$0.isWhitespace })?.isUppercase == true
            let written = hour + ns.substring(with: m.range(at: 2)).lowercased() + "m" + (stop ? "." : "")
            let replacement = (words.dropLast(spoken) + [written]).joined(separator: " ")
            out = (out as NSString).replacingCharacters(in: m.range, with: replacement)
        }
        return out
    }

    /// The last words before the meridiem that are a clock time and nothing
    /// else, as figures, with how many of them it took: "by five thirty" is
    /// 5:30 from two, "work by nine" is 9 from one, "we need three" is none,
    /// since 3 is not what those words say the time is.
    private static func figures(before words: [String]) -> (String, Int)? {
        for spoken in stride(from: min(2, words.count), through: 1, by: -1) {
            let figures = Digits.apply(words.suffix(spoken).joined(separator: " "))
            if figures.wholeMatch(of: time) != nil { return (figures, spoken) }
        }
        return nil
    }
}
