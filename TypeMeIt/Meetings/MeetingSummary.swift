import Foundation
import FoundationModels

/// At most `maxSentences` sentences on what a meeting was about, from
/// Apple's on-device model. The model's window is 4,096 tokens, so a
/// transcript longer than `chunkWords` is summarised part by part and the
/// parts' notes are summarised together. The model does not keep to a
/// length it is asked for, so the summary is two fields and anything past
/// `maxSentences` is cut. Kept in `meeting.json` for the meeting's page
/// only: it is not in `transcript.md` and the MCP never returns it. The
/// meeting's title is written from the summary. Needs nothing else from the
/// app, so Scripts/meeting-eval compiles it as it ships.
enum MeetingSummary {
    /// A summary part: about 2,000 tokens of transcript, leaving the rest of
    /// the 4,096-token window for the instructions and the answer.
    static let chunkWords = 1500
    /// The owner's limit, cut from 8 on 2026-09-29: eight sentences ran to
    /// 90–170 words, too long to read at a glance.
    static let maxSentences = 2
    /// Asked for, not enforced: `make meeting-eval` counts it. Two sentences
    /// alone came back as run-ons of up to 95 words.
    static let maxWords = 40
    /// One part's notes, which only feed the summary.
    static let noteSentences = 4
    /// Fits the 4,096-token window beside the title instructions.
    static let titleSourceWords = 700
    /// The words are taken as this many runs spread across the meeting:
    /// the opening is small talk and updates, the subject comes later.
    /// Measured on an 11-minute call: the first 700 words titled it
    /// "Weekly Update Meeting", seven runs titled it after its lesson.
    static let titleSamples = 7
    /// The title's length, as `titleRules` and `Title` ask for it.
    static let titleWords = 3...5
    /// The speaker name the app gives the person recording.
    static let you = "You"

    /// One paragraph of the transcript under its speaker's name.
    struct Turn: Decodable, Equatable, Sendable {
        let speaker: String
        let text: String
    }

    /// The transcript as `Name: words` lines, cut into parts of at most
    /// `maxWords` words at paragraph ends; a paragraph longer than that is
    /// cut inside. Pure.
    static func parts(of turns: [Turn], maxWords: Int) -> [String] {
        var parts: [String] = []
        var lines: [String] = []
        var count = 0
        func flush() {
            if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
            lines = []
            count = 0
        }
        for turn in turns {
            var words = turn.text.split(separator: " ")
            while !words.isEmpty {
                if count >= maxWords { flush() }
                let take = min(words.count, maxWords - count)
                lines.append("\(turn.speaker): \(words.prefix(take).joined(separator: " "))")
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

    /// `you` and its forms in lower case where they do not start a
    /// sentence: the model writes "Rachel proposed Your plan". Pure.
    static func lowercasedYou(_ text: String) -> String {
        var out = ""
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            let sentence = text[enclosing]
            let start = sentence.firstIndex { !$0.isWhitespace } ?? sentence.endIndex
            var cursor = sentence.startIndex
            for match in sentence.matches(of: #/\b(?:You|Your|Yours|Yourself)\b/#) where match.range.lowerBound > start {
                out += sentence[cursor..<match.range.lowerBound] + match.output.lowercased()
                cursor = match.range.upperBound
            }
            out += sentence[cursor...]
        }
        return out
    }

    static func sentenceCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }

    /// `titleSourceWords` words as `titleSamples` runs spread evenly across
    /// the transcript, joined by an ellipsis line.
    static func titleSample(of turns: [Turn]) -> String {
        let words = turns.flatMap { $0.text.split(separator: " ") }
        guard !words.isEmpty else { return "" }
        if words.count <= titleSourceWords { return words.joined(separator: " ") }
        let size = titleSourceWords / titleSamples
        return (0..<titleSamples).map { k in
            let start = k * words.count / titleSamples
            return words[start..<min(start + size, words.count)].joined(separator: " ")
        }.joined(separator: "\n…\n")
    }

    @Generable
    struct Notes: Sendable {
        @Guide(description: "a few plain sentences")
        let text: String
    }

    /// The summary as two fields. Asked for two sentences in one string, the
    /// model wrote run-ons of up to 95 words, and asked to shorten one it
    /// gave the same words back.
    @Generable
    struct Brief: Sendable {
        @Guide(description: "a short full sentence on what the meeting was about")
        let about: String
        @Guide(description: "a short full sentence on the main decision or next step")
        let outcome: String

        var text: String {
            [about, outcome]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { ".!?".contains($0.last!) ? $0 : $0 + "." }
                .joined(separator: " ")
        }
    }

    @Generable
    struct Title: Sendable {
        @Guide(description: "three to five words")
        let title: String
    }

    private static let rules = "Refer to the speaker named \(you) as you and to the others by their names. Say only what the text says. At most \(maxSentences) short plain sentences and \(maxWords) words in all, no preamble, no lists."

    private static let noteRules = "Refer to the speaker named \(you) as you and to the others by their names. Say only what the text says. At most \(noteSentences) plain sentences, no preamble, no lists."

    private static let titleRules = "Answer with a title of three to five words naming the subject the meeting was about, the way someone who was in it would refer to it afterwards. Prefer the topic over a company or product name that merely came up, and never name a person. No quotes, no trailing punctuation."

    /// Nil when Apple Intelligence is unavailable, the meeting has no
    /// words, or the model declines every part.
    static func summarise(_ turns: [Turn]) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let parts = parts(of: turns, maxWords: chunkWords)
        guard !parts.isEmpty else { return nil }
        do {
            let summary: String
            if parts.count == 1 {
                summary = try await respond(
                    as: Brief.self,
                    "You summarise meeting transcripts. The user message is a transcript, one speaker turn per line. Say what the meeting was about and what was decided or happens next. \(rules)",
                    to: "<transcript>\n\(parts[0])\n</transcript>").text
            } else {
                // A part the model still declines is left out, so one part
                // cannot cost the meeting its summary.
                var notes: [String] = []
                for part in parts {
                    do {
                        notes.append(try await respond(
                            as: Notes.self,
                            "You take notes on one part of a meeting transcript, one speaker turn per line. Say what this part covered and anything decided. \(noteRules)",
                            to: "<transcript>\n\(part)\n</transcript>").text)
                    } catch {
                        Log.meetings.notice("Meeting summary part left out: \(error.localizedDescription)")
                    }
                }
                guard !notes.isEmpty else { return nil }
                summary = try await respond(
                    as: Brief.self,
                    "The user message is notes on consecutive parts of one meeting, in order. Summarise the whole meeting as one, never mentioning parts: what it was about and what was decided or happens next. \(rules)",
                    to: notes.joined(separator: "\n")).text
            }
            return lowercasedYou(firstSentences(summary, max: maxSentences))
        } catch {
            Log.meetings.notice("No meeting summary: \(error.localizedDescription)")
            return nil
        }
    }

