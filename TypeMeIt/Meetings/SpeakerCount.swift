import Foundation

/// How many voices the diarizer may keep on a call's far end, from what the
/// meeting window showed (docs/meetings.md 8.3). Pure.
///
/// The diarizer finds its own voices; the count only folds the quietest into
/// the nearest. Meet lights some people's tiles late or not at all, so the
/// cap is everyone listed other than the user, not just the people lit:
/// capped at the lit, real people were merged on every one of seven past
/// calls checked by ear (listen review `extra-voices-1109`).
enum SpeakerCount: Equatable, Sendable {
    case exactly(Int)
    case atMost(Int)

    /// The most voices the track can hold either way.
    var maximum: Int {
        switch self {
        case .exactly(let n), .atMost(let n): n
        }
    }

    /// At most the people listed other than the user; exactly the far-end
    /// talkers when the window showed at least that many speaking; nil when
    /// the window gave neither.
    static func of(_ names: MeetingNames, talkers: [String], userName: String?) -> SpeakerCount? {
        let listed = names.roster.filter { !SpeakerNaming.isUser($0, userName: userName) }.count
        if listed > talkers.count { return .atMost(listed) }
        return talkers.isEmpty ? nil : .exactly(talkers.count)
    }

    /// The names shown speaking while the far end said at least `minimumMs`
    /// of words, and more there than on the mic. The second rule leaves the
    /// user out whatever name the call shows them by; the first leaves out
    /// a tile lit by a cough or a keyboard.
    static func farEndTalkers(spans: [MeetingNames.Span], farEnd: [Transcriber.Word], mic: [Transcriber.Word], lagMs: Int, minimumMs: Int) -> [String] {
        let heard = heard(spans: spans, farEnd: farEnd, mic: mic, lagMs: lagMs)
        return heard.order.filter { heard.farEndMs[$0]! >= minimumMs && heard.farEndMs[$0]! > heard.micMs[$0]! }
    }

    /// The name on the user's own tile: shown speaking while the mic said at
    /// least `minimumMs` of words, more than the far end did there; of
    /// several, the one with most. Meet labels the user by their Google
    /// name, which need not be the Mac's: "Max Mitchell" on the 25
    /// September capture, "Maximilian Mitchell" to `NSFullUserName()`.
    static func userTile(spans: [MeetingNames.Span], farEnd: [Transcriber.Word], mic: [Transcriber.Word], lagMs: Int, minimumMs: Int) -> String? {
        let heard = heard(spans: spans, farEnd: farEnd, mic: mic, lagMs: lagMs)
        return heard.order.filter { heard.micMs[$0]! >= minimumMs && heard.micMs[$0]! > heard.farEndMs[$0]! }
            .max { heard.micMs[$0]! < heard.micMs[$1]! }
    }

    /// The user's name as the call shows it. The one roster name that is
    /// the Mac's own name, the first name shortened or not, comes first;
    /// then the user's tile, but only when `farEndSpoke`: with the far end
    /// silent the loudspeaker put everyone on the mic, and every lit tile
    /// looks like the user's.
    static func user(roster: [String], macName: String, spans: [MeetingNames.Span], farEnd: [Transcriber.Word], mic: [Transcriber.Word],
                     farEndSpoke: Bool, lagMs: Int, minimumMs: Int) -> String? {
        let own = roster.filter { SpeakerAssign.isUser($0, userName: macName) }
        if own.count == 1 { return own[0] }
        guard farEndSpoke else { return nil }
        return userTile(spans: spans, farEnd: farEnd, mic: mic, lagMs: lagMs, minimumMs: minimumMs)
    }

    /// The names lit since `sinceMs`, the user's own tile left out by the
    /// Mac's name.
    static func talking(_ spans: [MeetingNames.Span], sinceMs: Int, excluding macName: String) -> [String] {
        var lit: [String] = []
        for span in spans where span.endMs > sinceMs && !SpeakerAssign.isUser(span.name, userName: macName) && !lit.contains(span.name) {
            lit.append(span.name)
        }
        return lit
    }

    /// Whether `words` hold at least `minimumMs` of speech.
    static func spoke(_ words: [Transcriber.Word], minimumMs: Int) -> Bool {
        wordMs(words, from: .min, to: .max) >= minimumMs
    }

    /// Milliseconds of each track's words inside each name's spans, names in first-span order.
    private static func heard(spans: [MeetingNames.Span], farEnd: [Transcriber.Word], mic: [Transcriber.Word], lagMs: Int) -> (order: [String], farEndMs: [String: Int], micMs: [String: Int]) {
        var order: [String] = []
        var farEndMs: [String: Int] = [:]
        var micMs: [String: Int] = [:]
        for span in spans {
            if farEndMs[span.name] == nil { order.append(span.name) }
            let start = span.startMs - lagMs, end = span.endMs - lagMs
            farEndMs[span.name, default: 0] += wordMs(farEnd, from: start, to: end)
            micMs[span.name, default: 0] += wordMs(mic, from: start, to: end)
        }
        return (order, farEndMs, micMs)
    }

    /// Milliseconds of `words` inside `start..<end`.
    private static func wordMs(_ words: [Transcriber.Word], from start: Int, to end: Int) -> Int {
        words.reduce(0) { total, word in
            total + max(0, min(end, word.end.milliseconds) - max(start, word.start.milliseconds))
        }
    }
}
