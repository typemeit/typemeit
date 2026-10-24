import Testing
@testable import TypeMeIt

struct AudioRingTests {
    @Test func readAfterWriteReturnsTheSameSamples() {
        let ring = AudioRing(frames: 16, channels: 1)
        let samples: [Float] = [1, 2, 3, 4, 5]
        ring.write(samples)
        var out: [Float] = []
        var unused: [Float] = []
        #expect(ring.read(into: &out, &unused) == 5)
        #expect(out == samples)
        #expect(unused.isEmpty)
    }

    @Test func writesWrapAroundTheEndOfStorageAndReadBackInOrder() {
        let ring = AudioRing(frames: 10, channels: 2)
        ring.write([0, 1, 2, 3, 4, 5], [10, 11, 12, 13, 14, 15])
        var mic: [Float] = []
        var others: [Float] = []
        #expect(ring.read(into: &mic, &others) == 6)
        #expect(mic == [0, 1, 2, 3, 4, 5])
        #expect(others == [10, 11, 12, 13, 14, 15])

        // Head is now at frame 6; this write spans frames 6..9 then wraps to 0..3.
        ring.write([6, 7, 8, 9, 10, 11, 12, 13], [16, 17, 18, 19, 20, 21, 22, 23])
        mic = []
        others = []
        #expect(ring.read(into: &mic, &others) == 8)
        #expect(mic == [6, 7, 8, 9, 10, 11, 12, 13])
        #expect(others == [16, 17, 18, 19, 20, 21, 22, 23])
    }

    @Test func theShorterChannelIsPaddedWithZeros() {
        let ring = AudioRing(frames: 16, channels: 2)
        ring.write([1, 2], [3, 4, 5, 6])
        ring.write([7, 8, 9], [])
        var mic: [Float] = []
        var others: [Float] = []
        #expect(ring.read(into: &mic, &others) == 7)
        #expect(mic == [1, 2, 0, 0, 7, 8, 9])
        #expect(others == [3, 4, 5, 6, 0, 0, 0])
    }

    @Test func anOverrunDropsTheSameFramesFromBothChannels() {
        let ring = AudioRing(frames: 4, channels: 2)
        ring.write([1, 2, 3], [11, 12, 13])
        ring.write([4, 5, 6], [14, 15, 16])
        #expect(ring.overruns == 2)
        var mic: [Float] = []
        var others: [Float] = []
        #expect(ring.read(into: &mic, &others) == 4)
        ring.write([7], [17])
        #expect(ring.read(into: &mic, &others) == 1)
        #expect(mic == [1, 2, 3, 4, 7])
        #expect(others == [11, 12, 13, 14, 17])
    }

    @Test func overrunDropsAndCounts() {
        let ring = AudioRing(frames: 100, channels: 1)
        ring.write([Float](repeating: 1, count: 105))
        #expect(ring.available == 100)
        #expect(ring.overruns == 5)
    }

    @Test func readOnAnEmptyRingReturnsZero() {
        let ring = AudioRing(frames: 8, channels: 2)
        var mic: [Float] = []
        var others: [Float] = []
        #expect(ring.read(into: &mic, &others) == 0)
        #expect(mic.isEmpty)
        #expect(others.isEmpty)
    }
}
