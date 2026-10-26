import AVFoundation
import Foundation

/// The voices `VoiceNames` learns from (docs/meetings.md 8.7): for each
/// transcribed meeting, an embedding of every clip of every speaker, in
/// `SupportPaths.directory/Voices/<meeting id>.json`. Never in the meeting's own
/// folder, which the MCP reads and the user shares. Kept only while
/// `Settings.meetingLearnVoices` is on; turning it off deletes the folder.
/// Who a voice belongs to is read from the meetings each time names are
/// suggested, so a rename teaches it without a second copy of any name.
actor VoiceLibrary {
    static let shared = VoiceLibrary()
    nonisolated static let directory = SupportPaths.directory.appendingPathComponent("Voices", isDirectory: true)

    private struct VoiceFile: Codable {
        var dimensions: Int
        /// How the clips were embedded (`VoiceLibrary.embedding`); absent
        /// in files learned from zero-padded clips.
        var embedding: String?
        /// Each speaker's clip embeddings, `dimensions` Float32s apiece, end to end.
        var speakers: [String: Data]
    }

    /// Clips read and embedded at a time: about 10 MB of audio, where a
    /// whole hour's clips at once would be hundreds.
    private static let clipsPerBatch = 16

    /// What `Diarizer.voices(of:)` makes: clips tiled to fill the window.
    /// A clip under 6 s embedded zero-padded comes out unrelated to the same
    /// clip tiled (median cosine 0.0–0.16), so files from before are relearned.
    private static let embedding = "tiled"

    /// Bumped by `forgetAll`, so a meeting still being learned when the
    /// setting goes off is not written.
    private var generation = 0
    /// Every file read so far, by meeting; `learn` and `forget` keep it current.
    private var voices: [UUID: [String: [[Float]]]] = [:]
    private var readAll = false
    /// The last model trained, with what it was trained on.
    private var cached: (key: String, model: VoiceNames.Model)?
    /// The model being trained, with what it is trained on. A meeting's page
    /// asks for suggestions on every change to any meeting, and the actor
    /// takes the next call while one waits on training: without this, each
    /// call that came in before the first finished started a training of its own.
    private var training: (key: String, task: Task<VoiceNames.Model?, Never>)?

    private init() {}

    private static func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    // MARK: Learning

    /// Cuts the meeting's clips from its tracks in `folder` and keeps one
    /// embedding for each.
    func learn(_ meeting: Meeting, folder: URL) async {
        let generation = generation
        let started = ContinuousClock.now
        do {
            let longestMs = try await Diarizer.shared.voiceWindowSamples() / Meeting.framesPerMs
            let clips = VoiceNames.clips(of: meeting, longestMs: longestMs, shortestMs: Fixed.meetingVoiceShortestMs,
                                         crosstalkShare: Fixed.meetingVoiceCrosstalkShare, echoPadMs: Fixed.meetingVoiceEchoPadMs)
            let tracks = Dictionary(meeting.tracks.map { ($0.role, folder.appendingPathComponent($0.file)) }, uniquingKeysWith: { first, _ in first })
            var bySpeaker: [String: [[Float]]] = [:]
            for start in stride(from: 0, to: clips.count, by: VoiceLibrary.clipsPerBatch) {
                let batch = Array(clips[start..<min(start + VoiceLibrary.clipsPerBatch, clips.count)])
                let audio = try await Task.detached { try VoiceLibrary.read(batch, tracks: tracks) }.value
                let embedded = try await Diarizer.shared.voices(of: audio)
                for (clip, vector) in zip(batch, embedded) where !vector.isEmpty { bySpeaker[clip.speaker, default: []].append(vector) }
            }
            guard generation == self.generation, let dimensions = bySpeaker.values.first?.first?.count else { return }
            let file = VoiceFile(dimensions: dimensions, embedding: VoiceLibrary.embedding, speakers: bySpeaker.mapValues { VoiceLibrary.data($0) })
            try FileManager.default.createDirectory(at: VoiceLibrary.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(file).write(to: VoiceLibrary.url(for: meeting.id), options: .atomic)
            voices[meeting.id] = bySpeaker
            // A relearned meeting keeps its clip counts, which is all `cached`'s key sees.
            cached = nil
            DebugLog.write("Meeting voices learned: \(counted(clips.count, "clip")) of \(counted(bySpeaker.count, "speaker")) in \(ContinuousClock.now - started)")
        } catch {
            Log.meetings.error("Could not learn the meeting's voices: \(error.localizedDescription)")
        }
    }

    /// Learns each done meeting whose audio was kept and whose voices are
    /// not here yet, or were embedded another way: when the setting goes
    /// on, and at launch. Voices embedded another way with no audio left to
    /// relearn from are deleted.
    func learnMissing(_ meetings: [(meeting: Meeting, folder: URL)]) async {
        for (meeting, folder) in meetings where meeting.isDone {
            let url = VoiceLibrary.url(for: meeting.id)
            if FileManager.default.fileExists(atPath: url.path) {
                guard VoiceLibrary.file(at: url) == nil else { continue }
                if meeting.audioFiles.isEmpty { forget([meeting.id]); continue }
                voices[meeting.id] = nil
            }
            guard !meeting.audioFiles.isEmpty else { continue }
            await learn(meeting, folder: folder)
        }
    }

    func forget(_ ids: Set<UUID>) {
        for id in ids {
            try? FileManager.default.removeItem(at: VoiceLibrary.url(for: id))
            voices[id] = nil
        }
    }

    func forgetAll() {
        generation += 1
        try? FileManager.default.removeItem(at: VoiceLibrary.directory)
        voices = [:]
        readAll = false
        cached = nil
    }

    // MARK: Suggesting

    /// A name for each of the meeting's numbered speakers whose voice is
    /// someone's named in `meetings`, when the model is sure enough.
    func suggestions(for meeting: Meeting, among meetings: [Meeting]) async -> [String: String] {
        let unnamed = Set(SpeakerAssign.unknown(in: meeting).map(\.id))
        loadAll()
        guard !unnamed.isEmpty, let file = voices[meeting.id] else { return [:] }
        let heard = VoiceNames.regrouped(file, in: meeting)
        var examples: [(name: String, vector: [Float])] = []
        var trainedOn: [String] = []
        for other in meetings {
            guard let file = voices[other.id] else { continue }
            let clips = VoiceNames.regrouped(file, in: other)
            for speaker in other.speakers {
                guard let name = VoiceNames.label(of: speaker), let vectors = clips[speaker.id] else { continue }
                examples += vectors.map { (name, $0) }
                trainedOn.append("\(other.id) \(speaker.id) \(name) \(vectors.count)")
            }
        }
        let key = trainedOn.sorted().joined(separator: "\n")
        let model: VoiceNames.Model
        if let cached, cached.key == key {
            model = cached.model
        } else {
            let task: Task<VoiceNames.Model?, Never>
            if let training, training.key == key {
                task = training.task
            } else {
                // A training for names that have since changed is no longer wanted.
                training?.task.cancel()
                let trainingSet = examples
                task = Task.detached {
                    VoiceNames.Model.train(trainingSet, steps: Fixed.meetingVoiceTrainingSteps, rate: Fixed.meetingVoiceTrainingRate, momentum: Fixed.meetingVoiceTrainingMomentum)
                }
                training = (key, task)
            }
            let trained = await task.value
            if training?.key == key { training = nil }
            guard let trained else { return [:] }
            cached = (key, trained)
            model = trained
        }
        return VoiceNames.suggestions(for: heard.filter { unnamed.contains($0.key) }, taken: Set(meeting.speakers.compactMap(VoiceNames.label(of:))),
                                      model: model, minimum: Fixed.meetingVoiceSuggestPosterior, minimumClips: Fixed.meetingVoiceMinimumClips)
    }

    // MARK: Files

    /// The meetings whose voices are on disk, read without waiting on the actor.
    nonisolated static func learnedIDs() -> Set<UUID> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return Set(files.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
    }

    private func loadAll() {
        guard !readAll else { return }
        readAll = true
        for id in VoiceLibrary.learnedIDs() where voices[id] == nil {
            guard let file = VoiceLibrary.file(at: VoiceLibrary.url(for: id)) else { continue }
            voices[id] = file.speakers.mapValues { VoiceLibrary.vectors($0, dimensions: file.dimensions) }
        }
    }

    /// The file's voices, or nil when it cannot be read or was embedded another way.
    private static func file(at url: URL) -> VoiceFile? {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(VoiceFile.self, from: data),
              file.embedding == embedding else { return nil }
        return file
    }

    private static func read(_ clips: [VoiceNames.Clip], tracks: [Meeting.Track.Role: URL]) throws -> [[Float]] {
        var files: [Meeting.Track.Role: AVAudioFile] = [:]
        return try clips.map { clip in
            guard let url = tracks[clip.role] else { return [] }
            if files[clip.role] == nil { files[clip.role] = try AVAudioFile(forReading: url) }
            return try MeetingTranscriber.read(files[clip.role]!, range: clip.range)
        }
    }

    private static func data(_ vectors: [[Float]]) -> Data {
        vectors.flatMap { $0 }.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func vectors(_ data: Data, dimensions: Int) -> [[Float]] {
        let width = dimensions * MemoryLayout<Float>.size
        guard width > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - width + 1, by: width).map { offset in
                (0..<dimensions).map { raw.loadUnaligned(fromByteOffset: offset + $0 * MemoryLayout<Float>.size, as: Float.self) }
            }
        }
    }
}
