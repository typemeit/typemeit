import AVFoundation
import FluidAudio
import Foundation

struct TurnOut: Codable { let startMs: Int; let endMs: Int; let speaker: String }
struct RunOut: Codable { let segments: [TurnOut]; let loadSeconds: Double; let runSeconds: Double; let audioSeconds: Double }

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

/// The parts of a meeting.json the window's speaker count is read from.
struct MeetingFile: Decodable {
    struct Speaker: Decodable { let id: String; let isYou: Bool }
    struct Paragraph: Decodable { let speaker: String; let startMs: Int; let endMs: Int }
    struct Names: Decodable { let roster: [String]; let spans: [MeetingNames.Span]?; let user: String? }
    let speakers: [Speaker]
    let paragraphs: [Paragraph]
    let names: Names?
}

let arguments = CommandLine.arguments
let system = arguments.count > 1 ? arguments[1] : ""
let window = system == "nemotron-app-window"
guard arguments.count == (window ? 4 : 3) else {
    fputs("usage: diar <system> <audio.wav>, or diar nemotron-app-window <audio.wav> <meeting.json>\n", stderr); exit(2)
}
let url = URL(fileURLWithPath: arguments[2])
let audioSeconds = Double(try AVAudioFile(forReading: url).length) / 16000

let loadStart = ContinuousClock.now
var turns: [TurnOut] = []
var loadSeconds = 0.0
var runSeconds = 0.0

