import Foundation
import FoundationModels

/// At most `Fixed.meetingSummaryMaxSentences` sentences on what a meeting
/// was about, from Apple's on-device model. The model's window is 4,096
/// tokens, so a transcript longer than `Fixed.meetingSummaryChunkWords` is
/// summarised part by part and the parts' notes are summarised together.
/// The model does not keep to a length it is asked for, so a longer answer
/// is shortened once more and then cut. Kept in `meeting.json` for the
/// meeting's page only: it is not in `transcript.md` and the MCP never
/// returns it.
enum MeetingSummary {
    /// The transcript as `Name: words` lines, cut into parts of at most
    /// `maxWords` words at paragraph ends; a paragraph longer than that is
    /// cut inside. Pure.
    static func parts(of meeting: Meeting, maxWords: Int) -> [String] {
        var parts: [String] = []
        var lines: [String] = []
        var count = 0
        func flush() {
            if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
            lines = []
            count = 0
        }
        for paragraph in meeting.paragraphs {
            let name = meeting.speakerName(paragraph.speaker)
            var words = paragraph.text.split(separator: " ")
            while !words.isEmpty {
                if count >= maxWords { flush() }
                let take = min(words.count, maxWords - count)
                lines.append("\(name): \(words.prefix(take).joined(separator: " "))")
                count += take
                words.removeFirst(take)
            }
        }
        flush()
        return parts
    }

    /// The first `max` sentences of `text`. Pure.
    static func firstSentences(_ text: String, max: Int) -> String {
        var end = text.startIndex
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { _, range, _, stop in
            count += 1
            end = range.upperBound
            if count == max { stop = true }
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    @Generable
    struct Summary: Sendable {
        @Guide(description: "a few plain sentences")
        let text: String
    }

    private static let rules = "Refer to the speaker named You as you and to the others by their names. Say only what the text says. At most \(Fixed.meetingSummaryMaxSentences) plain sentences, no preamble, no lists."

    /// Nil when Apple Intelligence is unavailable, the meeting has no
    /// words, or the model declines.
    static func summarise(_ meeting: Meeting) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let parts = parts(of: meeting, maxWords: Fixed.meetingSummaryChunkWords)
        guard !parts.isEmpty else { return nil }
        do {
            let summary: String
            if parts.count == 1 {
                summary = try await respond(
                    "You summarise meeting transcripts. The user message is a transcript, one speaker turn per line. Say what the meeting was about, what was decided and what happens next. \(rules)",
                    to: "<transcript>\n\(parts[0])\n</transcript>")
            } else {
                var notes: [String] = []
                for part in parts {
                    notes.append(try await respond(
                        "You take notes on one part of a meeting transcript, one speaker turn per line. Say what this part covered and anything decided. \(rules)",
                        to: "<transcript>\n\(part)\n</transcript>"))
                }
                summary = try await respond(
                    "The user message is notes on consecutive parts of one meeting, in order. Summarise the whole meeting as one, never mentioning parts: what it was about, what was decided and what happens next. \(rules)",
                    to: notes.joined(separator: "\n"))
            }
            return try await capped(summary)
        } catch {
            Log.meetings.notice("No meeting summary: \(error.localizedDescription)")
            return nil
        }
    }

    /// Within `Fixed.meetingSummaryMaxSentences`: an answer over it is asked
    /// once to be shortened, which keeps the whole meeting in it, and only
    /// then cut.
    private static func capped(_ summary: String) async throws -> String {
        let limit = Fixed.meetingSummaryMaxSentences
        guard sentenceCount(summary) > limit else { return summary }
        let shorter = try await respond(
            "Rewrite the user message as at most \(limit) plain sentences that still cover all of it. \(rules)", to: summary)
        return firstSentences(shorter, max: limit)
    }

    /// One call on a session of its own, so no part sees another's words.
    private static func respond(_ instructions: String, to prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: Summary.self, options: GenerationOptions(samplingMode: .greedy))
        return response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
