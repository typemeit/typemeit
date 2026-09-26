import Testing
@testable import TypeMeIt

struct AudioRingTests {
    @Test func readAfterWriteReturnsTheSameSamples() {
        let ring = AudioRing(capacity: 16)
        let samples: [Float] = [1, 2, 3, 4, 5]
        ring.write(samples)
        var out: [Float] = []
        #expect(ring.read(into: &out) == 5)
        #expect(out == samples)
    }

    @Test func writesWrapAroundTheEndOfStorageAndReadBackInOrder() {
        let ring = AudioRing(capacity: 10)
        ring.write([0, 1, 2, 3, 4, 5])
        var first: [Float] = []
        #expect(ring.read(into: &first) == 6)
        #expect(first == [0, 1, 2, 3, 4, 5])

        // Head is now at 6; this write spans indices 6..9 then wraps to 0..3.
        ring.write([6, 7, 8, 9, 10, 11, 12, 13])
        var second: [Float] = []
        #expect(ring.read(into: &second) == 8)
        #expect(second == [6, 7, 8, 9, 10, 11, 12, 13])
    }

    @Test func overrunDropsAndCounts() {
        let ring = AudioRing(capacity: 100)
        let samples = [Float](repeating: 1, count: 105)
        ring.write(samples)
        #expect(ring.available == 100)
        #expect(ring.overruns == 5)
    }

    @Test func readOnAnEmptyRingReturnsZero() {
        let ring = AudioRing(capacity: 8)
        var out: [Float] = []
        #expect(ring.read(into: &out) == 0)
        #expect(out.isEmpty)
    }
}
