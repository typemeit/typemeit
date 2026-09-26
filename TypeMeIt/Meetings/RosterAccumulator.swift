import Foundation

/// What one look at a meeting window found: who is listed, who is shown
/// speaking, and the caption lines on screen.
struct RosterReading: Equatable, Sendable {
    var roster: [String] = []
    var speaking: Set<String> = []
    var captions: [Caption] = []
    var channel: String?
    /// The Meet code or the huddle's channel.
    var call: String?

    struct Caption: Equatable, Sendable {
        let name: String
        let text: String
    }
}

/// Turns a stream of readings, each stamped in meeting time, into the
/// `MeetingNames` a meeting stores (docs/meetings.md 8.6). Pure.
struct RosterAccumulator: Equatable {
    private(set) var roster: [String] = []
    private(set) var channel: String?
    private(set) var call: String?
    private(set) var spans: [MeetingNames.Span] = []
    private(set) var captions: [MeetingNames.Caption] = []
    /// Names shown speaking, with when that began.
    private var open: [String: Int] = [:]
    /// Open names a reading last left out, with when that began.
    private var missing: [String: Int] = [:]
    /// A turn shorter than this is a backchannel, not a speaker.
    let minimumSpanMs: Int
    /// A turn stays open through a gap in its indicator this long: Meet's
    /// highlight goes out between words.
    let holdMs: Int

    init(minimumSpanMs: Int, holdMs: Int = 0) {
        self.minimumSpanMs = minimumSpanMs
        self.holdMs = holdMs
    }

    mutating func add(_ reading: RosterReading, atMs ms: Int) {
        for name in reading.roster where !roster.contains(name) { roster.append(name) }
        if let c = reading.channel { channel = c }
        if let c = reading.call { call = c }

        for name in reading.speaking {
            if open[name] == nil { open[name] = ms }
            missing[name] = nil
        }
        for (name, start) in open where !reading.speaking.contains(name) {
            let since = missing[name] ?? ms
            missing[name] = since
            guard ms - since >= holdMs else { continue }
            close(name, from: start, to: since)
            open[name] = nil
            missing[name] = nil
        }

        // A caption line grows in place as the speaker goes on, so a line
        // that extends the last one from the same name replaces it.
        for line in reading.captions where !line.text.isEmpty {
            if let i = captions.lastIndex(where: { $0.name == line.name }),
               line.text.hasPrefix(captions[i].text) || captions[i].text.hasPrefix(line.text) {
                if line.text.count > captions[i].text.count { captions[i].text = line.text }
            } else if !captions.contains(where: { $0.name == line.name && $0.text == line.text }) {
                captions.append(MeetingNames.Caption(name: line.name, startMs: ms, text: line.text))
            }
        }
    }

    private mutating func close(_ name: String, from start: Int, to end: Int) {
        guard end - start >= minimumSpanMs else { return }
        // Two turns of one name a poll apart are one turn.
        if let i = spans.lastIndex(where: { $0.name == name }), start - spans[i].endMs <= minimumSpanMs {
            spans[i].endMs = end
        } else {
            spans.append(MeetingNames.Span(name: name, startMs: start, endMs: end))
        }
    }

    /// Closes every open turn at `ms` and says what was learned, best source
    /// first; nil when nothing was read at all. A window that named nobody
    /// still says which call it was, so another call that follows within
    /// minutes is not joined onto it (`MeetingMerge`): on 25 September a
    /// Retro that yielded no names was joined to the next call.
    mutating func finish(atMs ms: Int) -> MeetingNames? {
        for (name, start) in open { close(name, from: start, to: missing[name] ?? ms) }
        open = [:]
        missing = [:]
        spans.sort { $0.startMs < $1.startMs }
        let source: MeetingNames.Source
        if !captions.isEmpty { source = .captions }
        else if !spans.isEmpty { source = .speaking }
        else if !roster.isEmpty || call != nil || channel != nil { source = .roster }
        else { return nil }
        return MeetingNames(source: source, roster: roster, channel: channel, spans: spans, captions: captions.isEmpty ? nil : captions, call: call)
    }
}
