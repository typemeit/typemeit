import Testing
@testable import TypeMeIt

struct PreRollTests {
    @Test func aWrappedRingYieldsTheNewestOldestFirst() {
        var ring = PreRollRing(capacity: 4)
        ring.append([1, 2, 3])
        ring.append([4, 5, 6])
        #expect(ring.contents == [3, 4, 5, 6])
        #expect(ring.total == 6)
    }

    @Test func aShortPreRollYieldsWhatWasHeld() {
        var ring = PreRollRing(capacity: 10)
        ring.append([1, 2, 3])
        #expect(ring.contents == [1, 2, 3])
    }

    @Test func anAppendLongerThanTheRingKeepsItsTail() {
        var ring = PreRollRing(capacity: 3)
        ring.append([1, 2, 3, 4, 5])
        #expect(ring.contents == [3, 4, 5])
        #expect(ring.total == 5)
    }

    @Test func discardLeavesNothingReadable() {
        var ring = PreRollRing(capacity: 4)
        ring.append([1, 2, 3, 4, 5])
        ring.discard()
        #expect(ring.contents == [])
        ring.append([9])
        #expect(ring.contents == [9])
    }

    @Test func zerosCountTowardTheTotal() {
        var ring = PreRollRing(capacity: 2)
        ring.appendZeros(5)
        #expect(ring.contents == [0, 0])
        #expect(ring.total == 5)
    }
}
