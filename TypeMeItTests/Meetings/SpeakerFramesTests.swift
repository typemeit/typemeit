import Testing
@testable import TypeMeIt

struct SpeakerFramesTests {
    /// Frames of two slots, each pair one frame's probabilities.
    private func frames(_ pairs: [(Float, Float)]) -> [Float] { pairs.flatMap { [$0.0, $0.1] } }

    private func segments(_ pairs: [(Float, Float)], minimumMs: Int = 0) -> [SpeakerSegment] {
        SpeakerFrames.segments(probabilities: frames(pairs), speakers: 2, frameMs: 10, threshold: 0.5, minimumMs: minimumMs)
    }

    @Test func aRunOfFramesIsOneTurn() {
        #expect(segments([(0.9, 0), (0.9, 0), (0.9, 0)]) == [SpeakerSegment(speaker: "0", startMs: 0, endMs: 30)])
    }

    @Test func overlappingSpeechGoesToTheLikelierSlot() {
        #expect(segments([(0.9, 0), (0.7, 0.8), (0.9, 0.6)])
            == [SpeakerSegment(speaker: "0", startMs: 0, endMs: 10), SpeakerSegment(speaker: "1", startMs: 10, endMs: 20), SpeakerSegment(speaker: "0", startMs: 20, endMs: 30)])
    }

    @Test func framesAtOrUnderTheThresholdAreSilence() {
        #expect(segments([(0.5, 0.2), (0.9, 0), (0.1, 0.5)]) == [SpeakerSegment(speaker: "0", startMs: 10, endMs: 20)])
    }

    @Test func aTurnShorterThanTheMinimumIsDropped() {
        #expect(segments([(0.9, 0), (0.9, 0), (0.9, 0), (0, 0.9), (0.9, 0), (0.9, 0)], minimumMs: 20)
            == [SpeakerSegment(speaker: "0", startMs: 0, endMs: 30), SpeakerSegment(speaker: "0", startMs: 40, endMs: 60)])
    }

    @Test func aTurnRunningToTheLastFrameIsClosed() {
        #expect(segments([(0, 0), (0, 0.9)]) == [SpeakerSegment(speaker: "1", startMs: 10, endMs: 20)])
    }

    @Test func noFramesNoTurns() {
        #expect(segments([]).isEmpty)
    }
}
