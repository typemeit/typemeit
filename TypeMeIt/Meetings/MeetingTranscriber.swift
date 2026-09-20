import AVFoundation
import Foundation
import FoundationModels
import TranscribeCpp

/// The end-of-meeting pass (docs/meetings.md 7.10): read each track once
/// for its envelopes, cut it into chunks, transcribe each on the meeting
/// session, detect echo, merge the tracks into paragraphs, transcode and
/// return the finished meeting for the coordinator to publish. Runs in one
/// detached task per meeting; memory stays at one chunk.
enum MeetingTranscriber {
    /// Frames per envelope value: the peak envelope for the cutter is
    /// 100 ms, the RMS envelope for the echo detector 10 ms.
    static let peakEnvelopeMs = 100
    static let rmsEnvelopeHz = 100
    /// What a chunk the model could not read is written as.
    static let unreadable = "[unreadable]"

    enum Failure: LocalizedError {
        case cancelled
        var errorDescription: String? { "cancelled" }
    }

    /// Runs steps 1 to 5 and the transcode on `meeting` in `folder`, saving
    /// through the store as it goes. Returns the meeting `done`, `failed`,
    /// or `pending` when the model is not installed or the task was
    /// cancelled between chunks.
    static func run(_ start: Meeting, folder: URL, progress: @escaping @Sendable (Double) -> Void) async -> Meeting {
        var meeting = start
        guard ModelStore.isInstalled else {
            meeting.transcription.state = .pending
            await save(meeting)
            return meeting
        }
        let began = ContinuousClock.now
        meeting.transcription.state = .running
        meeting.transcription.error = nil
        await save(meeting)
        DebugLog.write("Meeting transcription started: \(meeting.id) with \(counted(meeting.tracks.count, "track"))")
        do {
            var trackWords: [TrackWords] = []
            var rms: [Meeting.Track.Role: [Float]] = [:]
            let totalChunks = try meeting.tracks.reduce(0) { $0 + chunkCount(of: $1, in: folder) }
            var doneChunks = meeting.transcription.done.values.reduce(0, +)
            for track in meeting.tracks {
                let url = folder.appendingPathComponent(track.file)
                let envelopes = try envelopes(of: url)
                rms[track.role] = envelopes.rms
                let cuts = ChunkCutter.cuts(peaks: envelopes.peaks, frameMs: peakEnvelopeMs, maxChunkMs: Fixed.meetingChunkSeconds * 1000,
                                            overlapMs: Fixed.meetingChunkOverlapSeconds * 1000, searchMs: Fixed.meetingChunkSearchSeconds * 1000)
                let scratch = folder.appendingPathComponent("words-\(track.role.rawValue).json")
                var words = (try? Data(contentsOf: scratch)).flatMap { try? Meeting.decoder.decode(TrackWords.self, from: $0) } ?? TrackWords(role: speakerID(for: track.role), words: [])
                let already = meeting.transcription.done[track.role.rawValue] ?? 0
                let file = try AVAudioFile(forReading: url)
                for (index, range) in cuts.enumerated() where index >= already {
                    if Task.isCancelled { throw Failure.cancelled }
                    let chunk = try read(file, range: range)
                    let transcribed = try await transcribe(chunk, range: range)
                    words.words = ChunkStitch.append(transcribed, after: words.words, overlapMs: Fixed.meetingChunkOverlapSeconds * 1000)
                    try Meeting.encoder.encode(words).write(to: scratch, options: .atomic)
                    meeting.transcription.done[track.role.rawValue] = index + 1
                    doneChunks += 1
                    progress(Double(doneChunks) / Double(max(totalChunks, 1)))
                    await save(meeting)
                }
                trackWords.append(words)
            }

            if meeting.kind == .call, let mic = rms[.mic], let others = rms[.others] {
                meeting.echo = EchoVerdict.verdict(EchoBleedDetector.analyse(micEnvelope: mic, othersEnvelope: others, envelopeHz: rmsEnvelopeHz))
            }

            let spans = meeting.dictations.map { Meeting.Span(startMs: $0.startMs, endMs: $0.endMs) }
            meeting.paragraphs = TranscriptMerge.paragraphs(tracks: trackWords, segments: nil, dictations: spans, gap: .seconds(Fixed.meetingParagraphGapSeconds))
            for i in meeting.speakers.indices {
                let id = meeting.speakers[i].id
                meeting.speakers[i].talkMs = meeting.paragraphs.filter { $0.speaker == id }.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            }
            meeting.transcription.state = .done
            meeting.transcription.asr = ModelStore.fileName
            meeting.transcription.tookMs = (ContinuousClock.now - began).milliseconds
            for track in meeting.tracks { try? FileManager.default.removeItem(at: folder.appendingPathComponent("words-\(track.role.rawValue).json")) }
            await save(meeting)
            DebugLog.write("Meeting transcribed: \(counted(meeting.paragraphs.count, "paragraph")) in \(meeting.transcription.tookMs ?? 0) ms, echo \(meeting.echo.rawValue)")

            if meeting.titleSource == .app, !meeting.paragraphs.isEmpty, let title = await generatedTitle(for: meeting) {
                meeting.title = title
                meeting.titleSource = .generated
            }
            meeting = await transcode(meeting, in: folder)
            await save(meeting)
        } catch Failure.cancelled {
            meeting.transcription.state = .pending
            await save(meeting)
        } catch {
            Log.meetings.error("Meeting transcription failed: \(error.localizedDescription)")
            DebugLog.write("Meeting transcription failed: \(error.localizedDescription)")
            meeting.transcription.state = .failed
            meeting.transcription.error = error.localizedDescription
            await save(meeting)
        }
        return meeting
    }

