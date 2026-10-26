import AVFoundation
import Foundation
import Testing
@testable import TypeMeIt

final class MeetingTranscriberReadTests {
    private let dir = tempDir()

    deinit { try? FileManager.default.removeItem(at: dir) }

    /// A 16-bit CAF of `seconds` of sine.
    private func track(seconds: Int) throws -> URL {
        let url = dir.appendingPathComponent("mic.caf")
        try writeTrack(sine(seconds: seconds), to: url)
        return url
    }

    @Test func aChunkAcrossSecondBoundariesIsTheSameAsTheFileAtThatSpan() throws {
        let url = try track(seconds: 3)
        let whole = try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 0..<3000)

        let chunk = try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 500..<2300)

        #expect(chunk == Array(whole[(500 * Meeting.framesPerMs)..<(2300 * Meeting.framesPerMs)]))
    }

    @Test func aChunkPastTheEndStopsAtTheEnd() throws {
        let url = try track(seconds: 2)

        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 1500..<4000).count == 500 * Meeting.framesPerMs)
        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 2000..<3000).isEmpty)
    }

    @Test func aKeptOpusTrackReadsWholeChunks() throws {
        let raw = try track(seconds: 3)
        let kept = dir.appendingPathComponent("mic" + Meeting.keptAudioSuffix)
        #expect(try MeetingFolder.transcode(from: raw, to: kept))

        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: kept), range: 500..<2500).count == 2000 * Meeting.framesPerMs)
    }
}
