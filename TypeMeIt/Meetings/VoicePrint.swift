import AVFoundation
import Foundation

/// The user's voice, as the mean of speaker embeddings from their own
/// dictations (docs/meetings.md D15, 9.1). The file holds only that
/// vector and its count; it is deleted when the setting goes off or
/// history is cleared.
enum VoicePrint {
    struct Print: Codable, Equatable, Sendable {
        /// The running sum of L2-normalised embeddings; its direction is the print.
        var centroid: [Float]
        var count: Int
        var updated: Date
    }

    nonisolated static let url = Store.directory.appendingPathComponent("voiceprint.json")

    // MARK: Pure

    static func normalised(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }

    /// Cosine distance: 0 is the same direction, 1 unrelated.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 1 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    /// The print with one more embedding in it. An embedding of another
    /// length (a different model) starts the print again.
    static func folding(_ embedding: [Float], into print: Print?, at date: Date) -> Print {
        let unit = normalised(embedding)
        guard var print, print.centroid.count == unit.count else { return Print(centroid: unit, count: 1, updated: date) }
        for i in unit.indices { print.centroid[i] += unit[i] }
        print.count += 1
        print.updated = date
        return print
    }

    /// Which of a meeting's speakers is the user: the nearest to the print,
    /// when it is within `distance` and at least `margin` nearer than the
    /// runner-up. Nil when nobody is, or when two are too close to call.
    static func match(_ speakers: [String: [Float]], print: [Float], distance limit: Float, margin: Float) -> String? {
        let ranked = speakers.map { (id: $0.key, d: distance($0.value, print)) }.sorted { $0.d < $1.d }
        guard let best = ranked.first, best.d <= limit else { return nil }
        if ranked.count > 1, ranked[1].d - best.d < margin { return nil }
        return best.id
    }
}

extension VoicePrint {
    nonisolated static func load() -> Print? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Print.self, from: data)
    }

    /// The print when there is enough of it to match against.
    nonisolated static func usable() -> Print? {
        guard let print = load(), print.count >= Fixed.meetingVoicePrintMinimumSamples else { return nil }
        return print
    }

    nonisolated static func save(_ print: Print) {
        do {
            try FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(print).write(to: url, options: .atomic)
        } catch {
            Log.meetings.error("Could not save the voice print: \(error.localizedDescription)")
        }
    }
}

/// Grows the print while `Settings.voicePrintEnabled` is on: first from the
/// newest kept dictations, then from each dictation as it happens, until it
/// holds `Fixed.meetingVoicePrintTargetSamples`. Turning it off deletes it.
@MainActor
@Observable
final class VoicePrintKeeper {
    static let shared = VoicePrintKeeper()

    /// How many dictations the print is made of; 0 when there is none.
    private(set) var count = VoicePrint.load()?.count ?? 0
    /// Bumped by `delete()`, so an embedding that was in flight is dropped.
    private var generation = 0

    private var minimumFrames: Int { Fixed.meetingVoicePrintMinimumClipSeconds * Int(AudioCapture.targetFormat.sampleRate) }

    /// Builds the print from the newest kept dictations.
    func start() {
        let generation = generation
        Task {
            let files = ((try? FileManager.default.contentsOfDirectory(at: RecordingArchive.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                .sorted { $0.1 > $1.1 }.map(\.0)
            for file in files {
                guard generation == self.generation, count < Fixed.meetingVoicePrintTargetSamples else { break }
                guard let pcm = await Task.detached(operation: { VoicePrintKeeper.decode(file) }).value, pcm.count >= minimumFrames else { continue }
                await fold(pcm, generation: generation)
            }
            DebugLog.write("Voice print: \(counted(count, "dictation"))")
        }
    }

    /// Adds one dictation's audio while the print is still short of its target.
    func dictated(_ pcm: [Float]) {
        guard Settings.shared.voicePrintEnabled, count < Fixed.meetingVoicePrintTargetSamples, pcm.count >= minimumFrames else { return }
        let generation = generation
        Task { await fold(pcm, generation: generation) }
    }

    func delete() {
        generation += 1
        count = 0
        try? FileManager.default.removeItem(at: VoicePrint.url)
    }

    private func fold(_ pcm: [Float], generation: Int) async {
        guard let embedding = try? await Diarizer.shared.embedding(of: pcm), generation == self.generation,
              count < Fixed.meetingVoicePrintTargetSamples else { return }
        let print = VoicePrint.folding(embedding, into: VoicePrint.load(), at: Date())
        VoicePrint.save(print)
        count = print.count
    }

    nonisolated private static func decode(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
    }
}
