import Testing
@testable import TypeMeIt

struct ChunkCutterTests {
    @Test func emptyPeaksReturnsNoChunks() {
        #expect(ChunkCutter.cuts(peaks: [], frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300) == [])
    }

    @Test func trackShorterThanOneChunkReturnsOneRange() {
        let peaks = [Float](repeating: 1, count: 5) // 500 ms
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        #expect(cuts == [0..<500])
    }

    @Test func silenceEverywhereCutsAtTheMaximum() {
        let peaks = [Float](repeating: 0, count: 25) // 2500 ms
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        #expect(cuts.first == 0..<1000)
    }

    @Test func oneQuietFrameInTheSearchWindowIsChosen() {
        var peaks = [Float](repeating: 1, count: 25) // 2500 ms
        peaks[8] = 0 // 800 ms, inside the [700, 1000] window for the 1000 ms boundary
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        #expect(cuts.first == 0..<800)
    }

    @Test func overlapsAreExact() {
        let peaks = [Float](repeating: 0, count: 25) // 2500 ms, several chunks
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        #expect(cuts.count > 1)
        for i in 1..<cuts.count {
            #expect(cuts[i].lowerBound == cuts[i - 1].upperBound - 200)
        }
    }

    @Test func unionCoversTheWholeTrack() {
        let peaks = [Float](repeating: 0, count: 25) // 2500 ms
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        #expect(cuts.first?.lowerBound == 0)
        #expect(cuts.last?.upperBound == 2500)
        for i in 1..<cuts.count {
            #expect(cuts[i].lowerBound <= cuts[i - 1].upperBound)
        }
    }

    @Test func noChunkExceedsMaxChunkMs() {
        let peaks = [Float](repeating: 0, count: 37) // 3700 ms, an uneven remainder
        let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: 100, maxChunkMs: 1000, overlapMs: 200, searchMs: 300)
        for range in cuts {
            #expect(range.count <= 1000)
        }
    }
}
