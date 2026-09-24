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
        // A menu-bar accessory doing minutes of background work is what App Nap naps.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "transcribing a meeting")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        meeting.transcription.state = .running
        meeting.transcription.error = nil
        await save(meeting)
        DebugLog.write("Meeting transcription started: \(meeting.id) with \(counted(meeting.tracks.count, "track"))")
        do {
            var trackWords: [TrackWords] = []
            var rms: [Meeting.Track.Role: [Float]] = [:]
            var totalChunks = 0
            for track in meeting.tracks { totalChunks += try chunkCount(of: track, in: folder) }
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
                    // A chunk that never leaves the floor is done without a
                    // model call: a muted far end is otherwise decoded a chunk at a time.
                    let peakFrames = envelopes.peaks[(range.lowerBound / peakEnvelopeMs)..<min(envelopes.peaks.count, (range.upperBound + peakEnvelopeMs - 1) / peakEnvelopeMs)]
                    let transcribed: [Transcriber.Word]
                    if (peakFrames.max() ?? 0) < Fixed.meetingSilenceFloor {
                        transcribed = []
                    } else {
                        let chunk = try read(file, range: range)
                        transcribed = try await transcribeRetryingQuiet(chunk, range: range)
                    }
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
                if meeting.echo == .affected, let m = trackWords.firstIndex(where: { $0.role == Meeting.Speaker.you }), let o = trackWords.firstIndex(where: { $0.role == Meeting.Speaker.them }) {
                    let folded = EchoFold.fold(mic: trackWords[m].words, others: trackWords[o].words, micEnvelope: mic, othersEnvelope: others, envelopeHz: rmsEnvelopeHz)
                    trackWords[m].words = folded.mic
                    trackWords[o].words = folded.others
                    DebugLog.write("Meeting echo folded: \(counted(folded.droppedFromMic, "word")) off the mic, \(counted(folded.droppedFromOthers, "word")) off the far end")
                }
            }

            let segments = await speakers(of: &meeting, in: folder)
            let spans = meeting.dictations.map { Meeting.Span(startMs: $0.startMs, endMs: $0.endMs) }
            meeting.paragraphs = TranscriptMerge.paragraphs(tracks: trackWords, segments: segments, dictations: spans, gap: .seconds(Fixed.meetingParagraphGapSeconds))
            // A word the segments did not reach keeps its track's label; that
            // speaker stays in the list so the row can name it.
            for role in meeting.tracks.map(\.role) {
                let id = speakerID(for: role)
                if meeting.paragraphs.contains(where: { $0.speaker == id }), !meeting.speakers.contains(where: { $0.id == id }) {
                    meeting.speakers.append(Meeting.Speaker(id: id, name: defaultName(for: role), isYou: role == .mic, talkMs: 0))
                }
            }
            // Names from the meeting window, when it was read (8.6): the
            // diarizer says how many and when, the meeting says who. Captions
            // are theirs, not ours, and go once they have been used.
            if let names = meeting.names {
                let aligned = SpeakerNaming.align(
                    speakers: meeting.speakers, segments: segments ?? [], paragraphs: meeting.paragraphs, names: names,
                    userName: NSFullUserName(), lagMs: Fixed.meetingUILagMs, captionMatch: Fixed.meetingCaptionMatch,
                    minOverlapMs: Fixed.meetingNameMinOverlapSeconds * 1000, margin: Fixed.meetingNameMargin)
                meeting.speakers = aligned.speakers
                meeting.paragraphs = aligned.paragraphs
                meeting.names?.captions = nil
                DebugLog.write("Meeting names aligned from \(names.source.rawValue): \(counted(meeting.speakers.filter { $0.nameSource != nil }.count, "speaker")) named")
            }
            for i in meeting.speakers.indices {
                let id = meeting.speakers[i].id
                meeting.speakers[i].talkMs = meeting.paragraphs.filter { $0.speaker == id }.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
            }
            // A speaker the diarizer found but no word landed on is not listed.
            let spoken = Set(meeting.paragraphs.map(\.speaker))
            meeting.speakers.removeAll { !$0.isYou && !spoken.contains($0.id) }
            meeting.transcription.asr = (ModelStore.fileName as NSString).deletingPathExtension
            for track in meeting.tracks { try? FileManager.default.removeItem(at: folder.appendingPathComponent("words-\(track.role.rawValue).json")) }
            await save(meeting)
            // The title ladder (9.2): who was there, then what it was about, then the app.
            if meeting.titleSource == .app, let title = meeting.names?.title(excluding: NSFullUserName()) {
                meeting.title = title
                meeting.titleSource = .roster
            } else if meeting.titleSource == .app, !meeting.paragraphs.isEmpty, let title = await generatedTitle(for: meeting) {
                meeting.title = title
                meeting.titleSource = .generated
            }
            if !meeting.paragraphs.isEmpty { meeting.summary = await MeetingSummary.summarise(meeting) }
            meeting = await transcode(meeting, in: folder)
            // Done last: the store publishes any done meeting it sees, and the
            // folder must not move while the transcode is still writing into it.
            meeting.transcription.state = .done
            meeting.transcription.tookMs = (ContinuousClock.now - began).milliseconds
            await save(meeting)
            DebugLog.write("Meeting transcribed: \(counted(meeting.paragraphs.count, "paragraph")) in \(meeting.transcription.tookMs ?? 0) ms, echo \(meeting.echo.rawValue)")
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

    private static func defaultName(for role: Meeting.Track.Role) -> String {
        switch role {
        case .mic: "You"
        case .others: "Them"
        case .room: "Room"
        }
    }

    // MARK: Speakers (docs/meetings.md 8.3)

    /// Diarizes the far-end track of a call or the one track of a room.
    /// Speakers become `s1…sN` in first-appearance order named Speaker 1…N,
    /// keeping a name the user gave the same id before; a call whose far
    /// end has one speaker stays `Them`. Without the model the meeting
    /// transcribes as before, and the download starts for the next one.
    /// The diarizer failing keeps the transcript with `Them` or `Room`.
    private static func speakers(of meeting: inout Meeting, in folder: URL) async -> [SpeakerSegment]? {
        let role: Meeting.Track.Role = meeting.kind == .call ? .others : .room
        guard let track = meeting.tracks.first(where: { $0.role == role }) else { return nil }
        guard DiarizerModelStore.isInstalled else {
            await MainActor.run { DiarizerModelStore.shared.download() }
            return nil
        }
        // A speakers call with echo on the mic side never feeds the mic into embeddings (8.3); the far end is diarized alone.
        let segments: [SpeakerSegment]
        do {
            let run = try await Diarizer.shared.run(url: folder.appendingPathComponent(track.file))
            segments = SpeakerMerge.absorbingShort(run.segments, embeddings: run.embeddings, minimumMs: Fixed.meetingMinimumSpeakerSeconds * 1000)
        } catch {
            Log.meetings.error("Diarization failed; keeping \(defaultName(for: role)): \(error.localizedDescription)")
            DebugLog.write("Meeting diarization failed: \(error.localizedDescription)")
            return nil
        }
        meeting.transcription.diarizer = DiarizerModelStore.pipelineName
        var order: [String] = []
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) where !order.contains(segment.speaker) { order.append(segment.speaker) }
        guard !order.isEmpty else { return nil }
        let previous = meeting.speakers
        meeting.speakers = meeting.speakers.filter { $0.isYou }
        if meeting.kind == .call, order.count == 1 {
            let them = Meeting.Speaker.them
            meeting.speakers.append(Meeting.Speaker(id: them, name: previous.first { $0.id == them }?.name ?? defaultName(for: .others), isYou: false, talkMs: 0))
            return nil
        }
        let ids = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, "s\($0 + 1)") })
        for (i, original) in order.enumerated() {
            let id = ids[original]!
            let name = previous.first { $0.id == id }?.name ?? "Speaker \(i + 1)"
            meeting.speakers.append(Meeting.Speaker(id: id, name: name, isYou: false, talkMs: 0))
        }
        DebugLog.write("Meeting speakers: \(counted(order.count, "speaker")) on the \(role.rawValue) track")
        return segments.map { SpeakerSegment(speaker: ids[$0.speaker]!, startMs: $0.startMs, endMs: $0.endMs) }
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

    /// A chunk with speech that came back empty is tried once more,
    /// trimmed to its speech and louder.
    private static func transcribeRetryingQuiet(_ chunk: [Float], range: Range<Int>) async throws -> [Transcriber.Word] {
        let words = try await transcribe(chunk, range: range)
        guard words.isEmpty, QuietSpeech.hasSpeech(chunk), let boosted = QuietSpeech.boosted(chunk) else { return words }
        let start = range.lowerBound + boosted.offsetFrames / Meeting.framesPerMs
        let retried = try await transcribe(boosted.pcm, range: start..<(start + boosted.pcm.count / Meeting.framesPerMs))
        DebugLog.write("Meeting chunk at \(range.lowerBound) ms was empty; the louder retry gave \(counted(retried.count, "word"))")
        return retried
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

    /// Each raw `<role>.caf` becomes `<role>.opus.caf`, and is deleted only
    /// once the copy reopens with the right length. With the audio setting
    /// off the tracks are deleted and nothing is written.
    private static func transcode(_ meeting: Meeting, in folder: URL) async -> Meeting {
        var meeting = meeting
        let keep = await MainActor.run { Settings.shared.meetingKeepAudio }
        for i in meeting.tracks.indices {
            let caf = folder.appendingPathComponent(meeting.tracks[i].file)
            guard meeting.tracks[i].file == "\(meeting.tracks[i].role.rawValue).caf" else { continue }
            if !keep {
                try? FileManager.default.removeItem(at: caf)
                continue
            }
            let kept = folder.appendingPathComponent(meeting.tracks[i].role.rawValue + Meeting.keptAudioSuffix)
            do {
                guard try MeetingFolder.transcode(from: caf, to: kept) else {
                    Log.meetings.error("Transcoded \(kept.lastPathComponent) came back short; keeping the CAF")
                    continue
                }
                try FileManager.default.removeItem(at: caf)
                meeting.tracks[i].file = kept.lastPathComponent
            } catch {
                Log.meetings.error("Could not transcode \(caf.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return meeting
    }

    /// `Fixed.meetingTitleSourceWords` words as `Fixed.meetingTitleSamples`
    /// runs spread evenly across the transcript, joined by an ellipsis line.
    static func titleSample(of meeting: Meeting) -> String {
        let words = meeting.paragraphs.flatMap { $0.text.split(separator: " ") }
        guard !words.isEmpty else { return "" }
        if words.count <= Fixed.meetingTitleSourceWords { return words.joined(separator: " ") }
        let size = Fixed.meetingTitleSourceWords / Fixed.meetingTitleSamples
        return (0..<Fixed.meetingTitleSamples).map { k in
            let start = k * words.count / Fixed.meetingTitleSamples
            return words[start..<min(start + size, words.count)].joined(separator: " ")
        }.joined(separator: "\n…\n")
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
        let words = titleSample(of: meeting)
        guard !words.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: "You title meeting transcripts. The user message is the start of one transcript. Answer with a title of three to five words naming the subject the meeting was about, the way someone who was in it would refer to it afterwards. Prefer the topic over a company or product name that merely came up, and never name a person. No quotes, no trailing punctuation.")
        do {
            let response = try await session.respond(to: "<transcript>\n\(words)\n</transcript>", generating: MeetingTitle.self, options: GenerationOptions(samplingMode: .greedy))
            let title = response.content.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return title.isEmpty ? nil : title
        } catch {
            Log.meetings.notice("No generated title: \(error.localizedDescription)")
            return nil
        }
    }
}
