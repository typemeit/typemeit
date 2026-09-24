import Foundation

/// How many voices the diarizer is told a call's far end holds, from what
/// the meeting window showed (docs/meetings.md 8.3). Pure.
///
/// Measured on 24 September with `-diarizeCounts`: told the right count, the
/// diarizer matched its own; told one too many, it split a real voice, the
/// Slack call's one far-end person into 87 s and 37 s. So only people shown
/// speaking set an exact count. The list holds everyone who joined, silent
/// listeners included, and only caps the count.
enum SpeakerCount: Equatable, Sendable {
    case exactly(Int)
    case atMost(Int)

    /// Exactly the far-end talkers when the window showed anyone speaking;
    /// otherwise at most the people listed other than the user; nil when
    /// the window gave neither.
    static func of(_ names: MeetingNames, talkers: [String], userName: String?) -> SpeakerCount? {
        if !talkers.isEmpty { return .exactly(talkers.count) }
        let listed = names.roster.filter { !SpeakerNaming.isUser($0, userName: userName) }.count
        return listed > 0 ? .atMost(listed) : nil
    }

    /// The names shown speaking while the far end said at least `minimumMs`
    /// of words, and more there than on the mic. The second rule leaves the
    /// user out whatever name the call shows them by; the first leaves out
    /// a tile lit by a cough or a keyboard.
    static func farEndTalkers(spans: [MeetingNames.Span], farEnd: [Transcriber.Word], mic: [Transcriber.Word], lagMs: Int, minimumMs: Int) -> [String] {
        var order: [String] = []
        var farEndMs: [String: Int] = [:]
        var micMs: [String: Int] = [:]
        for span in spans {
            if farEndMs[span.name] == nil { order.append(span.name) }
            let start = span.startMs - lagMs, end = span.endMs - lagMs
            farEndMs[span.name, default: 0] += wordMs(farEnd, from: start, to: end)
            micMs[span.name, default: 0] += wordMs(mic, from: start, to: end)
        }
        return order.filter { farEndMs[$0]! >= minimumMs && farEndMs[$0]! > micMs[$0]! }
    }

    /// Milliseconds of `words` inside `start..<end`.
    private static func wordMs(_ words: [Transcriber.Word], from start: Int, to end: Int) -> Int {
        words.reduce(0) { total, word in
            total + max(0, min(end, word.end.milliseconds) - max(start, word.start.milliseconds))
        }
    }
}
