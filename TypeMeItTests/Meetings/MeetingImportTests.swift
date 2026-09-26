import AVFoundation
import CoreAudio
import CoreMedia
import Testing
@testable import TypeMeIt

private struct FixtureError: Error {}

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: Fixtures

/// A short mono tone, written as AAC in an `.m4a` container: the path
/// `AVAudioFile` reads directly.
private func writeMonoM4A(to url: URL, seconds: Double, sampleRate: Double = 44_100, frequency: Double = 440) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frameCount = AVAudioFrameCount(seconds * sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { throw FixtureError() }
    buffer.frameLength = frameCount
    let data = buffer.floatChannelData![0]
    for i in 0..<Int(frameCount) {
        data[i] = 0.4 * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
    }
    try file.write(from: buffer)
}

/// A stereo `.m4a`: a tone on the left channel for the first half, on the
/// right channel for the second half, silence elsewhere.
private func writeStereoM4A(to url: URL, seconds: Double, sampleRate: Double = 44_100, frequency: Double = 440) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let frameCount = Int(seconds * sampleRate)
    let half = frameCount / 2
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { throw FixtureError() }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let left = buffer.floatChannelData![0]
    let right = buffer.floatChannelData![1]
    for i in 0..<frameCount {
        let tone = 0.4 * Float(sin(2 * Double.pi * frequency * Double(i) / sampleRate))
        left[i] = i < half ? tone : 0
        right[i] = i >= half ? tone : 0
    }
    try file.write(from: buffer)
}

/// A raw LPCM `CMSampleBuffer` for one chunk of `pcm`, starting at frame
/// `startFrame`, so `writeAudioMP4` can feed `AVAssetWriterInput` without a
/// second, pre-encoded file.
private func lpcmSampleBuffer(pcm: [Float], sampleRate: Double, startFrame: Int, formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
    let byteCount = pcm.count * MemoryLayout<Float>.size
    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
    guard status == noErr, let blockBuffer else { throw FixtureError() }
    status = pcm.withUnsafeBufferPointer { pointer in
        CMBlockBufferReplaceDataBytes(with: pointer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
    }
    guard status == noErr else { throw FixtureError() }

    let timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: Int32(sampleRate)),
        presentationTimeStamp: CMTime(value: CMTimeValue(startFrame), timescale: Int32(sampleRate)),
        decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
        sampleCount: pcm.count, sampleTimingEntryCount: 1, sampleTimingArray: [timing],
        sampleSizeEntryCount: 1, sampleSizeArray: [MemoryLayout<Float>.size], sampleBufferOut: &sampleBuffer)
    guard status == noErr, let sampleBuffer else { throw FixtureError() }
    return sampleBuffer
}

/// An `.mp4` with one AAC audio track, built with `AVAssetWriter` fed raw
/// LPCM sample buffers it compresses on the way in: the container
/// `AVAudioFile` refuses, so importing it exercises the `AVAssetReader`
/// fallback (docs/meetings.md 7.14).
private func writeAudioMP4(to url: URL, seconds: Double, sampleRate: Double = 44_100, frequency: Double = 440) throws {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var formatDescription: CMFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
        magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
    guard status == noErr, let formatDescription else { throw FixtureError() }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let aacSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000,
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings, sourceFormatHint: formatDescription)
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { throw FixtureError() }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? FixtureError() }
    writer.startSession(atSourceTime: .zero)

    let totalFrames = Int(seconds * sampleRate)
    let chunkFrames = Int(sampleRate)
    var written = 0
    while written < totalFrames {
        let count = min(chunkFrames, totalFrames - written)
        var pcm = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let sampleIndex = written + i
            pcm[i] = 0.4 * Float(sin(2 * Double.pi * frequency * Double(sampleIndex) / sampleRate))
        }
        let sampleBuffer = try lpcmSampleBuffer(pcm: pcm, sampleRate: sampleRate, startFrame: written, formatDescription: formatDescription)
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        input.append(sampleBuffer)
        written += count
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else { throw writer.error ?? FixtureError() }
}

/// An `.mp4` with a video track and no audio track at all, built with
/// `AVAssetWriter` and a `CVPixelBuffer` per frame.
private func writeVideoOnlyMP4(to url: URL, seconds: Double = 1) throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 32,
        AVVideoHeightKey: 32,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 32,
        kCVPixelBufferHeightKey as String: 32,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    guard writer.canAdd(input) else { throw FixtureError() }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? FixtureError() }
    writer.startSession(atSourceTime: .zero)

    let fps = 10
    let frameCount = Int(seconds * Double(fps))
    for frame in 0..<frameCount {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var pixelBufferOut: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool else { throw FixtureError() }
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard let pixelBuffer = pixelBufferOut else { throw FixtureError() }
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else { throw writer.error ?? FixtureError() }
}

