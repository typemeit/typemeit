import AVFoundation
import Foundation
import Testing
@testable import TypeMeIt

struct MeetingTranscriberReadTests {
    private static let rate = Int(AudioCapture.targetFormat.sampleRate)

    /// A 16-bit CAF of `seconds` of sine in a fresh directory.
    private func track(seconds: Int, in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("mic.caf")
        let writer = try TrackWriter(url: url)
        writer.append((0..<(seconds * Self.rate)).map { Float(sin(Double($0) * 0.05)) * 0.3 })
        _ = writer.finish()
        return url
    }

    @Test func aChunkAcrossSecondBoundariesIsTheSameAsTheFileAtThatSpan() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try track(seconds: 3, in: dir)
        let whole = try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 0..<3000)

        let chunk = try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 500..<2300)

        #expect(chunk == Array(whole[(500 * Meeting.framesPerMs)..<(2300 * Meeting.framesPerMs)]))
    }

    @Test func aChunkPastTheEndStopsAtTheEnd() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try track(seconds: 2, in: dir)

        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 1500..<4000).count == 500 * Meeting.framesPerMs)
        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: url), range: 2000..<3000).isEmpty)
    }

    @Test func aKeptOpusTrackReadsWholeChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = try track(seconds: 3, in: dir)
        let kept = dir.appendingPathComponent("mic" + Meeting.keptAudioSuffix)
        #expect(try MeetingFolder.transcode(from: raw, to: kept))

        #expect(try MeetingTranscriber.read(AVAudioFile(forReading: kept), range: 500..<2500).count == 2000 * Meeting.framesPerMs)
    }
}
