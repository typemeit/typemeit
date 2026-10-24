import AVFoundation
import Foundation
import Testing
@testable import TypeMeIt

struct MeetingMergeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let window: TimeInterval = 15 * 60

    /// A Slack call starting `atSeconds` after `t0`, lasting `seconds`, done, with kept audio.
    private func call(_ atSeconds: TimeInterval, seconds: Int, app: String = "com.tinyspeck.slackmacgap", call key: String? = nil) -> Meeting {
        var m = MeetingFixtures.example
        m.id = UUID()
        m.started = t0.addingTimeInterval(atSeconds)
        m.durationMs = seconds * 1000
        m.recordedMs = seconds * 1000
        m.ended = m.started.addingTimeInterval(TimeInterval(seconds))
        m.app = Meeting.App(bundleId: app, name: "Slack")
        m.tracks = m.tracks.map { var t = $0; t.frames = seconds * 1000 * Meeting.framesPerMs; t.gaps = []; return t }
        m.dictations = []
        m.names = key.map { MeetingNames(source: .roster, roster: ["Ana"], channel: nil, spans: [], captions: nil, call: $0) }
        return m
    }

    @Test func aRejoinMinutesLaterContinuesTheCall() {
        let earlier = call(0, seconds: 600)
        let later = call(600 + 120, seconds: 300)
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window)?.id == earlier.id)
    }

    @Test func aCallAfterTheWindowStandsAlone() {
        let earlier = call(0, seconds: 600)
        let later = call(600 + 16 * 60, seconds: 300)
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window) == nil)
    }

    @Test func anotherAppStandsAlone() {
        let earlier = call(0, seconds: 600, app: "com.google.Chrome")
        let later = call(660, seconds: 300)
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window) == nil)
    }

    @Test func twoCallKeysThatDifferStandAlone() {
        let earlier = call(0, seconds: 600, call: "abc-defg-hij")
        let later = call(660, seconds: 300, call: "xyz-wxyz-xyz")
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window) == nil)
    }

    @Test func aCallKeyOnOneSideOnlyStillJoins() {
        let earlier = call(0, seconds: 600, call: "abc-defg-hij")
        let later = call(660, seconds: 300)
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window)?.id == earlier.id)
    }

    @Test func aMeetingWhoseAudioWasNotKeptCannotBeJoined() {
        var earlier = call(0, seconds: 600)
        earlier.tracks = earlier.tracks.map { var t = $0; t.file = "mic.caf"; return t }
        let later = call(660, seconds: 300)
        #expect(MeetingMerge.previous(of: later, among: [earlier, later], window: window) == nil)
    }

    @Test func theJoinedMeetingPutsTheLaterOneAfterTheGap() {
        let earlier = call(0, seconds: 600)
        var later = call(660, seconds: 300, call: "abc-defg-hij")
        later.dictations = [Meeting.Dictation(startMs: 1000, endMs: 2000, historyId: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!)]
        later.names?.spans = [MeetingNames.Span(name: "Ana", startMs: 5000, endMs: 9000)]
        let joined = MeetingMerge.joined(earlier, later, gapMs: MeetingMerge.gapMs(earlier, later))

        #expect(joined.id == earlier.id)
        #expect(joined.durationMs == 960_000)
        #expect(joined.recordedMs == 900_000)
        #expect(joined.tracks.map(\.file) == ["mic.caf", "others.caf"])
        #expect(joined.tracks[0].gaps == [Meeting.Span(startMs: 600_000, endMs: 660_000)])
        #expect(joined.dictations.map(\.startMs) == [661_000])
        #expect(joined.names?.spans == [MeetingNames.Span(name: "Ana", startMs: 665_000, endMs: 669_000)])
        #expect(joined.names?.call == "abc-defg-hij")
        #expect(joined.transcription.state == .pending)
        #expect(joined.paragraphs.isEmpty)
    }

    @Test func theAudioJoinsWithSilenceBetween() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let a = dir.appendingPathComponent("a", isDirectory: true), b = dir.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ url: URL, value: Float, ms: Int) throws {
            let w = try TrackWriter(url: url)
            w.append([Float](repeating: value, count: ms * Meeting.framesPerMs))
            _ = w.finish()
        }
        var earlier = call(0, seconds: 1)
        earlier.durationMs = 1000
        earlier.tracks = [Meeting.Track(role: .mic, file: "mic.caf", frames: 1000 * Meeting.framesPerMs)]
        var later = call(1.5, seconds: 1)
        later.durationMs = 1000
        later.tracks = [Meeting.Track(role: .mic, file: "mic.caf", frames: 1000 * Meeting.framesPerMs)]
        try write(a.appendingPathComponent("mic.caf"), value: 0.5, ms: 1000)
        try write(b.appendingPathComponent("mic.caf"), value: -0.5, ms: 1000)

        let written = try MeetingMerge.joinAudio(earlier, in: a, later, in: b, gapMs: 500)
        #expect(written[.mic]?.frames == 2500 * Meeting.framesPerMs)

        let file = try AVAudioFile(forReading: a.appendingPathComponent("mic.caf"))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let at = { (ms: Int) in pcm[ms * Meeting.framesPerMs] }
        #expect(abs(at(999) - 0.5) < 0.001)
        #expect(at(1250) == 0)
        #expect(abs(at(1500) + 0.5) < 0.001)
        #expect(!FileManager.default.fileExists(atPath: a.appendingPathComponent("mic.merged.caf").path))
    }
}