    /// Three to five words from the meeting's summary, which covers all of
    /// it, or from `titleSample` when it has none. `callName`, the name the
    /// call showed (`MeetingNames.name`), is given as context and not used
    /// as the title: it is often only who was invited, `Sam / Max`. Nil
    /// when Apple Intelligence is unavailable or declines.
    static func title(summary: String?, turns: [Turn], callName: String? = nil) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        var instructions: String
        var prompt: String
        if let summary, !summary.isEmpty {
            instructions = "You title meetings. The user message is a summary of one meeting. \(titleRules)"
            prompt = summary
        } else {
            let words = titleSample(of: turns)
            guard !words.isEmpty else { return nil }
            instructions = "You title meeting transcripts. The user message is words from one transcript. \(titleRules)"
            prompt = "<transcript>\n\(words)\n</transcript>"
        }
        if let callName, !callName.isEmpty {
            instructions += " The meeting's calendar name is given in <calendar> tags: use it as a hint to the subject, not as the title."
            prompt = "<calendar>\(callName)</calendar>\n\(prompt)"
        }
        do {
            let response = try await LanguageModelSession(instructions: instructions)
                .respond(to: prompt, generating: Title.self, options: GenerationOptions(sampling: .greedy))
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return title.isEmpty ? nil : title
        } catch {
            Log.meetings.notice("No generated title: \(error.localizedDescription)")
            return nil
        }
    }

    /// Guardrails that allow transforming what the user's meeting said, for
    /// a call the default guardrails refuse. They apply to plain-text
    /// answers only, not to `@Generable` ones.
    private static let permissive = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    /// One call on a session of its own, so no part sees another's words.
    /// The default guardrails refuse some meetings as sensitive (measured: a
    /// 47-minute interview lost one part in six); such a call is answered on
    /// `permissive` as plain text, which comes back with headings and
    /// bullets, and that answer is rewritten as plain sentences.
    private static func respond<Content: Generable>(as content: Content.Type, _ instructions: String, to prompt: String) async throws -> Content {
        do {
            return try await guided(content, instructions, to: prompt)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: break
            default: throw error
            }
            Log.meetings.notice("Meeting summary call refused, answered as plain text: \(error.localizedDescription)")
            let loose = try await LanguageModelSession(model: permissive, instructions: instructions)
                .respond(to: prompt, options: GenerationOptions(sampling: .greedy)).content
            return try await guided(content, "Rewrite the user message as plain sentences, keeping all of it. No preamble, no lists, no headings.", to: loose)
        }
    }

    /// One guided call on a session of its own, sampled greedily, so the
    /// same prompt gets the same answer. Shared by the meeting model calls.
    static func guided<Content: Generable>(_ content: Content.Type, _ instructions: String, to prompt: String) async throws -> Content {
        try await LanguageModelSession(instructions: instructions)
            .respond(to: prompt, generating: content, options: GenerationOptions(sampling: .greedy)).content
    }
}
