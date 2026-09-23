import XCTest
@testable import TypeMeIt

final class ClockTimeTests: XCTestCase {
    func testASpokenTimeIsWrittenInFigures() {
        XCTAssertEqual(ClockTime.apply("I just need to do some work by nine AM"), "I just need to do some work by 9am")
        XCTAssertEqual(ClockTime.apply("the standup moved to nine thirty a.m."), "the standup moved to 9:30am")
        XCTAssertEqual(ClockTime.apply("doors at seven pm, music at eight thirty pm"), "doors at 7pm, music at 8:30pm")
    }

    func testATimeAlreadyInFiguresLosesItsSpaceAndCapitals() {
        XCTAssertEqual(ClockTime.apply("the 7 PM train"), "the 7pm train")
        XCTAssertEqual(ClockTime.apply("it lands at 10:45 A.M. and leaves at 12 P.M."), "it lands at 10:45am and leaves at 12pm")
        XCTAssertEqual(ClockTime.apply("set it for 6AM"), "set it for 6am")
    }

    /// The dot of "a.m." is the abbreviation's, except where the sentence ends.
    func testTheSentenceKeepsItsFullStop() {
        XCTAssertEqual(ClockTime.apply("See you at eight a.m. Bring the notes."), "See you at 8am. Bring the notes.")
        XCTAssertEqual(ClockTime.apply("the eight a.m. one is full"), "the 8am one is full")
    }

    func testWordsThatOnlyLookLikeATimeAreLeftAlone() {
        XCTAssertEqual(ClockTime.apply("that leaves one, am I right"), "that leaves one, am I right")
        XCTAssertEqual(ClockTime.apply("we need three PMs on it"), "we need three PMs on it")
        XCTAssertEqual(ClockTime.apply("as a PM I am fine with the program"), "as a PM I am fine with the program")
        XCTAssertEqual(ClockTime.apply("there are twenty am I counting right"), "there are twenty am I counting right")
    }

    /// Whatever the writing styles say, a meridiem time is figures: the whole
    /// local pass runs on every dictation, with the styles off.
    func testTheLocalPassWritesTimesWithNoStylesOn() {
        XCTAssertEqual(LocalCleanup.run("Sorry, I um just need to do some work by nine AM"), "Sorry, I just need to do some work by 9am")
        XCTAssertEqual(WritingStyle.apply([], to: LocalCleanup.run("call me at five thirty pm")), "call me at 5:30pm")
    }
}
