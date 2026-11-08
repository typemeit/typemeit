import Foundation

/// Who spoke when, as a square of cells read left to right and top to
/// bottom like a page. The meeting's whole length is spread over every
/// cell, so the square is always full: a cell of an hour-long meeting is a
/// second, of a 15-minute one a quarter of a second. Each cell holds the
/// speaker who talked most in it, or quiet.
///
/// A person someone named keeps one hue in every meeting, picked from
/// their name; everyone else takes the hues left over. Takes only times,
/// speaker ids, which speaker is you and the given names, never words, the
/// title or the app; `Meeting.fingerprint` hands it those. It knows nothing
/// of `Meeting` so the design system gallery can draw it.
struct MeetingFingerprint: Equatable, Sendable {
    /// A speaker as the fingerprint sees one.
    struct Voice: Equatable, Sendable {
        var id: String
        var isYou: Bool
        var talkMs: Int
        /// The name someone gave them, nil while they are "Speaker 2". Only
        /// picks their hue; the fingerprint keeps no names.
        var name: String?
    }

    /// A paragraph as the fingerprint sees one.
    struct Turn: Equatable, Sendable {
        var speaker: String
        var startMs: Int
        var endMs: Int
        /// Said inside another speaker's turn.
        var aside: Bool
    }

    /// Cells along each side of the meeting page's square.
    static let side = 60
    /// The meetings list's square is the page's folded this many to a side.
    static let fold = 4
    /// Speech covering less of a cell than this leaves it quiet.
    static let quietBelow = 0.3
    /// An aside at least this long wins the cells it covers even where
    /// someone else talked more, so a "yeah" inside a long turn shows.
    static let asideMs = 500
    /// A cell's value when nobody spoke enough in it.
    static let quiet: Int16 = -1
    /// Everyone but you. Lemon is too faint on paper.
    static let hues: [CloudColor] = [.coral, .sky, .mint, .amber, .lavender, .rose]

    /// What colour a cell takes.
    enum Tone: Equatable, Sendable {
        case quiet, you
        case hue(CloudColor)
        /// Someone left over once every hue is taken.
        case rest
    }

    /// Cells along each side.
    let side: Int
    let durationMs: Int
    /// The speaker ids, you first, then by talk time.
    let speakers: [String]
    /// Each speaker's colour, in `speakers` order.
    let tones: [Tone]
    /// An index into `speakers` for each cell in reading order, or `quiet`.
    let cells: [Int16]

    /// Nil for a meeting with no length.
    init?(durationMs: Int, voices: [Voice], turns: [Turn]) {
        guard durationMs > 0 else { return nil }
        let ordered = MeetingFingerprint.ordered(voices, turns)
        side = MeetingFingerprint.side
        self.durationMs = durationMs
        speakers = ordered.map(\.id)
        tones = MeetingFingerprint.tones(ordered)
        cells = MeetingFingerprint.cells(durationMs, turns, speakers: speakers)
    }

    private init(side: Int, durationMs: Int, speakers: [String], tones: [Tone], cells: [Int16]) {
        self.side = side
        self.durationMs = durationMs
        self.speakers = speakers
        self.tones = tones
        self.cells = cells
    }

    /// The hue a named person has in every meeting where it is free: from
    /// their name, ignoring case and the spaces round it.
    static func hue(for name: String) -> CloudColor {
        // FNV-1a, because String's own hash changes from one launch to the next.
        let fnvOffset: UInt64 = 0xcbf2_9ce4_8422_2325, fnvPrime: UInt64 = 0x100_0000_01b3
        let hash = name.trimmingCharacters(in: .whitespaces).lowercased().utf8
            .reduce(fnvOffset) { ($0 ^ UInt64($1)) &* fnvPrime }
        return hues[Int(hash % UInt64(hues.count))]
    }

    var cellMs: Double { Double(durationMs) / Double(cells.count) }

    /// Where in the meeting `cell` begins.
    func startMs(ofCell cell: Int) -> Int { Int(Double(cell) * cellMs) }

    /// The cell playing at `ms`.
    func cell(atMs ms: Int) -> Int { min(max(Int(Double(ms) / cellMs), 0), cells.count - 1) }

    /// Who holds `cell`, nil for quiet.
    func speaker(ofCell cell: Int) -> String? {
        cells[cell] == MeetingFingerprint.quiet ? nil : speakers[Int(cells[cell])]
    }

    /// The colour `speaker` has in this meeting; nil for an id it does not have.
    func tone(ofSpeaker speaker: String) -> Tone? {
        speakers.firstIndex(of: speaker).map { tones[$0] }
    }

    func tone(ofCell cell: Int) -> Tone {
        cells[cell] == MeetingFingerprint.quiet ? .quiet : tones[Int(cells[cell])]
    }

    /// The square for the meetings list: each block of `fold` × `fold`
    /// cells becomes the value most of them hold; a tie goes to the one
    /// that comes first in reading order.
    func folded() -> MeetingFingerprint {
        let fold = MeetingFingerprint.fold
        let small = side / fold
        var folded = [Int16](repeating: MeetingFingerprint.quiet, count: small * small)
        for row in 0..<small {
            for column in 0..<small {
                var block: [Int16] = []
                for r in 0..<fold {
                    for c in 0..<fold { block.append(cells[(row * fold + r) * side + column * fold + c]) }
                }
                let counts = Dictionary(block.map { ($0, 1) }, uniquingKeysWith: +)
                folded[row * small + column] = block.first { counts[$0] == counts.values.max() }!
            }
        }
        return MeetingFingerprint(side: small, durationMs: durationMs, speakers: speakers, tones: tones, cells: folded)
    }

