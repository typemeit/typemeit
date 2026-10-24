import Foundation
import Testing
@testable import TypeMeIt

struct MeetingFolderFilingTests {
    /// A Meet code, the key a recurring call is matched on.
    private let standup = "abc-defg-hij"

    @Test func anOldMeetingJsonWithoutAFolderDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: MeetingFixtures.example.encoded()) as! [String: Any]
        json["folder"] = nil
        json["folderSuggestion"] = nil
        let decoded = try #require(Meeting.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(decoded.folder == nil)
        #expect(decoded.folderSuggestion == nil)
        #expect(decoded == MeetingFixtures.example)
    }

    @Test func aFolderRoundTrips() throws {
        var m = MeetingFixtures.example
        m.folder = "standups"
        m.folderSuggestion = "planning"
        #expect(Meeting.decode(try m.encoded()) == m)
    }

    @Test func aNewMeetingOnAFiledCallTakesItsFolderThoughItsTitleIsTheApps() {
        let new = MeetingFixtures.meeting(call: standup)
        let earlier = [MeetingFixtures.meeting("Sprint Standup Notes", hoursAgo: 24, folder: "standups", call: standup),
                       MeetingFixtures.meeting("Release Standup", hoursAgo: 48, folder: "old", call: standup)]
        #expect(Meeting.seriesFolder(for: new, among: earlier) == "standups")
    }

    @Test func anotherCallIsAnotherSeries() {
        let new = MeetingFixtures.meeting(call: standup)
        let earlier = [MeetingFixtures.meeting(hoursAgo: 24, folder: "standups", call: "xyz-wxyz-xyz")]
        #expect(Meeting.seriesFolder(for: new, among: earlier) == nil)
    }

    @Test func noCallKeyIsNoSeries() {
        let earlier = [MeetingFixtures.meeting(hoursAgo: 24, folder: "standups")]
        #expect(Meeting.seriesFolder(for: MeetingFixtures.meeting(), among: earlier) == nil)
        #expect(Meeting.seriesFolder(for: MeetingFixtures.meeting(call: standup), among: earlier) == nil)
    }

    @Test func theLatestEarlierMeetingOfTheCallInNoFolderFilesNothing() {
        let new = MeetingFixtures.meeting(call: standup)
        let earlier = [MeetingFixtures.meeting(hoursAgo: 24, call: standup), MeetingFixtures.meeting(hoursAgo: 48, folder: "standups", call: standup)]
        #expect(Meeting.seriesFolder(for: new, among: earlier) == nil)
    }

    @Test func anotherAppIsAnotherSeries() {
        let new = MeetingFixtures.meeting(call: standup)
        let earlier = [MeetingFixtures.meeting(hoursAgo: 24, folder: "standups", call: standup, app: Meeting.App(bundleId: "us.zoom.xos", name: "Zoom"))]
        #expect(Meeting.seriesFolder(for: new, among: earlier) == nil)
    }

    @Test func filingInAFolderOrNoneClearsTheSuggestion() {
        var m = MeetingFixtures.example
        m.folderSuggestion = "standups"
        let accepted = m.filed(in: "standups")
        #expect(accepted.folder == "standups")
        #expect(accepted.folderSuggestion == nil)
        let dismissed = m.filed(in: nil)
        #expect(dismissed.folder == nil)
        #expect(dismissed.folderSuggestion == nil)
    }

    @Test func aSuggestionIsOpenOnlyWhileInNoFolder() {
        var m = MeetingFixtures.example
        m.folderSuggestion = "standups"
        #expect(m.openFolderSuggestion == "standups")
        m.folder = "planning"
        #expect(m.openFolderSuggestion == nil)
    }

    @Test func aPassKeepsTheFolderAndSuggestionTheStoreHas() {
        var pass = MeetingFixtures.example
        pass.summary = "Written by the pass."
        pass.folderSuggestion = "old suggestion"
        var stored = MeetingFixtures.example
        stored.folder = "standups"
        stored.folderSuggestion = nil
        var expected = pass
        expected.folder = "standups"
        expected.folderSuggestion = nil
        #expect(MeetingTranscriber.keepingFiling(pass, from: stored) == expected)
    }

    @Test func aPassForAMeetingNoLongerStoredSavesItsOwnCopy() {
        var pass = MeetingFixtures.example
        pass.folder = "standups"
        #expect(MeetingTranscriber.keepingFiling(pass, from: nil) == pass)
    }

    @Test func aShareDoesNotCarryTheFolderOrSuggestion() throws {
        var m = MeetingFixtures.example
        m.folder = "standups"
        m.folderSuggestion = "planning"
        let received = try MeetingShare.meeting(from: MeetingShare.markdown(m, sender: "Max Mitchell"))
        #expect(received.folder == nil)
        #expect(received.folderSuggestion == nil)
        #expect(MeetingShare.markdown(m, sender: "Max Mitchell") == MeetingShare.markdown(MeetingFixtures.example, sender: "Max Mitchell"))
    }
}
