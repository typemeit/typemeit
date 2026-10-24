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

    @Test func withoutAnEmbeddingTheShortSpeakerJoinsTheOneItBorders() {
        let segments = [segment("A", 0, 30_000), segment("B", 30_000, 31_000), segment("C", 50_000, 90_000)]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: ["A": [1, 0], "C": [0, 1]], minimumMs: 10_000)
            == [segment("A", 0, 30_000), segment("A", 30_000, 31_000), segment("C", 50_000, 90_000)])
    }

    @Test func cappingFoldsTheQuietestIntoTheNearestVoice() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("C", 90_000, 110_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0, 1], "C": [0.9, 0.1]]
        #expect(SpeakerMerge.capped(segments, embeddings: embeddings, maximum: 2)
            == [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("A", 90_000, 110_000)])
    }

    @Test func cappingRepeatsUntilTheCountFits() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("C", 90_000, 110_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0, 1], "C": [0.9, 0.1]]
        #expect(Set(SpeakerMerge.capped(segments, embeddings: embeddings, maximum: 1).map(\.speaker)) == ["A"])
    }

    @Test func twoUnlikeVoicesOnOneTileStayTwo() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("C", 90_000, 110_000)]
        let tiles = ["A": "Ana", "B": "Ben", "C": "Ben"]
        let voices: [String: [[Float]]] = ["A": [[1, 0]], "B": [[0, 1]], "C": [[1, 0.1]]]
        #expect(SpeakerMerge.capped(segments, embeddings: [:], maximum: 2, tiles: tiles, voices: voices, distinct: 0.6) == segments)
    }

    @Test func twoLikeVoicesOnOneTileFold() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("C", 90_000, 110_000)]
        let tiles = ["A": "Ana", "B": "Ben", "C": "Ben"]
        let voices: [String: [[Float]]] = ["A": [[1, 0]], "B": [[0, 1]], "C": [[0.3, 1]]]
        #expect(SpeakerMerge.capped(segments, embeddings: [:], maximum: 2, tiles: tiles, voices: voices, distinct: 0.6)
            == [segment("A", 0, 60_000), segment("B", 60_000, 90_000), segment("B", 90_000, 110_000)])
    }

    @Test func aVoiceNeverFoldsIntoAnotherTile() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0.9, 0.1]]
        #expect(SpeakerMerge.capped(segments, embeddings: embeddings, maximum: 1, tiles: ["A": "Ana", "B": "Ben"]) == segments)
    }

    @Test func aTileIsTheNameOverMoreThanHalfTheTalk() {
        let segments = [segment("A", 0, 10_000), segment("B", 10_000, 20_000)]
        let spans = [MeetingNames.Span(name: "Ana", startMs: 0, endMs: 8_000), MeetingNames.Span(name: "Ben", startMs: 8_000, endMs: 15_000),
                     MeetingNames.Span(name: "Cy", startMs: 15_000, endMs: 20_000)]
        #expect(SpeakerMerge.tiles(of: segments, spans: spans) == ["A": "Ana"])
    }

    @Test func meanDistanceAveragesEveryPair() {
        #expect(SpeakerMerge.meanDistance([[1, 0], [0, 1]], [[1, 0]]) == 0.5)
    }

    @Test func underTheCapNobodyMoves() {
        let segments = [segment("A", 0, 60_000), segment("B", 60_000, 90_000)]
        #expect(SpeakerMerge.capped(segments, embeddings: [:], maximum: 3) == segments)
    }

    @Test func whenEveryoneIsShortNobodyMoves() {
        let segments = [segment("A", 0, 4_000), segment("B", 4_000, 8_000)]
        let embeddings: [String: [Float]] = ["A": [1, 0], "B": [0, 1]]
        #expect(SpeakerMerge.absorbingShort(segments, embeddings: embeddings, minimumMs: 10_000) == segments)
    }
}