    /// How many of the cells' speech is yours and everyone else's, for
    /// VoiceOver: "you 40%, 2 others 60%".
    var spokenShares: String {
        let spoken = cells.filter { $0 != MeetingFingerprint.quiet }
        let startsWithYou = tones.first == .you
        guard !spoken.isEmpty else { return "quiet" }
        let percent = { (n: Int) in "\(Int((Double(n) / Double(spoken.count) * 100).rounded()))%" }
        let others = Set(spoken.filter { !startsWithYou || $0 != 0 }).count
        guard startsWithYou else { return counted(others, "speaker") }
        let yours = spoken.filter { $0 == 0 }.count
        guard others > 0 else { return "you \(percent(yours))" }
        return "you \(percent(yours)), \(counted(others, "other")) \(percent(spoken.count - yours))"
    }

    /// You first, then everyone else by talk time, most first; a tie keeps
    /// the meeting's speaker order. A paragraph's speaker missing from
    /// `voices` comes last, in order of first appearance, unnamed.
    private static func ordered(_ voices: [Voice], _ turns: [Turn]) -> [Voice] {
        let you = voices.first { $0.isYou }
        let others = voices.enumerated()
            .filter { !$0.element.isYou }
            .sorted { ($0.element.talkMs, -$0.offset) > ($1.element.talkMs, -$1.offset) }
            .map(\.element)
        var ordered = (you.map { [$0] } ?? []) + others
        for turn in turns where !ordered.contains(where: { $0.id == turn.speaker }) {
            ordered.append(Voice(id: turn.speaker, isYou: false, talkMs: 0, name: nil))
        }
        return ordered
    }

    /// You in ink. Named people, most talk first, take their own hue, or
    /// when someone here already has it the next free one round the list;
    /// then the unnamed, most talk first, take the first free hues. Anyone
    /// left once all are taken is `rest`.
    private static func tones(_ ordered: [Voice]) -> [Tone] {
        var tones = ordered.map { $0.isYou ? Tone.you : nil }
        var free = hues
        func take(_ index: Int, from start: Int) {
            let hue = (0..<hues.count).lazy.map { hues[(start + $0) % hues.count] }.first(where: free.contains)
            tones[index] = hue.map(Tone.hue) ?? .rest
            free.removeAll { $0 == hue }
        }
        for (index, voice) in ordered.enumerated() where tones[index] == nil {
            if let name = voice.name { take(index, from: hues.firstIndex(of: hue(for: name))!) }
        }
        for index in ordered.indices where tones[index] == nil {
            take(index, from: 0)
        }
        return tones.map { $0! }
    }

    /// One pass over the turns, each adding its milliseconds to the cells
    /// it overlaps.
    private static func cells(_ durationMs: Int, _ turns: [Turn], speakers: [String]) -> [Int16] {
        let count = side * side
        let cellMs = Double(durationMs) / Double(count)
        let index = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($0.element, $0.offset) })
        var spokenMs = [Double](repeating: 0, count: count * speakers.count)
        var firstMs = [Double](repeating: .infinity, count: count * speakers.count)
        var aside = [(ms: Double, speaker: Int)?](repeating: nil, count: count)

        for turn in turns {
            let start = Double(max(turn.startMs, 0))
            let end = Double(min(turn.endMs, durationMs))
            guard end > start, let speaker = index[turn.speaker] else { continue }
            let isAside = turn.aside && turn.endMs - turn.startMs >= asideMs
            let first = Int(start / cellMs)
            let last = min(Int((end / cellMs).rounded(.up)) - 1, count - 1)
            guard first <= last else { continue }
            for cell in first...last {
                let cellStart = Double(cell) * cellMs
                let overlap = min(end, cellStart + cellMs) - max(start, cellStart)
                guard overlap > 0 else { continue }
                spokenMs[cell * speakers.count + speaker] += overlap
                firstMs[cell * speakers.count + speaker] = min(firstMs[cell * speakers.count + speaker], max(start, cellStart))
                // An aside claims a cell it fills at least half of, or, in a
                // cell longer than itself, the one holding most of it.
                if isAside, overlap >= min(end - start, cellMs) / 2, overlap > aside[cell]?.ms ?? 0 {
                    aside[cell] = (overlap, speaker)
                }
            }
        }

        return (0..<count).map { cell in
            if let claimed = aside[cell] { return Int16(claimed.speaker) }
            let row = cell * speakers.count
            let spoken = (0..<speakers.count).reduce(0) { $0 + spokenMs[row + $1] }
            guard spoken >= quietBelow * cellMs else { return quiet }
            let winner = (0..<speakers.count).max { a, b in
                (spokenMs[row + a], -firstMs[row + a]) < (spokenMs[row + b], -firstMs[row + b])
            }!
            return Int16(winner)
        }
    }
}
