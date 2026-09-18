import XCTest
@testable import TypeMeIt

final class MeetingMicTests: XCTestCase {
    func testMeetingApps() {
        XCTAssertTrue(MeetingMic.isMeetingApp("us.zoom.xos"))
        XCTAssertTrue(MeetingMic.isMeetingApp("com.microsoft.teams2"))
        XCTAssertTrue(MeetingMic.isMeetingApp("com.tinyspeck.slackmacgap"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(MeetingMic.isMeetingApp("com.apple.FaceTime"))
        XCTAssertTrue(MeetingMic.isMeetingApp("com.hnc.Discord"))
    }

    func testBrowsersAndOurselvesAreNotMeetings() {
        XCTAssertFalse(MeetingMic.isMeetingApp("com.google.Chrome"))
        XCTAssertFalse(MeetingMic.isMeetingApp("com.apple.Safari"))
        XCTAssertFalse(MeetingMic.isMeetingApp("it.typeme.typemeit"))
        XCTAssertFalse(MeetingMic.isMeetingApp(""))
    }
}
