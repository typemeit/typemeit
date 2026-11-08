import Testing
@testable import TypeMeIt

struct PuffPixelsTests {
    @Test func thePuffHasCellsAndNoneTwice() {
        let cells = PuffPixels.cells
        #expect(cells.count > 120)
        #expect(Set(cells).count == cells.count)
        #expect(cells.allSatisfy { (0..<PuffPixels.size).contains($0.column) && (0..<PuffPixels.size).contains($0.row) })
    }

    @Test func nothingLightsAtTheStartAndEverythingAtTheEnd() {
        #expect(PuffPixels.litCount(0) == 0)
        #expect(PuffPixels.litCount(-1) == 0)
        #expect(PuffPixels.litCount(1) == PuffPixels.cells.count)
        #expect(PuffPixels.litCount(2) == PuffPixels.cells.count)
    }

    @Test func halfwayLightsHalf() {
        let half = PuffPixels.litCount(0.5)
        #expect(abs(half - PuffPixels.cells.count / 2) <= 1)
    }

    /// Clockwise from twelve: the first cells sit on the top half, right of
    /// centre; the last ones on the top half, left of it.
    @Test func itFillsClockwiseFromTheTop() {
        let mid = PuffPixels.size / 2
        let first = PuffPixels.cells.prefix(5), last = PuffPixels.cells.suffix(5)
        #expect(first.allSatisfy { $0.row < mid && $0.column >= mid - 1 })
        #expect(last.allSatisfy { $0.row < mid && $0.column <= mid })
    }

    @Test func aPointOnTheOutlineIsOnIt() {
        // An endpoint of the outline in puff.svg.
        #expect(PuffPixels.distance(42.99, 43.81) < 0.01)
        #expect(PuffPixels.distance(32, 32) > 3)
    }
}
