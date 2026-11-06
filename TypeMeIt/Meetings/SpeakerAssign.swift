import Foundation

/// Naming a meeting's speakers by hand: which still need a name, the clips
/// that let the user hear them, the names offered, and what a choice does
/// to the meeting. Pure; the meeting page plays and saves.
enum SpeakerAssign {
    /// A clip pads its paragraph by this much each side, so the first and
    /// last words are not clipped.
    static let clipLeadMs = 250
    /// The longest clip played; a longer paragraph plays its start.
    static let clipMaxMs = 8_500
    /// How many clips a speaker offers.
    static let clipLimit = 3
    /// No other speaker may talk this close to a clip.
    static let soloPadMs = 600
    /// A paragraph worth playing: long enough to recognise, dense enough
    /// that it is talking and not a pause with a word at each end.
    static let clipMinMs = 2_500
    static let clipMinWords = 6
    static let clipMinWordsPerSecond = 1.5
    /// Clips from one stretch of a meeting sound alike; prefer ones this far apart.
    static let clipSpreadMs = 90_000
    /// Past people offered before anything is typed, and after.
    static let pastShown = 3
    static let pastMatched = 6

    /// A speaker still labelled by number: neither the meeting nor the user
    /// gave it a name, or its name is one of those labels (a shared meeting
    /// marks every name as given). The room of a recording never diarized is
    /// not a person.
    static func isUnknown(_ speaker: Meeting.Speaker) -> Bool {
        !speaker.isYou && speaker.id != Meeting.Speaker.room && (speaker.nameSource == nil || Meeting.Speaker.isPlaceholder(speaker.name))
    }

    static func unknown(in meeting: Meeting) -> [Meeting.Speaker] {
        meeting.speakers.filter(isUnknown)
    }

    /// The speaker's first name: "Ana". "Ana R." when another speaker is
    /// also an Ana, the whole name when the initial is shared too. A
    /// speaker no one has named keeps its label: "Speaker 2".
    static func firstName(of id: String, in meeting: Meeting) -> String {
        guard let speaker = meeting.speakers.first(where: { $0.id == id }), !isUnknown(speaker) else { return meeting.speakerName(id) }
        let words = speaker.name.split(separator: " ")
        guard words.count > 1, let first = words.first, let last = words.last else { return speaker.name }
        let namesakes = meeting.speakers.filter { $0.id != id }.map { $0.name.split(separator: " ") }
            .filter { $0.first?.lowercased() == first.lowercased() }
        if namesakes.isEmpty { return String(first) }
        if namesakes.contains(where: { $0.count > 1 && $0.last?.prefix(1).lowercased() == last.prefix(1).lowercased() }) { return speaker.name }
        return "\(first) \(last.prefix(1))."
    }

    /// The next unknown speaker after `id` in the list's order, wrapping;
    /// from the start when `id` is gone (merged).
    static func nextUnknown(after id: String?, in meeting: Meeting, backwards: Bool = false) -> String? {
        let order = meeting.speakers.map(\.id)
        guard !order.isEmpty else { return nil }
        let start = id.flatMap { order.firstIndex(of: $0) } ?? (backwards ? 0 : order.count - 1)
        for step in 1...order.count {
            let i = ((start + (backwards ? -step : step)) % order.count + order.count) % order.count
            let speaker = meeting.speakers[i]
            if speaker.id != id, isUnknown(speaker) { return speaker.id }
        }
        return nil
    }

    // MARK: Who the user is

    /// Whether a listed name is the user's: the tile the transcription found
    /// the user on, or the Mac's name.
    static func isUser(_ name: String, in meeting: Meeting) -> Bool {
        [meeting.names?.user, NSFullUserName()].compactMap { $0 }.contains { isUser(name, userName: $0) }
    }