if system == "nemotron" || system == "nemotron-app" || window {
    let config = Nemotron3Config.offline
    let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TYPEMEIT_NEMOTRON_DIR"]
        ?? NSHomeDirectory() + "/Library/Application Support/TypeMeIt/models/diarizer/nemotron-3-diarization")
    ModelHub.offlineMode = true
    let models = try await Nemotron3Models.load(config: config, directory: folder, computeUnits: .all)
    let diarizer = Nemotron3Diarizer(config: config, models: models)
    loadSeconds = seconds(ContinuousClock.now - loadStart)
    let runStart = ContinuousClock.now
    // The app's own loop (Diarizer.turns): a second at a time, then SpeakerFrames.segments.
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate))!
    diarizer.reset()
    var probabilities: [Float] = []
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: buffer.frameCapacity)
        guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
        diarizer.appendAudio(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
        for chunk in try diarizer.processBufferedAudio() { probabilities += chunk.probabilities }
    }
    for chunk in try diarizer.finishStream() { probabilities += chunk.probabilities }
    var segments = SpeakerFrames.segments(
        probabilities: probabilities, speakers: config.numSpeakers,
        frameMs: Int((config.outputFrameSeconds * 1000).rounded()),
        threshold: Fixed.meetingTurnThreshold, minimumMs: Fixed.meetingTurnMinimumMs
    )
    if system == "nemotron-app" || window {
        // The app's next step (Diarizer.run, then MeetingTranscriber.speakers), with the window's
        // count only for nemotron-app-window: one WeSpeaker embedding per speaker from its longest 30 s, then
        // SpeakerMerge.absorbingShort folds speakers under 10 s into the nearest voice.
        let models = try await OfflineDiarizerModels.load(
            from: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/TypeMeIt/models/diarizer"))
        let embedder = OfflineDiarizerManager(config: OfflineDiarizerConfig(
            segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
            segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds
        ).withSpeakers(exactly: 1))
        embedder.initialize(models: models)
        // Diarizer.clip: the speaker's longest segments, up to `budget` ms.
        let sampleRate = Int(file.processingFormat.sampleRate)
        func clip(of speaker: String, budget: Int) throws -> [Float] {
            var clip: [Float] = []
            var taken = 0
            for segment in segments.filter({ $0.speaker == speaker }).sorted(by: { $0.endMs - $0.startMs > $1.endMs - $1.startMs }) {
                guard taken < budget else { break }
                let end = min(segment.endMs, segment.startMs + budget - taken)
                file.framePosition = AVAudioFramePosition(segment.startMs * sampleRate / 1000)
                let count = AVAudioFrameCount((end - segment.startMs) * sampleRate / 1000)
                let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: piece, frameCount: count)
                clip += Array(UnsafeBufferPointer(start: piece.floatChannelData![0], count: Int(piece.frameLength)))
                taken += end - segment.startMs
            }
            return clip
        }
        var embeddings: [String: [Float]] = [:]
        for speaker in Set(segments.map(\.speaker)) {
            let clip = try clip(of: speaker, budget: Fixed.meetingEmbeddingClipSeconds * 1000)
            guard !clip.isEmpty else { continue }
            embeddings[speaker] = (try? await embedder.process(audio: clip))?.speakerDatabase?.values.first
        }
        if window {
            // MeetingTranscriber's count from the meeting window (SpeakerCount), with the stored
            // paragraphs standing in for the words, then Diarizer.run's cap (SpeakerMerge.capped).
            let meeting = try JSONDecoder().decode(MeetingFile.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))
            let you = Set(meeting.speakers.filter(\.isYou).map(\.id))
            func words(_ mic: Bool) -> [Transcriber.Word] {
                meeting.paragraphs.filter { you.contains($0.speaker) == mic }
                    .map { Transcriber.Word(text: "", confidence: .nan, start: .milliseconds($0.startMs), end: .milliseconds($0.endMs)) }
            }
            if let shown = meeting.names {
                let names = MeetingNames(roster: shown.roster, spans: shown.spans ?? [])
                let speakerMs = Fixed.meetingMinimumSpeakerSeconds * 1000
                let talkers = SpeakerCount.farEndTalkers(spans: names.spans, farEnd: words(false), mic: words(true), lagMs: Fixed.meetingUILagMs, minimumMs: speakerMs)
                if let count = SpeakerCount.of(names, talkers: talkers, userName: shown.user ?? NSFullUserName()) {
                    let spans = names.spans.map { MeetingNames.Span(name: $0.name, startMs: $0.startMs - Fixed.meetingUILagMs, endMs: $0.endMs - Fixed.meetingUILagMs) }
                    var voices: [String: [[Float]]] = [:]
                    if embeddings.count > count.maximum, !spans.isEmpty {
                        let clipSamples = Fixed.meetingVoiceClipSeconds * sampleRate
                        for speaker in embeddings.keys {
                            let joined = try clip(of: speaker, budget: Fixed.meetingVoiceClipSeconds * Fixed.meetingVoiceClips * 1000)
                            for start in stride(from: 0, to: joined.count - clipSamples + 1, by: clipSamples) {
                                if let voice = (try? await embedder.process(audio: Array(joined[start..<start + clipSamples])))?.speakerDatabase?.values.first {
                                    voices[speaker, default: []].append(voice)
                                }
                            }
                        }
                    }
                    segments = SpeakerMerge.capped(segments, embeddings: embeddings, maximum: count.maximum,
                                                   tiles: SpeakerMerge.tiles(of: segments, spans: spans), voices: voices, distinct: Fixed.meetingDistinctVoiceDistance)
                    fputs("told \(count), \(talkers.count) lit\n", stderr)
                }
            }
        }
        segments = SpeakerMerge.absorbingShort(segments, embeddings: embeddings, minimumMs: Fixed.meetingMinimumSpeakerSeconds * 1000)
    }
    turns = segments.map { TurnOut(startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker) }
    runSeconds = seconds(ContinuousClock.now - runStart)
} else if system.hasPrefix("lseend-") {
    let variants: [String: LSEENDVariant] = ["ami": .ami, "callhome": .callhome, "dihard2": .dihard2, "dihard3": .dihard3]
    guard let variant = variants[String(system.dropFirst("lseend-".count))] else { fputs("unknown variant\n", stderr); exit(2) }
    let model = try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: .step100ms, computeUnits: .cpuOnly)
    let diarizer = try LSEENDDiarizer(model: model)
    loadSeconds = seconds(ContinuousClock.now - loadStart)
    let runStart = ContinuousClock.now
    let timeline = try diarizer.processComplete(audioFileURL: url, keepingEnrolledSpeakers: nil, finalizeOnCompletion: true, progressCallback: nil)
    let frameMs = Double(timeline.config.frameDurationSeconds) * 1000
    for (_, speaker) in timeline.speakers {
        for segment in speaker.finalizedSegments {
            turns.append(TurnOut(startMs: Int((Double(segment.startFrame) * frameMs).rounded()), endMs: Int((Double(segment.endFrame) * frameMs).rounded()), speaker: String(segment.speakerIndex)))
        }
    }
    turns.sort { $0.startMs < $1.startMs }
    runSeconds = seconds(ContinuousClock.now - runStart)
} else {
    fputs("unknown system \(system)\n", stderr); exit(2)
}
FileHandle.standardOutput.write(try JSONEncoder().encode(RunOut(segments: turns, loadSeconds: loadSeconds, runSeconds: runSeconds, audioSeconds: audioSeconds)))
