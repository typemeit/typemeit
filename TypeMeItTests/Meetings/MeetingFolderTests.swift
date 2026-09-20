import Foundation
import Testing
@testable import TypeMeIt

struct MeetingFolderTests {
    private static let utc = TimeZone(identifier: "UTC")!
    // 2026-01-15T12:00:00Z, chosen so London and New York land on clean
    // clock times without daylight saving in play.
    private static let jan15Noon = Date(timeIntervalSince1970: 1_768_478_400)

    // MARK: durationLabel

    @Test func durationLabelRoundsToTheNearestMinute() {
        #expect(MeetingFolder.durationLabel(.seconds(480)) == "8m")
        #expect(MeetingFolder.durationLabel(.seconds(2_700)) == "45m")
        #expect(MeetingFolder.durationLabel(.seconds(4_800)) == "1h20m")
    }

    @Test func durationLabelUnderAMinuteIsZero() {
        #expect(MeetingFolder.durationLabel(.seconds(30)) == "0m")
        #expect(MeetingFolder.durationLabel(.seconds(59)) == "0m")
        #expect(MeetingFolder.durationLabel(.seconds(60)) == "1m")
    }

    // MARK: sanitised

    @Test func sanitisedReplacesSlashAndColon() {
        #expect(MeetingFolder.sanitised("Q3/Recap:notes") == "Q3-Recap-notes")
    }

    @Test func sanitisedCollapsesNewlinesAndWhitespace() {
        #expect(MeetingFolder.sanitised("Standup\n\nnotes   today") == "Standup notes today")
    }

    @Test func sanitisedKeepsEmojiAndHash() {
        #expect(MeetingFolder.sanitised("Standup 🎉 #retro") == "Standup 🎉 #retro")
    }

    @Test func sanitisedStripsLeadingDots() {
        #expect(MeetingFolder.sanitised("..hidden title") == "hidden title")
    }

    // MARK: name

    @Test func nameWithNoDuration() {
        let name = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Standup", existing: [])
        #expect(name == "2026-01-15 1200 Standup")
    }

    @Test func nameWithADuration() {
        let name = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: .seconds(480), title: "Standup", existing: [])
        #expect(name == "2026-01-15 1200 8m Standup")
    }

    @Test func nameCapsAtTheByteLimitOnAGraphemeBoundary() {
        let title = String(repeating: "😀", count: 50)
        let name = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: title, existing: [])
        let expected = "2026-01-15 1200 " + String(repeating: "😀", count: 46)
        #expect(name.utf8.count <= Fixed.meetingFolderNameMax)
        #expect(name == expected)
    }

    @Test func sameMinuteCollisionAppendsAnIncrementingSuffix() {
        let first = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Standup", existing: [])
        let second = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Standup", existing: [first])
        let third = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Standup", existing: [first, second])
        #expect(first == "2026-01-15 1200 Standup")
        #expect(second == "2026-01-15 1200 Standup 2")
        #expect(third == "2026-01-15 1200 Standup 3")
    }

    @Test func collisionIsCaseFolded() {
        let name = MeetingFolder.name(
            started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Standup",
            existing: ["2026-01-15 1200 standup"])
        #expect(name == "2026-01-15 1200 Standup 2")
    }

    @Test func collisionFoldsDecomposedAgainstPrecomposedAccents() {
        // "Café" written with a combining acute accent (e + U+0301) instead
        // of the precomposed U+00E9.
        let decomposedTitle = "Cafe\u{0301}"
        let name = MeetingFolder.name(
            started: Self.jan15Noon, zone: Self.utc, duration: nil, title: decomposedTitle,
            existing: ["2026-01-15 1200 Café"])
        #expect(name == "2026-01-15 1200 Café 2")
    }

    @Test func timeZoneChangesTheHHMMPart() {
        let london = MeetingFolder.name(
            started: Self.jan15Noon, zone: TimeZone(identifier: "Europe/London")!,
            duration: nil, title: "Standup", existing: [])
        let newYork = MeetingFolder.name(
            started: Self.jan15Noon, zone: TimeZone(identifier: "America/New_York")!,
            duration: nil, title: "Standup", existing: [])
        #expect(london == "2026-01-15 1200 Standup")
        #expect(newYork == "2026-01-15 0700 Standup")
    }

    @Test func titlePartRoundTrips() {
        let withoutDuration = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: nil, title: "Deploy sync", existing: [])
        #expect(MeetingFolder.titlePart(of: withoutDuration) == "Deploy sync")

        let withDuration = MeetingFolder.name(started: Self.jan15Noon, zone: Self.utc, duration: .seconds(480), title: "Standup", existing: [])
        #expect(MeetingFolder.titlePart(of: withDuration) == "Standup")
    }
}