    /// Whether a listed name is `userName`. Meet uses the Google name, which
    /// need not be the Mac's ("Max Mitchell" for "Maximilian Mitchell"), so
    /// a shared last name with one first name starting the other counts.
    static func isUser(_ name: String, userName: String) -> Bool {
        let a = name.lowercased().split(separator: " ")
        let b = userName.lowercased().split(separator: " ")
        guard let firstA = a.first, let firstB = b.first else { return false }
        if a == b { return true }
        guard a.count > 1, b.count > 1, a.last == b.last else { return false }
        return firstA.hasPrefix(firstB) || firstB.hasPrefix(firstA)
    }

    /// Everyone the call listed, the user left out.
    static func callNames(_ meeting: Meeting) -> [String] {
        (meeting.names?.roster ?? []).filter { !isUser($0, in: meeting) }
    }

    // MARK: Clips

    struct Clip: Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    /// Up to `clipLimit` stretches where only this speaker talks, the most
    /// words first and spread across the meeting, in time order. A speaker
    /// with no such stretch offers its longest paragraphs.
    static func clips(for id: String, in meeting: Meeting) -> [Clip] {
        let paragraphs = meeting.paragraphs.sorted { $0.startMs < $1.startMs }
        let own = paragraphs.indices.filter { paragraphs[$0].speaker == id }
        let wordCount = { (i: Int) in paragraphs[i].text.split(separator: " ").count }
        let playable = own.filter { i in
            let p = paragraphs[i], ms = p.endMs - p.startMs, words = wordCount(i)
            return ms >= clipMinMs && words >= clipMinWords && Double(words) / (Double(ms) / 1000) >= clipMinWordsPerSecond && solo(i, in: paragraphs)
        }
        let ranked = (playable.isEmpty ? own : playable).sorted { wordCount($0) > wordCount($1) }
        var chosen: [Int] = []
        for i in ranked where chosen.count < clipLimit && chosen.allSatisfy({ abs(paragraphs[$0].startMs - paragraphs[i].startMs) > clipSpreadMs }) {
            chosen.append(i)
        }
        for i in ranked where chosen.count < clipLimit && !chosen.contains(i) { chosen.append(i) }
        return chosen.sorted().map { clip(paragraphs[$0]) }
    }

    /// No other speaker's paragraph within `soloPadMs` of this one.
    private static func solo(_ i: Int, in paragraphs: [Meeting.Paragraph]) -> Bool {
        let p = paragraphs[i]
        return !paragraphs.contains { $0.speaker != p.speaker && $0.startMs < p.endMs + soloPadMs && $0.endMs > p.startMs - soloPadMs }
    }

    /// The paragraph padded, cut at `clipMaxMs`; a cut one keeps the share
    /// of its words that fits and ends in an ellipsis.
    private static func clip(_ p: Meeting.Paragraph) -> Clip {
        let start = max(0, p.startMs - clipLeadMs)
        let end = p.endMs + clipLeadMs
        guard end - start > clipMaxMs else { return Clip(startMs: start, endMs: end, text: p.text) }
        let words = p.text.split(separator: " ")
        let kept = max(1, words.count * (clipMaxMs - clipLeadMs) / max(1, p.endMs - p.startMs))
        return Clip(startMs: start, endMs: start + clipMaxMs, text: words.prefix(kept).joined(separator: " ") + "…")
    }

    // MARK: Names offered

    /// Someone named in another meeting, and in how many.
    struct Person: Equatable, Sendable {
        var name: String
        var calls: Int
    }

