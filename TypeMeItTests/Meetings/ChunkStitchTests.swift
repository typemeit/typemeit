import Testing
@testable import TypeMeIt

struct ChunkStitchTests {
    @Test func aRepeatedWordIsDropped() {
        let tail: [Transcriber.Word] = [.at("hello", 900, 1000)]
        let new: [Transcriber.Word] = [
            .at("hello", 1000, 1100),
            .at("world", 1200, 1300),
        ]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + [new[1]])
    }

    @Test func aDifferentWordAtTheSameTimeIsKept() {
        let tail: [Transcriber.Word] = [.at("hello", 900, 1000)]
        let new: [Transcriber.Word] = [.at("goodbye", 950, 1050)]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + new)
    }

    @Test func anEmptyTailReturnsNew() {
        let new: [Transcriber.Word] = [.at("hi", 0, 100)]
        #expect(ChunkStitch.append(new, after: [], overlapMs: 300) == new)
    }

    @Test func anOverlapWithNoWords() {
        let tail: [Transcriber.Word] = [.at("hi", 0, 100)]
        #expect(ChunkStitch.append([], after: tail, overlapMs: 300) == tail)
    }

    @Test func aWordOutsideTheOverlapIsNeverDroppedEvenIfTheTextRepeats() {
        let tail: [Transcriber.Word] = [.at("hello", 100, 200)]
        let new: [Transcriber.Word] = [.at("hello", 5000, 5100)]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + new)
    }
}
