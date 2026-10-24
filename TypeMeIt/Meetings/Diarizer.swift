import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// Who spoke when (docs/meetings.md 8.2). Nemotron 3 Diarization finds the
/// turns; FluidAudio's offline pipeline (pyannote community-1 segmentation,
/// WeSpeaker embeddings) then gives each speaker it found one embedding, which
/// `SpeakerMerge` and `RoomVoices` match voices by. Nemotron has no
/// embeddings of its own. Both are loaded when a pass first needs them, and
/// let go when the transcription queue empties (a reload takes about 0.05 s),
/// from the files `DiarizerModelStore` installed and never from the network:
/// `ModelHub.offlineMode` is set before any loader is touched, and
/// `prepareModels` is never called, since its catch path deletes the model
/// folder on any load error.
///
/// Rerunning 14 kept meetings on 30 September against AssemblyAI's labels,
/// 4.8% of words went under the wrong speaker where the pyannote pipeline
/// had put 8.6%, and the number of people was right on 12 to its 9. One
/// 11-minute call with one far-end person came out as two (9.1% to 10.4%).
actor Diarizer {
    static let shared = Diarizer()

    /// FluidAudio's types are not Sendable; each is used from one detached
    /// task at a time, serialised by this actor.
    private struct Loaded: @unchecked Sendable {
        let turns: Nemotron3Diarizer
        let models: OfflineDiarizerModels
        let embedder: OfflineDiarizerManager
    }
    private var loaded: Loaded?

    enum Error: LocalizedError {
        case notInstalled
        case sampleRate(Double)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "the speaker model is not installed"
            case .sampleRate(let rate): "the track is at \(Int(rate)) Hz, not 16 kHz"
            }
        }
    }

    private init() {}

    /// Gives the models' memory back; the next `run` loads them again.
    func unload() {
        loaded = nil
    }

    /// Nemotron's offline preset: a 27.2 s chunk with 3.2 s of look-ahead,
    /// the most accurate and fastest of its presets on a whole recording.
    /// It runs on the GPU; the Neural Engine cannot compile it.
    static let turnConfig = Nemotron3Config.offline

    /// FluidAudio's clustering threshold, with S3's segmentation values
    /// from michaelwilhelmsen/humla (MIT) (docs/meetings.md S3): a turn
    /// needs 1.0 s on so a "yeah" does not split a sentence across
    /// speakers, and 0.5 s off so a breath does not end one. Used for S3's
    /// comparison probe, and, told there is one speaker, for embeddings.
    static let configuration = OfflineDiarizerConfig(
        segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
        segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds)

    private func ensureLoaded() async throws -> Loaded {
        if let loaded { return loaded }
        guard DiarizerModelStore.isInstalled else { throw Error.notInstalled }
        ModelHub.offlineMode = true
        let started = ContinuousClock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let models = try await OfflineDiarizerModels.load(from: DiarizerModelStore.directory, configuration: configuration)
        let embedder = OfflineDiarizerManager(config: Diarizer.configuration.withSpeakers(exactly: 1))
        embedder.initialize(models: models)
        let turnModels = try await Nemotron3Models.load(config: Diarizer.turnConfig, directory: DiarizerModelStore.nemotronFolder, computeUnits: .all)
        let loaded = Loaded(turns: Nemotron3Diarizer(config: Diarizer.turnConfig, models: turnModels), models: models, embedder: embedder)
        self.loaded = loaded
        Log.meetings.info("Speaker models loaded in \(ContinuousClock.now - started)")
        return loaded
    }

    /// Who spoke when on one track, with one embedding per speaker for the
    /// caller's matching, returned in memory and never stored (D18). Told
    /// how many voices the track holds, the quietest are folded into the
    /// nearest voice until no more remain; Nemotron cannot be told a count.
    /// With the window's speaking `spans`, a voice heard through the same
    /// tile as another but sounding unlike it is kept (`SpeakerMerge.capped`).
    func run(url: URL, count: SpeakerCount? = nil, spans: [MeetingNames.Span] = []) async throws -> (segments: [SpeakerSegment], embeddings: [String: [Float]]) {
        let loaded = try await ensureLoaded()
        let started = ContinuousClock.now
        let segments = try await Task.detached { try Diarizer.turns(of: url, with: loaded.turns) }.value
        var embeddings: [String: [Float]] = [:]
        for speaker in Set(segments.map(\.speaker)) {
            let clip = try Diarizer.clip(of: speaker, segments: segments, in: url, budgetMs: Fixed.meetingEmbeddingClipSeconds * 1000)
            guard !clip.isEmpty else { continue }
            // Too little speech for the embedding model throws ("No speech
            // detected"); that speaker goes without, and SpeakerMerge places
            // them by the turns they sit next to.
            let result = try? await Task.detached { try await loaded.embedder.process(audio: clip) }.value
            embeddings[speaker] = result?.speakerDatabase?.values.first
        }
        var voices: [String: [[Float]]] = [:]
        if let count, embeddings.count > count.maximum, !spans.isEmpty {
            let clipSamples = Fixed.meetingVoiceClipSeconds * Diarizer.turnConfig.sampleRate
            for speaker in embeddings.keys {
                let joined = try Diarizer.clip(of: speaker, segments: segments, in: url, budgetMs: Fixed.meetingVoiceClipSeconds * Fixed.meetingVoiceClips * 1000)
                for start in stride(from: 0, to: joined.count - clipSamples + 1, by: clipSamples) {
                    let piece = Array(joined[start..<start + clipSamples])
                    if let voice = try? await Task.detached(operation: { try await loaded.embedder.process(audio: piece) }).value.speakerDatabase?.values.first {
                        voices[speaker, default: []].append(voice)
                    }
                }
            }
        }
        let capped = count.map {
            SpeakerMerge.capped(segments, embeddings: embeddings, maximum: $0.maximum,
                                tiles: SpeakerMerge.tiles(of: segments, spans: spans), voices: voices, distinct: Fixed.meetingDistinctVoiceDistance)
        } ?? segments
        Log.meetings.info("Diarized \(url.lastPathComponent): \(counted(Set(capped.map(\.speaker)).count, "speaker")), \(counted(capped.count, "segment")) in \(ContinuousClock.now - started)")
        return (capped, embeddings)
    }

    /// One WeSpeaker embedding per clip, made the way FluidAudio's
    /// `embedSpan` makes one: the clip repeated to fill the model's window,
    /// every frame weighted. Zero padding would not do: the FBank model
    /// subtracts its mean over the whole window, which padding drags to the
    /// log floor. A clip longer than the window is cut to it. For `VoiceLibrary`, which keeps them while
    /// `Settings.meetingLearnVoices` is on.
    func voices(of clips: [[Float]]) async throws -> [[Float]] {
        let loaded = try await ensureLoaded()
        return try await Task.detached { try clips.map { try Diarizer.voice(of: $0, models: loaded.models) } }.value
    }

    /// The samples `voices(of:)` hears at most: the embedding model's window.
    func voiceWindowSamples() async throws -> Int {
        let loaded = try await ensureLoaded()
        return Diarizer.inputLength(loaded.models.fbankModel, "audio")
    }

    private static func inputLength(_ model: MLModel, _ input: String) -> Int {
        model.modelDescription.inputDescriptionsByName[input]?.multiArrayConstraint?.shape.last?.intValue ?? 0
    }

    private static func voice(of clip: [Float], models: OfflineDiarizerModels) throws -> [Float] {
        let window = inputLength(models.fbankModel, "audio")
        let frames = inputLength(models.embeddingModel, "weights")
        guard !clip.isEmpty else { return [] }
        let audio = try MLMultiArray(shape: [1, 1, NSNumber(value: window)], dataType: .float32)
        Diarizer.tiled(clip, length: window).withUnsafeBufferPointer {
            audio.dataPointer.assumingMemoryBound(to: Float.self).update(from: $0.baseAddress!, count: window)
        }
        let fbank = try models.fbankModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio]))
        guard let features = fbank.featureValue(for: "fbank_features")?.multiArrayValue else { return [] }
        let weights = try MLMultiArray(shape: [1, NSNumber(value: frames)], dataType: .float32)
        weights.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 1, count: frames)
        let embedded = try models.embeddingModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["fbank_features": features, "weights": weights]))
        guard let embedding = embedded.featureValue(for: "embedding")?.multiArrayValue else { return [] }
        return (0..<embedding.count).map { embedding[$0].floatValue }
    }

    /// `clip` repeated end to end until it fills `length` samples, or cut
    /// to `length`. Not empty.
    static func tiled(_ clip: [Float], length: Int) -> [Float] {
        (0..<length).map { clip[$0 % clip.count] }
    }

    /// Nemotron over the whole track, fed a second at a time: one read of
    /// a long stretch of a kept Opus track does not come back
    /// (`MeetingTranscriber.read`), and a second at a time also keeps the
    /// hour's samples out of memory.
    private static func turns(of url: URL, with diarizer: Nemotron3Diarizer) throws -> [SpeakerSegment] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard Int(rate) == Diarizer.turnConfig.sampleRate else { throw Error.sampleRate(rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate)) else { return [] }
        diarizer.reset()
        var probabilities: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
            diarizer.appendAudio(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            for chunk in try diarizer.processBufferedAudio() { probabilities += chunk.probabilities }
        }
        for chunk in try diarizer.finishStream() { probabilities += chunk.probabilities }
        return SpeakerFrames.segments(
            probabilities: probabilities, speakers: Diarizer.turnConfig.numSpeakers,
            frameMs: Int((Diarizer.turnConfig.outputFrameSeconds * 1000).rounded()),
            threshold: Fixed.meetingTurnThreshold, minimumMs: Fixed.meetingTurnMinimumMs)
    }

    /// One speaker's longest turns joined, up to `budget`, for the
    /// embedding model to hear them alone.
    private static func clip(of speaker: String, segments: [SpeakerSegment], in url: URL, budgetMs budget: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        var clip: [Float] = []
        var taken = 0
        for segment in segments.filter({ $0.speaker == speaker }).sorted(by: { $0.endMs - $0.startMs > $1.endMs - $1.startMs }) {
            guard taken < budget else { break }
            let end = min(segment.endMs, segment.startMs + budget - taken)
            clip += try MeetingTranscriber.read(file, range: segment.startMs..<end)
            taken += end - segment.startMs
        }
        return clip
    }

    /// S3's comparison: the same file through each named configuration of
    /// the pyannote pipeline, with each run's segments and speaker embeddings.
    func compare(url: URL, configurations: [(String, OfflineDiarizerConfig)]) async throws -> [(name: String, segments: [SpeakerSegment], embeddings: [String: [Float]], took: Duration)] {
        let loaded = try await ensureLoaded()
        var out: [(name: String, segments: [SpeakerSegment], embeddings: [String: [Float]], took: Duration)] = []
        for (name, config) in configurations {
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: loaded.models)
            let boxed = Loaded(turns: loaded.turns, models: loaded.models, embedder: manager)
            let started = ContinuousClock.now
            let result = try await Task.detached { try await boxed.embedder.process(url) }.value
            let segments = result.segments.map {
                SpeakerSegment(speaker: $0.speakerId, startMs: Int($0.startTimeSeconds * 1000), endMs: Int($0.endTimeSeconds * 1000))
            }
            out.append((name, segments, result.speakerDatabase ?? [:], ContinuousClock.now - started))
        }
        return out
    }
}