    /// Everyone named on a speaker in the other meetings, the user and this
    /// call's list left out. People who were in meetings with someone on
    /// this call's list come first, then by how many meetings.
    static func past(_ meetings: [Meeting], for meeting: Meeting) -> [Person] {
        let here = Set(callNames(meeting).map { $0.lowercased() })
        var people: [String: (name: String, meetings: Int, shared: Int)] = [:]
        for other in meetings where other.id != meeting.id {
            let named = other.speakers.filter { !$0.isYou && !isUnknown($0) && $0.id != Meeting.Speaker.room }.map(\.name)
            let around = Set((named + (other.names?.roster ?? [])).map { $0.lowercased() })
            let shares = !around.isDisjoint(with: here)
            for name in Set(named) where !here.contains(name.lowercased()) && !isUser(name, in: meeting) {
                let key = name.lowercased()
                var entry = people[key] ?? (name, 0, 0)
                entry.meetings += 1
                if shares { entry.shared += 1 }
                people[key] = entry
            }
        }
        return people.values
            .sorted { ($0.shared, $0.meetings, $1.name) > ($1.shared, $1.meetings, $0.name) }
            .map { Person(name: $0.name, calls: $0.meetings) }
    }

    enum Choice: Equatable, Sendable {
        case name(String)
        case me
        /// Takes a speaker merged into this one back out.
        case split(String)
    }

    struct Option: Equatable, Sendable {
        enum Group: Equatable, Sendable { case voice, call, past, same, other, merged }
        var choice: Choice
        var label: String
        var group: Group
        var detail: String = ""
        /// The key that picks it while nothing is typed.
        var key: Int? = nil
    }

