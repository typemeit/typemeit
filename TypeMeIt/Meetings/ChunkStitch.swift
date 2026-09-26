import Foundation

/// Joins a new chunk's words onto the words already accumulated for a
/// track, dropping the new chunk's echo of words the previous chunk already
/// produced in their shared overlap (docs/meetings.md 7.10). Pure.
enum ChunkStitch {
    /// Two overlap words are the same utterance when their text matches and
    /// their starts fall within this many ms of each other. This module's
    /// own tuning knob, not shared with any other constant.
    static let matchToleranceMs = 300

    /// `new` are the next chunk's words, already offset to meeting time.
    /// `tail` is every word accumulated so far. A word of `new` is a
    /// candidate for dropping only while its start still falls inside the
    /// stretch `tail` already covers (start <= tail's last word's end);
    /// later words are always kept.
    static func append(_ new: [Transcriber.Word], after tail: [Transcriber.Word], overlapMs: Int) -> [Transcriber.Word] {
        guard let lastTailEnd = tail.last?.end else { return tail + new }

        var result = tail
        for word in new {
            if word.start <= lastTailEnd, repeats(word, in: tail) {
                continue
            }
            result.append(word)
        }
        return result
    }

    private static func repeats(_ word: Transcriber.Word, in tail: [Transcriber.Word]) -> Bool {
        let text = normalized(word.text)
        return tail.contains { candidate in
            normalized(candidate.text) == text
                && abs(candidate.start.milliseconds - word.start.milliseconds) <= matchToleranceMs
        }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
