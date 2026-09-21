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
    private struct Loaded: @unchecked Sendable { let manager: OfflineDiarizerManager }
    private var loaded: Loaded?

    enum Error: LocalizedError {
        case notInstalled
        var errorDescription: String? { "the speaker model is not installed" }
    }

    private init() {}

    private func ensureLoaded() async throws -> Loaded {
        if let loaded { return loaded }
        guard DiarizerModelStore.isInstalled else { throw Error.notInstalled }
        ModelHub.offlineMode = true
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let started = ContinuousClock.now
        let models = try await OfflineDiarizerModels.load(from: DiarizerModelStore.directory, configuration: configuration)
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig(segmentationStepRatio: Fixed.meetingDiarizerStepRatio))
        manager.initialize(models: models)
        let loaded = Loaded(manager: manager)
        self.loaded = loaded
        Log.meetings.info("Speaker model loaded in \(ContinuousClock.now - started)")
        return loaded
    }

    /// Who spoke when on one track. The embeddings are the run's
    /// `speakerDatabase`, one per speaker, returned in memory for the
    /// caller's matching and never stored (D18).
    func run(url: URL) async throws -> (segments: [SpeakerSegment], embeddings: [String: [Float]]) {
        let loaded = try await ensureLoaded()
        let started = ContinuousClock.now
        let result = try await Task.detached { try await loaded.manager.process(url) }.value
        let segments = result.segments.map {
            SpeakerSegment(speaker: $0.speakerId, startMs: Int($0.startTimeSeconds * 1000), endMs: Int($0.endTimeSeconds * 1000))
        }
        Log.meetings.info("Diarized \(url.lastPathComponent): \(counted(Set(segments.map(\.speaker)).count, "speaker")), \(counted(segments.count, "segment")) in \(ContinuousClock.now - started)")
        return (segments, result.speakerDatabase ?? [:])
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
