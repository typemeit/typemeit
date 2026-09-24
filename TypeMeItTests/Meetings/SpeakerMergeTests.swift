import Testing
@testable import TypeMeIt

struct SpeakerMergeTests {
    private func segment(_ speaker: String, _ start: Int, _ end: Int) -> SpeakerSegment {
        SpeakerSegment(speaker: speaker, startMs: start, endMs: end)
    }

    @Test func aShortSpeakerJoinsTheNearestVoice() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 64_000), segment("C", 64_000, 120_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0.1, 1], "C": [0, 1]]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: embeddings, minimumMs: 10_000)
            == [segment("A", 0, 60_000), segment("C", 60_000, 64_000), segment("C", 64_000, 120_000)])
    }

    @Test func talkIsSummedAcrossSegmentsBeforeJudgingShort() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 66_000), segment("B", 70_000, 76_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0, 1]]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: embeddings, minimumMs: 10_000) == segments)
    }

    @Test func withoutAnEmbeddingTheShortSpeakerStays() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 64_000)]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: ["A": [1, 0]], minimumMs: 10_000) == segments)
    }

    @Test func whenEveryoneIsShortNobodyMoves() {
        let segments = [segment("A", 0, 4_000), segment("B", 4_000, 8_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0, 1]]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: embeddings, minimumMs: 10_000) == segments)
    }
}
