import AppKit
import SwiftUI

/// A meeting's fingerprint (`MeetingFingerprint`) as a square of cells: you
/// in ink, everyone else in a cloud hue, quiet cells faint.
/// Before there is a transcript it shows where the meeting has got to: an
/// empty frame while recording, faint cells lit top-down while
/// transcribing, faint cells when transcription failed.
struct SquareFingerprint: View {
    enum Content: Equatable {
        case recording
        case transcribing(Double)
        case failed
        case done(MeetingFingerprint)
    }

    let content: Content
    /// Cells along each side when there is no fingerprint to say.
    var side = MeetingFingerprint.side
    var cell: CGFloat = 3
    /// The cell under the player's playhead, outlined in ink.
    var playingCell: Int? = nil
    /// Cells where a question was offered to Claude Code.
    var questionCells: Set<Int> = []
    /// Nil leaves the square unclickable, with the arrow pointer.
    var click: ((Int) -> Void)? = nil

    @State private var pointing = false
    @Environment(\.displayScale) private var displayScale

    private var cellsPerSide: Int {
        if case .done(let fingerprint) = content { fingerprint.side } else { side }
    }

    var body: some View {
        let length = cell * CGFloat(cellsPerSide)
        Canvas { context, _ in draw(in: &context) }
            .frame(width: length, height: length)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, click != nil, !pointing { NSCursor.pointingHand.push(); pointing = true }
                if !inside, pointing { NSCursor.pop(); pointing = false }
            }
            .onChange(of: click == nil) { _, unclickable in
                if unclickable, pointing { NSCursor.pop(); pointing = false }
            }
            .gesture(SpatialTapGesture().onEnded { tap in
                if let click, let cell = index(at: tap.location) { click(cell) }
            }, including: click == nil ? .none : .all)
            .accessibilityElement()
            .accessibilityLabel("who spoke when")
            .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        switch content {
        case .recording: "recording"
        case .transcribing(let fraction): "transcribing \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        case .failed: "failed"
        case .done(let fingerprint): fingerprint.spokenShares
        }
    }

    private func index(at location: CGPoint) -> Int? {
        let column = Int(location.x / cell), row = Int(location.y / cell)
        guard (0..<cellsPerSide).contains(column), (0..<cellsPerSide).contains(row) else { return nil }
        return row * cellsPerSide + column
    }

    /// A cell's square, its edges on whole pixels: a cell that is not a
    /// whole number of pixels would otherwise leave a faint seam beside its
    /// neighbour, so cells come out a pixel wider or narrower in turn.
    private func rect(_ index: Int) -> CGRect {
        let snap = { (points: CGFloat) in (points * displayScale).rounded() / displayScale }
        let column = CGFloat(index % cellsPerSide), row = CGFloat(index / cellsPerSide)
        let x = snap(column * cell), y = snap(row * cell)
        return CGRect(x: x, y: y, width: snap((column + 1) * cell) - x, height: snap((row + 1) * cell) - y)
    }

    private func draw(in context: inout GraphicsContext) {
        let count = cellsPerSide * cellsPerSide
        switch content {
        case .recording:
            let frame = CGRect(x: 0, y: 0, width: cell * CGFloat(cellsPerSide), height: cell * CGFloat(cellsPerSide))
            context.stroke(Path(frame.insetBy(dx: DesignTokens.hairline / 2, dy: DesignTokens.hairline / 2)),
                           with: .color(DesignTokens.Colors.inkA12), lineWidth: DesignTokens.hairline)
        case .transcribing(let fraction):
            let lit = Int(min(max(fraction, 0), 1) * Double(count))
            for index in 0..<count {
                context.fill(Path(rect(index)), with: .color(index < lit ? DesignTokens.Colors.inkA32 : DesignTokens.Colors.inkA08))
            }
        case .failed:
            context.fill(Path(CGRect(x: 0, y: 0, width: cell * CGFloat(cellsPerSide), height: cell * CGFloat(cellsPerSide))),
                         with: .color(DesignTokens.Colors.inkA08))
        case .done(let fingerprint):
            for index in 0..<count {
                context.fill(Path(rect(index)), with: .color(SquareFingerprint.colour(fingerprint.tone(ofCell: index))))
            }
            for index in questionCells where index < count {
                outline(index, DesignTokens.Colors.claude, in: &context)
            }
            if let playingCell, playingCell < count { outline(playingCell, DesignTokens.Colors.ink, in: &context) }
        }
    }

    /// A 1 pt line round `index`, drawn outside it so the cell's own colour still shows.
    private func outline(_ index: Int, _ colour: Color, in context: inout GraphicsContext) {
        let line: CGFloat = 1
        context.stroke(Path(rect(index).insetBy(dx: -line / 2, dy: -line / 2)), with: .color(colour), lineWidth: line)
    }

    static func colour(_ tone: MeetingFingerprint.Tone) -> Color {
        switch tone {
        case .quiet: DesignTokens.Colors.inkA08
        case .you: DesignTokens.Colors.ink
        case .hue(let hue): Color(nsColor: hue.color)
        case .rest: DesignTokens.Colors.ink3
        }
    }
}