/// The loudest sample in each half of `url`'s (mono) audio.
private func halfPeaks(of url: URL) throws -> (first: Float, second: Float) {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw FixtureError() }
    try file.read(into: buffer)
    let count = Int(buffer.frameLength)
    let data = buffer.floatChannelData![0]
    let half = count / 2
    var first: Float = 0
    var second: Float = 0
    for i in 0..<half { first = max(first, abs(data[i])) }
    for i in half..<count { second = max(second, abs(data[i])) }
    return (first, second)
}

struct MeetingImportTests {
    /// The tolerance the spec allows: block-based conversion can end a
    /// partial block short by up to one block at the target rate.
    private static let oneConverterBlock = Int(AudioCapture.targetFormat.sampleRate)

    @Test func aMonoM4AImportsToARoomMeeting() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Standup.m4a")
        try writeMonoM4A(to: source, seconds: 2)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)

        let (meeting, folder) = try await MeetingImport.run(url: source, staging: staging)

        #expect(meeting.kind == .room)
        #expect(meeting.title == "Standup")
        #expect(meeting.titleSource == .app)
        #expect(meeting.source == .imported)
        #expect(meeting.importedFrom == "Standup.m4a")
        #expect(meeting.published == false)
        #expect(meeting.echo == .notMeasured)
        #expect(meeting.transcription.state == .pending)
        #expect(meeting.speakers == [Meeting.Speaker(id: Meeting.Speaker.room, name: "Room", isYou: false, talkMs: 0)])
        #expect(meeting.tracks.count == 1)
        let track = try #require(meeting.tracks.first)
        #expect(track.role == .room)
        #expect(track.file == "room.caf")
        let expectedFrames = Int(2 * AudioCapture.targetFormat.sampleRate)
        #expect(abs(track.frames - expectedFrames) <= Self.oneConverterBlock)
        #expect(meeting.durationMs == track.frames / Meeting.framesPerMs)
        #expect(meeting.recordedMs == meeting.durationMs)
        #expect(meeting.ended == meeting.started.addingTimeInterval(TimeInterval(meeting.durationMs) / 1000))

        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("room.caf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingFolder.meetingFile).path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(MeetingFolder.transcriptFile).path))
        // `started`/`ended` round-trip through ISO 8601 seconds, so they can
        // lose the sub-second component `Date()` carried; every other field
        // is checked for an exact match.
        let reread = try #require(MeetingFolder.read(folder))
        #expect(reread.id == meeting.id)
        #expect(reread.kind == meeting.kind)
        #expect(reread.title == meeting.title)
        #expect(reread.tracks == meeting.tracks)
        #expect(reread.speakers == meeting.speakers)
        #expect(reread.transcription == meeting.transcription)
        #expect(reread.source == meeting.source)
        #expect(reread.importedFrom == meeting.importedFrom)
    }

    @Test func anMP4WithOneAudioTrackFallsBackToAssetReader() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("call.mp4")
        try writeAudioMP4(to: source, seconds: 2)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)

        let (meeting, folder) = try await MeetingImport.run(url: source, staging: staging)

        #expect(meeting.kind == .room)
        #expect(meeting.title == "call")
        #expect(meeting.source == .imported)
        #expect(meeting.importedFrom == "call.mp4")
        let track = try #require(meeting.tracks.first)
        let expectedFrames = Int(2 * AudioCapture.targetFormat.sampleRate)
        #expect(abs(track.frames - expectedFrames) <= Self.oneConverterBlock)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("room.caf").path))
    }

    @Test func aStereoFileMixesBothChannelsIntoTheMonoTrack() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("stereo.m4a")
        try writeStereoM4A(to: source, seconds: 2)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)

        let (_, folder) = try await MeetingImport.run(url: source, staging: staging)

        let peaks = try halfPeaks(of: folder.appendingPathComponent("room.caf"))
        #expect(peaks.first > 0.05)
        #expect(peaks.second > 0.05)
    }

    @Test func aFileWithNoAudioTrackThrowsNoAudio() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("silent.mp4")
        try writeVideoOnlyMP4(to: source, seconds: 1)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)

        do {
            _ = try await MeetingImport.run(url: source, staging: staging)
            Issue.record("expected MeetingImport.Error.noAudio")
        } catch let error as MeetingImport.Error {
            #expect(error == .noAudio)
            #expect(error.errorDescription == "no audio in that file")
        }
    }

    @Test func aBasenameThatNeedsSanitisingBecomesTheTitle() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Team: sync.m4a")
        try writeMonoM4A(to: source, seconds: 1)
        let staging = dir.appendingPathComponent("staging", isDirectory: true)

        let (meeting, _) = try await MeetingImport.run(url: source, staging: staging)

        #expect(meeting.title == "Team- sync")
        #expect(meeting.importedFrom == "Team: sync.m4a")
    }
}
