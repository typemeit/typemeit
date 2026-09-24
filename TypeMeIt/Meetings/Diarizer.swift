import CoreML
import FluidAudio
import Foundation

/// FluidAudio's offline pipeline (pyannote community-1 segmentation,
/// WeSpeaker embeddings, VBx clustering) behind two functions
/// (docs/meetings.md 8.2). One initialised manager for the life of the
/// process, loaded from the files `DiarizerModelStore` installed and never
/// from the network: `ModelHub.offlineMode` is set before any loader is
/// touched, and `prepareModels` is never called, since its catch path
/// deletes the model folder on any load error.
actor Diarizer {
    static let shared = Diarizer()

    /// FluidAudio's manager is not Sendable; it is used from one detached
    /// task at a time, serialised by this actor.
    private struct Loaded: @unchecked Sendable { let manager: OfflineDiarizerManager; let models: OfflineDiarizerModels }
    private var loaded: Loaded?

    enum Error: LocalizedError {
        case notInstalled
        var errorDescription: String? { "the speaker model is not installed" }
    }

    private init() {}

    /// S3's starting values from michaelwilhelmsen/humla (MIT), measured
    /// against FluidAudio's defaults on two real calls (docs/meetings.md S3):
    /// the same speaker counts, a quiet speaker given more of their own
    /// speech, and half the time. Threshold 0.5 against 0.6 (lower merges
    /// sooner); a turn needs 1.0 s on so a "yeah" does not split a sentence
    /// across speakers, and 0.5 s off so a breath does not end one.
    static let configuration = OfflineDiarizerConfig(
        clusteringThreshold: Fixed.meetingDiarizerThreshold, segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
        segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds)

    private func ensureLoaded() async throws -> Loaded {
        if let loaded { return loaded }
        guard DiarizerModelStore.isInstalled else { throw Error.notInstalled }
        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let started = ContinuousClock.now
        let models = try await OfflineDiarizerModels.load(from: DiarizerModelStore.directory, configuration: configuration)
        let manager = OfflineDiarizerManager(config: Diarizer.configuration)
        manager.initialize(models: models)
        let loaded = Loaded(manager: manager, models: models)
        self.loaded = loaded
        Log.meetings.info("Speaker model loaded in \(ContinuousClock.now - started)")
        return loaded
    }

    /// The shipped settings, told how many speakers when the call said.
    static func configuration(for count: SpeakerCount?) -> OfflineDiarizerConfig {
        switch count {
        case .exactly(let n): configuration.withSpeakers(exactly: n)
        case .atMost(let n): configuration.withSpeakers(max: n)
        case nil: configuration
        }
    }

    /// Who spoke when on one track. The embeddings are the run's
    /// `speakerDatabase`, one per speaker, returned in memory for the
    /// caller's matching and never stored (D18).
    func run(url: URL, count: SpeakerCount? = nil) async throws -> (segments: [SpeakerSegment], embeddings: [String: [Float]]) {
        var loaded = try await ensureLoaded()
        if count != nil {
            let manager = OfflineDiarizerManager(config: Diarizer.configuration(for: count))
            manager.initialize(models: loaded.models)
            loaded = Loaded(manager: manager, models: loaded.models)
        }
        let started = ContinuousClock.now
        let run = loaded
        let result = try await Task.detached { try await run.manager.process(url) }.value
        let segments = result.segments.map {
            SpeakerSegment(speaker: $0.speakerId, startMs: Int($0.startTimeSeconds * 1000), endMs: Int($0.endTimeSeconds * 1000))
        }
        Log.meetings.info("Diarized \(url.lastPathComponent): \(counted(Set(segments.map(\.speaker)).count, "speaker")), \(counted(segments.count, "segment")) in \(ContinuousClock.now - started)")
        return (segments, result.speakerDatabase ?? [:])
    }

    /// S3's comparison: the same file through each named configuration,
    /// on the loaded models, with each run's segments and speaker embeddings.
    func compare(url: URL, configurations: [(String, OfflineDiarizerConfig)]) async throws -> [(name: String, segments: [SpeakerSegment], embeddings: [String: [Float]], took: Duration)] {
        let loaded = try await ensureLoaded()
        var out: [(name: String, segments: [SpeakerSegment], embeddings: [String: [Float]], took: Duration)] = []
        for (name, config) in configurations {
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: loaded.models)
            let boxed = Loaded(manager: manager, models: loaded.models)
            let started = ContinuousClock.now
            let result = try await Task.detached { try await boxed.manager.process(url) }.value
            let segments = result.segments.map {
                SpeakerSegment(speaker: $0.speakerId, startMs: Int($0.startTimeSeconds * 1000), endMs: Int($0.endTimeSeconds * 1000))
            }
            out.append((name, segments, result.speakerDatabase ?? [:], ContinuousClock.now - started))
        }
        return out
    }

    /// The embedding of a one-speaker clip (16 kHz mono), or nil unless
    /// exactly one speaker came out, so a voice print and a meeting's
    /// speakers come from one model.
    func embedding(of pcm: [Float]) async throws -> [Float]? {
        let loaded = try await ensureLoaded()
        let result = try await Task.detached { try await loaded.manager.process(audio: pcm) }.value
        guard let database = result.speakerDatabase, database.count == 1 else { return nil }
        return database.values.first
    }
}
