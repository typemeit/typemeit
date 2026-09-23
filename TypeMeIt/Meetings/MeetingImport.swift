import AVFoundation
import CoreMedia
import Foundation

/// Turns a recording made elsewhere into a meeting, the same shape a live
/// recording produces, so it can run through the existing pipeline
/// unchanged (docs/meetings.md 7.14, D21).
enum MeetingImport {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case noAudio
        case insufficientDiskSpace

        var errorDescription: String? {
            switch self {
            case .noAudio: "no audio in that file"
            case .insufficientDiskSpace: "not enough disk space to import"
            }
        }
    }

    /// One block of native-rate audio read and converted at a time, so a
    /// four-hour file is bounded by disk rather than memory.
    private static let blockSeconds: Double = 1

    /// Reads `url`, converts it to a room track and writes a staged meeting
    /// folder. `AVAudioFile` reads what it can; a container it refuses
    /// (`.mp4`, `.mov`) falls back to `AVAssetReader` over the first audio
    /// track.
    static func run(url: URL, staging: URL = MeetingFolder.stagingRoot) async throws -> (meeting: Meeting, folder: URL) {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try checkFreeSpace(in: staging)

        let id = UUID()
        let folder = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let writer = try TrackWriter(url: folder.appendingPathComponent("room.caf"))
        do {
            if let file = try? AVAudioFile(forReading: url) {
                try convert(file, into: writer)
            } else {
                try await convertViaAssetReader(url: url, into: writer)
            }
        } catch {
            _ = writer.finish()
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let finished = writer.finish()

        let started = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let durationMs = finished.frames / Meeting.framesPerMs
        let title = MeetingFolder.sanitised(url.deletingPathExtension().lastPathComponent)
        let meeting = Meeting(
            id: id, kind: .room, started: started, timeZone: TimeZone.current.identifier,
            ended: started.addingTimeInterval(TimeInterval(durationMs) / 1000),
            durationMs: durationMs, recordedMs: durationMs, firstHostTime: nil,
            app: nil, title: title, titleSource: .app, published: false,
            tracks: [Meeting.Track(role: .room, file: "room.caf", frames: finished.frames, peak: finished.peak)],
            audio: nil, echo: .notMeasured, bothSilentMs: 0, dictations: [],
            speakers: [Meeting.Speaker(id: Meeting.Speaker.room, name: "Room", isYou: false, talkMs: 0)],
            transcription: Meeting.Transcription(state: .pending), paragraphs: [],
            source: .imported, importedFrom: url.lastPathComponent)
        try MeetingFolder.write(meeting, to: folder)
        return (meeting, folder)
    }

    /// Only blocks the import when the free-space check can positively show
    /// too little room; an unreadable volume statistic lets the import try
    /// anyway, matching `MeetingRecorder.checkDisk`.
    private static func checkFreeSpace(in staging: URL) throws {
        guard let values = try? staging.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return }
        guard free >= Fixed.meetingMinimumFreeBytes else { throw Error.insufficientDiskSpace }
    }

    // MARK: AVAudioFile

    private static func convert(_ file: AVAudioFile, into writer: TrackWriter) throws {
        let nativeFormat = file.processingFormat
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeFormat.sampleRate, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: monoFormat, to: AudioCapture.targetFormat) else { throw Error.noAudio }
        let blockFrames = AVAudioFrameCount(nativeFormat.sampleRate * blockSeconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: blockFrames) else { throw Error.noAudio }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            let mono = monoSamples(from: buffer)
            writer.append(resample(mono, with: converter, nativeRate: nativeFormat.sampleRate))
        }
    }

    // MARK: AVAssetReader

    /// The first audio track's format is read from its own sample buffers,
    /// so nothing here needs the track's format descriptions up front.
    private static func convertViaAssetReader(url: URL, into writer: TrackWriter) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Error.noAudio }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        let reader = try AVAssetReader(asset: asset)
        guard reader.canAdd(output) else { throw Error.noAudio }
        reader.add(output)
        guard reader.startReading() else { throw Error.noAudio }

        var converter: AVAudioConverter?
        var nativeRate: Double = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee else { continue }
            let channels = AVAudioChannelCount(max(1, Int(asbd.mChannelsPerFrame)))
            if converter == nil {
                nativeRate = asbd.mSampleRate
                let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: nativeRate, channels: 1, interleaved: false)!
                converter = AVAudioConverter(from: monoFormat, to: AudioCapture.targetFormat)
            }
            guard let converter,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: asbd.mSampleRate, channels: channels, interleaved: true),
                  let buffer = pcmBuffer(from: sampleBuffer, format: format) else { continue }
            let mono = monoSamples(from: buffer)
            writer.append(resample(mono, with: converter, nativeRate: nativeRate))
        }
        if reader.status == .failed { throw reader.error ?? Error.noAudio }
        guard converter != nil else { throw Error.noAudio }
    }

    /// Wraps a sample buffer's audio data without copying it; the retained
    /// block buffer is kept alive by the deallocator closure until the
    /// `AVAudioPCMBuffer` itself is freed.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        var audioBufferList = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, blockBuffer != nil else { return nil }
        return withUnsafeMutablePointer(to: &audioBufferList) { pointer in
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: pointer) { _ in _ = blockBuffer }
        }
    }

    // MARK: Mixing and resampling

    /// Averages every channel down to one, at the buffer's own sample rate.
    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0, let channelData = buffer.floatChannelData else { return [] }
        var mono = [Float](repeating: 0, count: frameCount)
        if buffer.format.isInterleaved {
            let interleaved = channelData[0]
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += interleaved[frame * channelCount + channel] }
                mono[frame] = sum / Float(channelCount)
            }
        } else {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channelData[channel][frame] }
                mono[frame] = sum / Float(channelCount)
            }
        }
        return mono
    }

    /// Runs `samples` (mono, at `nativeRate`) through `converter` to
    /// `AudioCapture.targetFormat`, one buffer at a time.
    private static func resample(_ samples: [Float], with converter: AVAudioConverter, nativeRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let inputFormat = converter.inputFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        let ratio = AudioCapture.targetFormat.sampleRate / nativeRate
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioCapture.targetFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { Log.meetings.error("Meeting import conversion failed: \(error.localizedDescription)"); return [] }
        guard let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}
