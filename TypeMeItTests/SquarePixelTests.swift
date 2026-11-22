import CoreGraphics
import XCTest
@testable import TypeMeIt

final class SquarePixelTests: XCTestCase {
    func testLevelsStepEvenlyBothWays() {
        XCTAssertEqual((1...4).map { SquarePixel.level(from: 0, to: 16, step: $0) }, [4, 8, 12, 16])
        XCTAssertEqual((1...4).map { SquarePixel.level(from: 16, to: 0, step: $0) }, [12, 8, 4, 0])
    }

    /// A level a move was cut off at carries on to the end in the same four steps.
    func testALevelPartWayStillLandsOnTheEnd() {
        XCTAssertEqual(SquarePixel.level(from: 8, to: 0, step: 4), 0)
        XCTAssertEqual(SquarePixel.level(from: 8, to: 16, step: 4), 16)
    }

    func testRectsStepOnWholePoints() {
        let from = CGRect(x: 0, y: 0, width: 40, height: 22), to = CGRect(x: 47, y: 0, width: 61, height: 22)
        let mid = SquarePixel.rect(from: from, to: to, step: 2)
        XCTAssertEqual(mid, CGRect(x: 24, y: 0, width: 51, height: 22))
        XCTAssertEqual(SquarePixel.rect(from: from, to: to, step: 4), to)
    }

    func testDitherLevelsInkThatManyOfEachBlock() {
        for level in [0, 4, 8, 10, 16] {
            let inked = (0..<4).flatMap { row in (0..<4).map { (row, $0) } }
                .filter { SquarePixel.inked(column: $0.1, row: $0.0, level: level) }.count
            XCTAssertEqual(inked, level)
        }
    }

    func testASlabJumpLandsAndItsGhostFades() {
        var motion = SquareSlabMotion()
        let a = CGRect(x: 0, y: 0, width: 40, height: 22), b = CGRect(x: 60, y: 0, width: 40, height: 22)
        XCTAssertFalse(motion.start(to: a, reduceMotion: false), "nothing to jump from yet")
        XCTAssertEqual(motion.slab, a)
        XCTAssertTrue(motion.start(to: b, reduceMotion: false))
        XCTAssertEqual(motion.ghost, a)
        var frames = 1
        while motion.advance() { frames += 1 }
        XCTAssertEqual(motion.slab, b)
        XCTAssertEqual(motion.ghostLevel, 0)
        // Four steps to land; the ghost, from 10 at 2 a frame, lasts five.
        XCTAssertEqual(frames, 5)
    }

    func testReduceMotionJustMoves() {
        var motion = SquareSlabMotion()
        let a = CGRect(x: 0, y: 0, width: 40, height: 22), b = CGRect(x: 60, y: 0, width: 40, height: 22)
        motion.settle(at: a)
        XCTAssertFalse(motion.start(to: b, reduceMotion: true))
        XCTAssertEqual(motion.slab, b)
        XCTAssertNil(motion.ghost)
    }

    func testTheSlabCoversALabelByItsMiddle() {
        var motion = SquareSlabMotion()
        motion.settle(at: CGRect(x: 0, y: 0, width: 40, height: 22))
        XCTAssertEqual(motion.covers(CGRect(x: 10, y: 0, width: 20, height: 22)), true)
        XCTAssertEqual(motion.covers(CGRect(x: 30, y: 0, width: 30, height: 22)), false)
        XCTAssertNil(SquareSlabMotion().covers(CGRect(x: 0, y: 0, width: 10, height: 10)))
    }
}
