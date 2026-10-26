import Foundation
import XCTest
@testable import TypeMeIt

/// Eight rows in the order the history lists them, newest first.
private let rows = (0..<8).map { _ in UUID() }

private func click(_ index: Int, extending: Bool = false, anchor: Int? = nil,
                   selected: [Int] = []) -> Set<Int> {
    var selection = ListSelection(picked: Set(selected.map { rows[$0] }), anchor: anchor.map { rows[$0] })
    selection.click(rows[index], extending: extending, in: rows)
    return Set(selection.picked.map { rows.firstIndex(of: $0)! })
}

final class ListSelectionTests: XCTestCase {
    /// The box clicked is what the next shift-click measures from.
    func testAClickMovesTheAnchorToItsRow() {
        var selection = ListSelection(picked: [rows[1]], anchor: rows[1])
        selection.click(rows[4], extending: false, in: rows)
        XCTAssertEqual(selection.anchor, rows[4])
        selection.click(rows[6], extending: true, in: rows)
        XCTAssertEqual(selection.picked, [rows[1], rows[4], rows[5], rows[6]])
        XCTAssertEqual(selection.anchor, rows[6])
    }

    func testPlainClickTurnsARowOnAndOffAgain() {
        XCTAssertEqual(click(3), [3])
        XCTAssertEqual(click(3, selected: [3]), [])
    }

    func testPlainClickLeavesTheRestOfTheSelectionAlone() {
        XCTAssertEqual(click(5, selected: [1, 2]), [1, 2, 5])
    }

    func testShiftTakesEveryRowDownToTheOneClicked() {
        XCTAssertEqual(click(4, extending: true, anchor: 1, selected: [1]), [1, 2, 3, 4])
    }

    /// The anchor can be below the row clicked; the range is the same either way.
    func testShiftTakesEveryRowUpToTheOneClicked() {
        XCTAssertEqual(click(1, extending: true, anchor: 4, selected: [4]), [1, 2, 3, 4])
    }

    func testShiftKeepsRowsSelectedOutsideTheRange() {
        XCTAssertEqual(click(3, extending: true, anchor: 2, selected: [2, 7]), [2, 3, 7])
    }

    /// Two runs gathered up before deleting: the first survives the second.
    func testASecondRangeAddsToTheFirst() {
        let first = click(2, extending: true, anchor: 0, selected: [0])
        XCTAssertEqual(first, [0, 1, 2])
        XCTAssertEqual(click(6, extending: true, anchor: 5, selected: Array(first)), [0, 1, 2, 5, 6])
    }

    /// Shift never clears: a row already taken by a range stays taken.
    func testShiftDoesNotTurnASelectedRowOff() {
        XCTAssertEqual(click(2, extending: true, anchor: 0, selected: [0, 1, 2]), [0, 1, 2])
    }

    func testShiftOnTheAnchorItselfKeepsIt() {
        XCTAssertEqual(click(3, extending: true, anchor: 3, selected: [3]), [3])
    }

    /// The first box clicked has nothing to measure a range from.
    func testShiftWithNoAnchorIsAPlainClick() {
        XCTAssertEqual(click(3, extending: true, anchor: nil), [3])
    }

    /// The search hid the anchor, or it was deleted. Nothing to measure from,
    /// so the click turns its own row on rather than reaching for a range.
    func testShiftWithAnAnchorThatIsNoLongerListedIsAPlainClick() {
        let gone = UUID()
        var selection = ListSelection(anchor: gone)
        selection.click(rows[3], extending: true, in: rows)
        XCTAssertEqual(selection.picked, [rows[3]])
    }
}

final class HistoryEntryDisplayTests: XCTestCase {
    private func entry(postProcessed: String?, typed: String?) -> HistoryEntry {
        HistoryEntry(timestamp: Date(), transcript: "a hundred and thirty four", postProcessed: postProcessed, postProcessRequested: true, typed: typed, dictionaryFixes: 0)
    }

    func testDisplayTextIsWhatWasTyped() {
        // The model fell back but the digits style still ran: the row shows the digits, not the words.
        XCTAssertEqual(entry(postProcessed: nil, typed: "134.").displayText, "134.")
        XCTAssertEqual(entry(postProcessed: "One hundred and thirty four.", typed: "134.").displayText, "134.")
    }

    func testEntriesFromBeforeTypedWasKeptShowTheModelOutput() {
        XCTAssertEqual(entry(postProcessed: "One hundred and thirty four.", typed: nil).displayText, "One hundred and thirty four.")
        XCTAssertEqual(entry(postProcessed: nil, typed: nil).displayText, "a hundred and thirty four")
    }
}