#if DEBUG
/// One invented meeting: click a cell to play from it, and transcribe to
/// watch the square fill before the colours arrive.
struct SquareFingerprintSpecimen: View {
    private static let durationMs = 42 * 60_000
    private static let names = ["s1": "Robin", "s2": "Sam", "s3": "Alex"]
    private static let fingerprint = SquareFingerprintSpecimen.invented()
    private static let questionsAtMs = [9 * 60_000, 31 * 60_000]
    /// The specimen plays this many times faster than the meeting.
    private static let playbackSpeed = 20
    private static let tick = Duration.milliseconds(100)
    private static let transcribeSteps = 60

    @State private var playingMs: Int?
    @State private var transcribed: Double?

    var body: some View {
        let fingerprint = SquareFingerprintSpecimen.fingerprint
        SquareSpecimen {
            SquareSpecimenLine(name: "meeting page") {
                VStack(alignment: .leading, spacing: 8) {
                    SquareFingerprint(
                        content: transcribed.map { .transcribing($0) } ?? .done(fingerprint),
                        playingCell: playingMs.map(fingerprint.cell(atMs:)),
                        questionCells: Set(SquareFingerprintSpecimen.questionsAtMs.map(fingerprint.cell(atMs:))),
                        click: { playingMs = fingerprint.startMs(ofCell: $0) })
                    Text(Duration.milliseconds(fingerprint.durationMs).formatted(.units(allowed: [.minutes])))
                        .font(Square.mono(11))
                        .foregroundStyle(DesignTokens.Colors.ink2)
                    Button("transcribe") { transcribed = 0 }
                        .buttonStyle(SquareButtonStyle(small: true))
                        .disabled(transcribed != nil)
                }
            }
            SquareSpecimenLine(name: "meetings list") {
                SquareFingerprint(content: .done(fingerprint.folded()), cell: 2)
            }
            SquareSpecimenLine(name: "failed") {
                SquareFingerprint(content: .failed)
            }
        }
        .task(id: playingMs == nil) {
            while let ms = playingMs, !Task.isCancelled {
                try? await Task.sleep(for: SquareFingerprintSpecimen.tick)
                let next = ms + SquareFingerprintSpecimen.playbackSpeed * Int(SquareFingerprintSpecimen.tick / .milliseconds(1))
                playingMs = next < fingerprint.durationMs ? next : nil
            }
        }
        .task(id: transcribed == nil) {
            while let fraction = transcribed, !Task.isCancelled {
                try? await Task.sleep(for: SquareFingerprintSpecimen.tick)
                let next = fraction + 1 / Double(SquareFingerprintSpecimen.transcribeSteps)
                transcribed = next < 1 ? next : nil
            }
        }
    }

    /// A call of four invented people, built from a fixed seed so the
    /// specimen looks the same every time: turns of a few seconds to a
    /// minute, pauses between them, now and then an aside.
    private static func invented() -> MeetingFingerprint {
        let weights = [("s1", 5), ("you", 3), ("s2", 2), ("s3", 1)]
        var seed: UInt64 = 0x5EED
        func random(_ range: ClosedRange<Int>) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return range.lowerBound + Int((seed >> 33) % UInt64(range.count))
        }
        var turns: [MeetingFingerprint.Turn] = []
        var at = 2_000
        var last = ""
        while at < durationMs {
            var pick = random(1...weights.map(\.1).reduce(0, +))
            let speaker = weights.first { pick -= $0.1; return pick <= 0 }!.0
            guard speaker != last else { continue }
            let end = min(at + random(3_000...60_000), durationMs)
            turns.append(MeetingFingerprint.Turn(speaker: speaker, startMs: at, endMs: end, aside: false))
            if random(1...4) == 1, end - at > 10_000 {
                let asideAt = at + random(3_000...(end - at - 2_000))
                let by = weights.map(\.0).first { $0 != speaker }!
                turns.append(MeetingFingerprint.Turn(speaker: by, startMs: asideAt, endMs: asideAt + random(600...1_500), aside: true))
            }
            last = speaker
            at = end + random(0...4_000)
        }
        let voices = (["you"] + names.keys.sorted()).map { id in
            MeetingFingerprint.Voice(id: id, isYou: id == "you",
                                     talkMs: turns.filter { $0.speaker == id }.reduce(0) { $0 + $1.endMs - $1.startMs },
                                     name: id == "you" ? nil : names[id])
        }
        return MeetingFingerprint(durationMs: durationMs, voices: voices, turns: turns.sorted { $0.startMs < $1.startMs })!
    }
}

#Preview("fingerprint") { SquareFingerprintSpecimen() }
#endif