    private static func save(_ meeting: Meeting) async {
        await MainActor.run { MeetingStore.shared.save(meeting) }
    }

    /// The far end is `them`, the mic `you`, a room `room`.
    static func speakerID(for role: Meeting.Track.Role) -> String {
        switch role {
        case .mic: Meeting.Speaker.you
        case .others: Meeting.Speaker.them
        case .room: Meeting.Speaker.room
        }
    }

    // MARK: Audio

    private static func chunkCount(of track: Meeting.Track, in folder: URL) throws -> Int {
        let file = try AVAudioFile(forReading: folder.appendingPathComponent(track.file))
        let ms = Int(file.length) / Meeting.framesPerMs
        let chunk = Fixed.meetingChunkSeconds * 1000
        return ms <= chunk ? 1 : Int((Double(ms - chunk) / Double(chunk - Fixed.meetingChunkOverlapSeconds * 1000)).rounded(.up)) + 1
    }

    /// One pass over the file: the 100 ms peak envelope for the cutter and
    /// the 10 ms RMS envelope for the echo detector.
    private static func envelopes(of url: URL) throws -> (peaks: [Float], rms: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let rate = Int(file.processingFormat.sampleRate)
        let peakFrames = rate * peakEnvelopeMs / 1000
        let rmsFrames = rate / rmsEnvelopeHz
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate)) else { return ([], []) }
        var peaks: [Float] = []
        var rms: [Float] = []
        var peakAcc: Float = 0, peakCount = 0
        var rmsAcc: Float = 0, rmsCount = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(rate))
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<n {
                let v = data[i]
                peakAcc = max(peakAcc, abs(v)); peakCount += 1
                rmsAcc += v * v; rmsCount += 1
                if peakCount == peakFrames { peaks.append(peakAcc); peakAcc = 0; peakCount = 0 }
                if rmsCount == rmsFrames { rms.append((rmsAcc / Float(rmsFrames)).squareRoot()); rmsAcc = 0; rmsCount = 0 }
            }
        }
        if peakCount > 0 { peaks.append(peakAcc) }
        if rmsCount > 0 { rms.append((rmsAcc / Float(rmsCount)).squareRoot()) }
        return (peaks, rms)
    }

    private static func read(_ file: AVAudioFile, range: Range<Int>) throws -> [Float] {
        let start = AVAudioFramePosition(range.lowerBound * Meeting.framesPerMs)
        let count = AVAudioFrameCount(range.count * Meeting.framesPerMs)
        file.framePosition = min(start, file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return [] }
        try file.read(into: buffer, frameCount: count)
        guard let data = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }

    /// Transcribes one chunk, offsetting every word to meeting time. An
    /// out-of-memory run is halved and tried once more; anything else, or a
    /// half that fails again, leaves one `[unreadable]` word for the span.
    private static func transcribe(_ chunk: [Float], range: Range<Int>) async throws -> [Transcriber.Word] {
        do {
            return try await run(chunk, offsetMs: range.lowerBound)
        } catch Transcriber.Error.status(let status, _) where status == TRANSCRIBE_ERR_OOM {
            Log.meetings.notice("Chunk at \(range.lowerBound) ms ran out of memory; retrying in halves")
            let half = chunk.count / 2
            do {
                let first = try await run(Array(chunk[..<half]), offsetMs: range.lowerBound)
                let second = try await run(Array(chunk[half...]), offsetMs: range.lowerBound + half / Meeting.framesPerMs)
                return first + second
            } catch {
                return [unreadableWord(range)]
            }
        } catch Transcriber.Error.aborted {
            throw Failure.cancelled
        } catch {
            Log.meetings.error("Chunk at \(range.lowerBound) ms failed: \(error.localizedDescription)")
            return [unreadableWord(range)]
        }
    }

    private static func run(_ pcm: [Float], offsetMs: Int) async throws -> [Transcriber.Word] {
        let transcript = try await Transcriber.shared.transcribeMeetingChunk(pcm)
        let offset = Duration.milliseconds(offsetMs)
        return transcript.words.map { Transcriber.Word(text: $0.text, confidence: $0.confidence, start: $0.start + offset, end: $0.end + offset) }
    }

    private static func unreadableWord(_ range: Range<Int>) -> Transcriber.Word {
        Transcriber.Word(text: unreadable, confidence: .nan, start: .milliseconds(range.lowerBound), end: .milliseconds(range.upperBound))
    }

    // MARK: After the words

    /// Each `.caf` becomes an `.m4a`, deleted only once the copy reopens
    /// with the right length. With the audio setting off the tracks are
    /// deleted and no `.m4a` is written.
    private static func transcode(_ meeting: Meeting, in folder: URL) async -> Meeting {
        var meeting = meeting
        let keep = await MainActor.run { Settings.shared.meetingKeepAudio }
        for i in meeting.tracks.indices {
            let caf = folder.appendingPathComponent(meeting.tracks[i].file)
            guard caf.pathExtension == "caf" else { continue }
            if !keep {
                try? FileManager.default.removeItem(at: caf)
                continue
            }
            let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
            do {
                guard try MeetingFolder.transcode(from: caf, to: m4a) else {
                    Log.meetings.error("Transcoded \(m4a.lastPathComponent) came back short; keeping the CAF")
                    continue
                }
                try FileManager.default.removeItem(at: caf)
                meeting.tracks[i].file = m4a.lastPathComponent
            } catch {
                Log.meetings.error("Could not transcode \(caf.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return meeting
    }

    @Generable
    struct MeetingTitle: Sendable {
        @Guide(description: "three to five words")
        let title: String
    }

    /// A title from the first words of the transcript, on a session of its
    /// own (never `PostProcessor.shared`, whose window a meeting overflows
    /// and which cancels whatever it was doing when called again). Nil when
    /// Apple Intelligence is unavailable or declines.
    private static func generatedTitle(for meeting: Meeting) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let words = meeting.paragraphs.flatMap { $0.text.split(separator: " ") }.prefix(Fixed.meetingTitleSourceWords).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You title meeting transcripts. The user message is the start of one transcript. Answer with a title of three to five words naming what the meeting was about. No quotes, no trailing punctuation.")
        do {
            let response = try await session.respond(to: "<transcript>\n\(words)\n</transcript>", generating: MeetingTitle.self, options: GenerationOptions(sampling: .greedy))
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return title.isEmpty ? nil : title
        } catch {
            Log.meetings.notice("No generated title: \(error.localizedDescription)")
            return nil
        }
    }
}
