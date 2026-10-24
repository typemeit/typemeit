import AVFoundation
import FluidAudio
import Foundation

struct TurnOut: Codable { let startMs: Int; let endMs: Int; let speaker: String }
struct RunOut: Codable { let segments: [TurnOut]; let loadSeconds: Double; let runSeconds: Double; let audioSeconds: Double }

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fputs("usage: diar <system> <audio.wav>\n", stderr); exit(2) }
let system = arguments[1]
let url = URL(fileURLWithPath: arguments[2])
let audioSeconds = Double(try AVAudioFile(forReading: url).length) / 16000

let loadStart = ContinuousClock.now
var turns: [TurnOut] = []
var loadSeconds = 0.0
var runSeconds = 0.0

if system == "nemotron" || system == "nemotron-app" {
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
    if system == "nemotron-app" {
        // The app's next step (Diarizer.run, then MeetingTranscriber.speakers) on a track with no
        // window count: one WeSpeaker embedding per speaker from its longest 30 s, then
        // SpeakerMerge.absorbingShort folds speakers under 10 s into the nearest voice.
        let models = try await OfflineDiarizerModels.load(
            from: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/TypeMeIt/models/diarizer"))
        let embedder = OfflineDiarizerManager(config: OfflineDiarizerConfig(
            segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
            segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds
        ).withSpeakers(exactly: 1))
        embedder.initialize(models: models)
        var embeddings: [String: [Float]] = [:]
        for speaker in Set(segments.map(\.speaker)) {
            var clip: [Float] = []
            var taken = 0
            let budget = Fixed.meetingEmbeddingClipSeconds * 1000
            for segment in segments.filter({ $0.speaker == speaker }).sorted(by: { $0.endMs - $0.startMs > $1.endMs - $1.startMs }) {
                guard taken < budget else { break }
                let end = min(segment.endMs, segment.startMs + budget - taken)
                file.framePosition = AVAudioFramePosition(segment.startMs * 16)
                let count = AVAudioFrameCount((end - segment.startMs) * 16)
                let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: piece, frameCount: count)
                clip += Array(UnsafeBufferPointer(start: piece.floatChannelData![0], count: Int(piece.frameLength)))
                taken += end - segment.startMs
            }
            guard !clip.isEmpty else { continue }
            embeddings[speaker] = (try? await embedder.process(audio: clip))?.speakerDatabase?.values.first
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
