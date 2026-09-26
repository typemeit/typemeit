import AVFoundation
import Foundation

/// Audio behind history entries, kept when the "keep audio" setting is on so a
/// dictation can be played back next to its transcript. Files are AAC at
/// 16 kbps, 16 kHz mono: intelligible speech at roughly 120 KB a minute. A file
/// is named after its history entry's id and goes when the entry does.
enum RecordingArchive {
    static let directory = Store.directory.appendingPathComponent("Recordings", isDirectory: true)

    private static let queue = DispatchQueue(label: "it.typeme.typemeit.recording-archive", qos: .utility)

    static func url(for file: String) -> URL { directory.appendingPathComponent(file) }

    /// Encodes off the main thread; the pipeline does not wait for it.
    /// Returns the file name to store on the history entry.
    static func save(_ pcm: [Float], id: UUID) -> String {
        let file = "\(id.uuidString).m4a"
        queue.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try write(pcm, to: url(for: file))
            } catch {
                Log.audio.error("Could not save recording: \(error.localizedDescription)")
            }
        }
        return file
    }

    static func delete(_ files: [String]) {
        guard !files.isEmpty else { return }
        queue.async {
            for file in files { try? FileManager.default.removeItem(at: url(for: file)) }
        }
    }

    static func deleteAll() {
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    private static func write(_ pcm: [Float], to url: URL) throws {
        let format = AudioCapture.targetFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 16_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "type me it.Audio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not allocate an audio buffer"])
        }
        pcm.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: pcm.count) }
        buffer.frameLength = AVAudioFrameCount(pcm.count)
        try file.write(from: buffer)
    }
}

/// Plays one recording at a time from the history and meetings tabs. A
/// meeting's tracks are several files started together, so its two sides
/// stay aligned.
@MainActor
@Observable
final class RecordingPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = RecordingPlayer()

    /// How far ahead every player is scheduled, so all of them start on the
    /// same device clock tick.
    private static let startLead: TimeInterval = 0.1

    /// The recording loaded, playing or paused.
    private(set) var playing: UUID?
    private(set) var paused = false
    private var players: [AVAudioPlayer] = []

    /// Seconds into what is loaded; 0 when nothing is.
    var currentTime: TimeInterval { players.first?.currentTime ?? 0 }
    var duration: TimeInterval { players.map(\.duration).max() ?? 0 }

    func toggle(_ entry: HistoryEntry) {
        guard let file = entry.recordingFile else { return }
        toggle(id: entry.id, urls: [RecordingArchive.url(for: file)])
    }

    /// Starts every URL at the same moment, or stops if `id` is playing.
    func toggle(id: UUID, urls: [URL]) {
        if playing == id { stop(); return }
        play(id: id, urls: urls, from: 0)
    }

    /// Plays `id` from `seconds`, or from where it was paused; loads its
    /// files first when something else is loaded.
    func play(id: UUID, urls: [URL], from seconds: TimeInterval? = nil) {
        if playing != id {
            stop()
            guard load(id: id, urls: urls) else { return }
        }
        start(from: seconds ?? currentTime)
    }

    func pause() {
        for p in players { p.pause() }
        paused = true
    }

    /// Moves to `seconds`, playing on if it was playing.
    func seek(to seconds: TimeInterval) {
        if paused {
            for p in players { p.currentTime = min(max(0, seconds), p.duration) }
        } else {
            start(from: seconds)
        }
    }

    func stop() {
        for p in players { p.stop() }
        players = []
        playing = nil
        paused = false
    }

    private func load(id: UUID, urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        do {
            players = try urls.map { try AVAudioPlayer(contentsOf: $0) }
            for p in players { p.delegate = self }
            playing = id
            return true
        } catch {
            Log.audio.error("Could not play recording: \(error.localizedDescription)")
            return false
        }
    }

    /// Every track from `seconds`, started on one device clock tick so the
    /// two sides of a call stay aligned.
    private func start(from seconds: TimeInterval) {
        for p in players {
            p.stop()
            p.currentTime = min(max(0, seconds), p.duration)
            p.prepareToPlay()
        }
        let at = (players.first?.deviceCurrentTime ?? 0) + RecordingPlayer.startLead
        for p in players { p.play(atTime: at) }
        paused = false
    }

    /// Stops when what is playing is about to be deleted.
    func stopIfPlaying(any ids: Set<UUID>) {
        if let playing, ids.contains(playing) { stop() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            // The tracks end together; the first to finish takes the rest down.
            self.stop()
        }
    }
}