    /// What the name field offers for `id`: the name its voice matches
    /// (`VoiceNames`, 8.7), the call's names not yet given, people from past
    /// meetings, the speakers already named (to merge), the user, what was
    /// typed, and the speakers merged into it (to split).
    static func options(for id: String, in meeting: Meeting, query: String, past: [Person], voice: String? = nil) -> [Option] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matches = { (name: String) in
            q.isEmpty || name.lowercased().hasPrefix(q) || name.lowercased().split(whereSeparator: { " '-".contains($0) }).contains { $0.hasPrefix(q) }
        }
        // Its own name too: offering what it is already called does nothing.
        var used = Set(meeting.speakers.map { $0.name.lowercased() })
        var out: [Option] = []
        if let voice, !used.contains(voice.lowercased()), matches(voice) {
            out.append(Option(choice: .name(voice), label: voice, group: .voice))
            used.insert(voice.lowercased())
        }
        var keyed = 0
        for name in callNames(meeting) where !used.contains(name.lowercased()) && matches(name) {
            keyed += 1
            out.append(Option(choice: .name(name), label: name, group: .call, key: q.isEmpty ? keyed : nil))
        }
        for person in past.filter({ !used.contains($0.name.lowercased()) && matches($0.name) }).prefix(q.isEmpty ? pastShown : pastMatched) {
            out.append(Option(choice: .name(person.name), label: person.name, group: .past, detail: counted(person.calls, "call")))
        }
        for speaker in meeting.speakers where speaker.id != id && !speaker.isYou && !isUnknown(speaker) && matches(speaker.name) {
            out.append(Option(choice: .name(speaker.name), label: speaker.name, group: .same, detail: "merge"))
        }
        let you = meeting.speakers.first(where: \.isYou)
        if you?.id != id, q.isEmpty || "that's me".hasPrefix(q) || q == "me" {
            out.append(Option(choice: .me, label: "that's me", group: .other, detail: you == nil ? "" : "merge into You"))
        }
        if !q.isEmpty, !"that's me".hasPrefix(q), q != "me", !out.contains(where: { $0.label.lowercased() == q }) {
            let typed = query.trimmingCharacters(in: .whitespaces)
            out.append(Option(choice: .name(typed), label: "use “\(typed)”", group: .other))
        }
        if q.isEmpty {
            for merged in mergedInto(id, in: meeting) {
                out.append(Option(choice: .split(merged.id), label: merged.name, group: .merged, detail: "split"))
            }
        }
        return out
    }

    // MARK: Choosing

    /// The meeting with `id` given `choice`. A name another speaker already
    /// has, or "that's me" while another voice is You, merges the two. Then,
    /// when one name on the call's list and one unknown speaker are left,
    /// that speaker takes it.
    static func apply(_ choice: Choice, to id: String, in meeting: Meeting) -> Meeting {
        var m = meeting
        guard let i = m.speakers.firstIndex(where: { $0.id == id }) else { return m }
        switch choice {
        case .split(let merged):
            return split(merged, in: m)
        case .me:
            if let you = m.speakers.first(where: { $0.isYou && $0.id != id }) {
                m = merge(id, into: you.id, in: m)
            } else {
                m.speakers[i].isYou = true
                rename(&m.speakers[i], to: "You")
            }
        case .name(let raw):
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return m }
            if let twin = m.speakers.first(where: { $0.id != id && !$0.isYou && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                m = merge(id, into: twin.id, in: m)
            } else {
                rename(&m.speakers[i], to: name)
                m.speakers[i].isYou = false
            }
        }
        let used = Set(m.speakers.map { $0.name.lowercased() })
        let left = callNames(m).filter { !used.contains($0.lowercased()) }
        let open = m.speakers.indices.filter { isUnknown(m.speakers[$0]) }
        if left.count == 1, open.count == 1 {
            m.speakers[open[0]].name = left[0]
            m.speakers[open[0]].nameSource = .roster
        }
        return m
    }

    /// `speaker` named `name` by the user, keeping the name the meeting
    /// window gave it as its prediction.
    private static func rename(_ speaker: inout Meeting.Speaker, to name: String) {
        if let source = speaker.nameSource, source != .user {
            speaker.predicted = Meeting.Speaker.Prediction(name: speaker.name, source: source)
        }
        speaker.name = name
        speaker.nameSource = .user
    }

    /// `from`'s paragraphs moved onto `into`, each remembering the speaker
    /// it had, and `from` kept aside as it was, so `split` can undo it.
    static func merge(_ from: String, into: String, in meeting: Meeting) -> Meeting {
        var m = meeting
        guard let source = m.speakers.first(where: { $0.id == from }), let j = m.speakers.firstIndex(where: { $0.id == into }) else { return m }
        m.speakers[j].talkMs += source.talkMs
        m.speakers.removeAll { $0.id == from }
        m.mergedSpeakers = (m.mergedSpeakers ?? []) + [source]
        for k in m.paragraphs.indices where m.paragraphs[k].speaker == from {
            m.paragraphs[k].speaker = into
            m.paragraphs[k].mergedFrom = m.paragraphs[k].mergedFrom ?? from
        }
        return m
    }

    /// The speakers merged into `id`, as they were: those whose paragraphs it now has.
    static func mergedInto(_ id: String, in meeting: Meeting) -> [Meeting.Speaker] {
        let froms = Set(meeting.paragraphs.filter { $0.speaker == id }.compactMap(\.mergedFrom))
        return (meeting.mergedSpeakers ?? []).filter { froms.contains($0.id) }
    }

    /// A merged speaker back on its own, with the paragraphs that were its
    /// and the talking time they hold, taken from whoever had them.
    static func split(_ id: String, in meeting: Meeting) -> Meeting {
        var m = meeting
        guard var kept = m.mergedSpeakers?.first(where: { $0.id == id }) else { return m }
        m.mergedSpeakers?.removeAll { $0.id == id }
        if m.mergedSpeakers?.isEmpty == true { m.mergedSpeakers = nil }
        kept.talkMs = 0
        for k in m.paragraphs.indices where m.paragraphs[k].mergedFrom == id {
            let ms = max(0, m.paragraphs[k].endMs - m.paragraphs[k].startMs)
            if let holder = m.speakers.firstIndex(where: { $0.id == m.paragraphs[k].speaker }) { m.speakers[holder].talkMs -= ms }
            kept.talkMs += ms
            m.paragraphs[k].speaker = id
            m.paragraphs[k].mergedFrom = nil
        }
        m.speakers.append(kept)
        return m
    }
}
