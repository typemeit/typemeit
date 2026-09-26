import Foundation
import Testing
@testable import TypeMeIt

struct MeetingCodableTests {
    private static let roomVariant = Meeting(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
        kind: .room,
        started: Date(timeIntervalSince1970: 1_789_824_612),
        timeZone: "Europe/London",
        ended: Date(timeIntervalSince1970: 1_789_826_688),
        durationMs: 2_076_000,
        recordedMs: 2_076_000,
        firstHostTime: nil,
        app: nil,
        title: "Room 3.02",
        titleSource: .generated,
        published: false,
        tracks: [Meeting.Track(role: .room, file: "room.caf", frames: 2_076_000 * Meeting.framesPerMs)],
        audio: nil,
        echo: .notMeasured,
        bothSilentMs: 0,
        dictations: [],
        speakers: [Meeting.Speaker(id: "room", name: "Room", isYou: false, talkMs: 0)],
        transcription: Meeting.Transcription(state: .pending, error: nil, asr: nil, diarizer: nil, tookMs: nil, done: [:]),
        paragraphs: [])

    @Test func theExampleMeetingRoundTrips() throws {
        let data = try MeetingFixtures.example.encoded()
        #expect(Meeting.decode(data) == MeetingFixtures.example)
    }

    @Test func aRoomVariantRoundTrips() throws {
        let data = try Self.roomVariant.encoded()
        #expect(Meeting.decode(data) == Self.roomVariant)
    }

    @Test func unknownTopLevelKeysAreIgnored() throws {
        let data = try MeetingFixtures.example.encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["future"] = 1
        let withExtraKey = try JSONSerialization.data(withJSONObject: object)
        #expect(Meeting.decode(withExtraKey) == MeetingFixtures.example)
    }

    @Test func decodeReturnsNilForANewerSchema() throws {
        let data = try MeetingFixtures.example.encoded()
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schema"] = 2
        let newerSchema = try JSONSerialization.data(withJSONObject: object)
        #expect(Meeting.decode(newerSchema) == nil)
    }

    @Test func framesMatchDurationTimesFramesPerMs() {
        for track in MeetingFixtures.example.tracks {
            #expect(track.frames == MeetingFixtures.example.durationMs * Meeting.framesPerMs)
        }
    }
}
