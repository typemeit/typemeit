import Foundation
import XCTest
@testable import TypeMeIt

/// The record of what produced an entry: Apple Intelligence's state and the
/// writing styles that were on. Both are new, so history.json written by an
/// older build has to keep loading.
final class HistoryEntryTests: XCTestCase {
    func testAnEntryWithoutTheCleanUpStateStillLoads() throws {
        let json = """
        [{"id":"EAE7E673-1585-4551-AB34-B77BAB303764","timestamp":781000000,"transcript":"work by nine AM",
          "postProcessed":"work by nine AM","postProcessRequested":true,"dictionaryFixes":0,"starred":false}]
        """
        let entry = try JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8))[0]
        XCTAssertNil(entry.modelState)
        XCTAssertNil(entry.styles)
        XCTAssertEqual(entry.displayText, "work by nine AM")
    }

    func testTheStateRoundTrips() throws {
        let entry = HistoryEntry(timestamp: Date(), transcript: "work by nine AM", postProcessed: "work by nine AM",
                                 postProcessRequested: true, modelState: "available", styles: [.digits, .quotes],
                                 typed: "work by 9am", dictionaryFixes: 0)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded, entry)
        XCTAssertEqual(decoded.styles, [.digits, .quotes])
        XCTAssertEqual(decoded.modelState, "available")
    }

    /// Clean-up off leaves no state to record; no styles on is an empty list,
    /// which is not the same as an entry that never recorded them.
    func testNoStylesIsNotTheSameAsNoRecord() throws {
        let entry = HistoryEntry(timestamp: Date(), transcript: "work by nine AM", postProcessRequested: false,
                                 styles: [], typed: "work by nine AM", dictionaryFixes: 0)
        let decoded = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(decoded.styles, [])
        XCTAssertNil(decoded.modelState)
    }
}
