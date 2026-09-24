import AVFoundation
import Foundation

/// A call recorded again soon after its last recording ended (you left and
/// came back, or the app dropped the mic for longer than the 30 s a pause
/// covers) is joined onto that meeting instead of becoming a second one.
/// The key is the app, plus the Meet code or the huddle's channel when the
/// window was read: two recordings whose keys both say which call they
/// were must say the same one. The earlier meeting's tracks and the new
/// ones are joined end to end with the time between them as silence, and
/// the whole meeting is transcribed again so its speakers are found once.
enum MeetingMerge {
    /// The meeting `new` continues, if any: the latest call from the same
    /// app that ended within `window` before `new` started, whose call key
    /// does not contradict `new`'s, and whose audio was kept. Pure.
    static func previous(of new: Meeting, among meetings: [Meeting], window: TimeInterval) -> Meeting? {
        guard new.kind == .call, new.source == nil, let app = new.app else { return nil }
        return meetings
            .filter { m in
                guard m.id != new.id, m.kind == .call, m.source == nil, m.app?.bundleId == app.bundleId, m.continues == nil,
                      !m.tracks.isEmpty, m.transcription.state == .done ? !m.audioFiles.isEmpty : true else { return false }
                if let a = m.names?.call, let b = new.names?.call, a != b { return false }
                let gap = new.started.timeIntervalSince(end(of: m))
                // The new recording's held minute can reach back past the
                // old one's end; a little overlap is still a rejoin.
                return gap <= window && gap >= -Double(Fixed.meetingPreRollSeconds)
            }
            .max { end(of: $0) < end(of: $1) }
    }

    /// Where a meeting's audio ends: its start plus its length, which
    /// includes the silence written while it waited for a rejoin.
    static func end(of meeting: Meeting) -> Date {
        meeting.started.addingTimeInterval(Double(meeting.durationMs) / 1000)
    }

    /// Milliseconds of silence between `earlier`'s audio and `later`'s; never negative.
    static func gapMs(_ earlier: Meeting, _ later: Meeting) -> Int {
        max(0, Int(later.started.timeIntervalSince(end(of: earlier)) * 1000))
    }

    /// `earlier` with `later` joined on after `gapMs` of silence, reset for
    /// a full transcription. Tracks name CAF files the audio join writes.
    /// Pure.
    static func joined(_ earlier: Meeting, _ later: Meeting, gapMs: Int) -> Meeting {
        var m = earlier
        let offset = earlier.durationMs + gapMs
        let gap = Meeting.Span(startMs: earlier.durationMs, endMs: offset)
        func shifted(_ s: Meeting.Span) -> Meeting.Span { Meeting.Span(startMs: s.startMs + offset, endMs: s.endMs + offset) }
        m.tracks = earlier.tracks.map { track in
            let other = later.tracks.first { $0.role == track.role }
            var t = track
            t.file = "\(track.role.rawValue).caf"
            t.frames = offset * Meeting.framesPerMs + later.durationMs * Meeting.framesPerMs
            t.gaps = track.gaps + (gapMs > 0 ? [gap] : []) + (other?.gaps ?? [Meeting.Span(startMs: 0, endMs: later.durationMs)]).map(shifted)
            t.peak = max(track.peak ?? 0, other?.peak ?? 0)
            return t
        }
        m.durationMs = offset + later.durationMs
        m.recordedMs = earlier.recordedMs + later.recordedMs
        m.ended = later.ended
        m.bothSilentMs = earlier.bothSilentMs + later.bothSilentMs
        m.dictations = earlier.dictations + later.dictations.map { Meeting.Dictation(startMs: $0.startMs + offset, endMs: $0.endMs + offset, historyId: $0.historyId) }
        m.names = joinedNames(earlier.names, later.names, offsetMs: offset)
        m.echo = .notMeasured
        m.transcription = Meeting.Transcription(state: .pending)
        m.paragraphs = []
        m.summary = nil
        if m.titleSource == .generated || m.titleSource == .roster {
            m.title = m.app?.name ?? m.title
            m.titleSource = .app
        }
        return m
    }

    /// Both recordings' names, the later one's times moved along; the
    /// better source of the two wins.
    static func joinedNames(_ a: MeetingNames?, _ b: MeetingNames?, offsetMs: Int) -> MeetingNames? {
        guard let b else { return a }
        let moved = MeetingNames(
            source: b.source, roster: b.roster, channel: b.channel,
            spans: b.spans.map { MeetingNames.Span(name: $0.name, startMs: $0.startMs + offsetMs, endMs: $0.endMs + offsetMs) },
            captions: b.captions?.map { MeetingNames.Caption(name: $0.name, startMs: $0.startMs + offsetMs, text: $0.text) },
            call: b.call)
        guard let a else { return moved }
        let rank: [MeetingNames.Source] = [.captions, .speaking, .roster, .user]
        let source = [a.source, b.source].min { rank.firstIndex(of: $0)! < rank.firstIndex(of: $1)! }!
        let captions = (a.captions ?? []) + (moved.captions ?? [])
        return MeetingNames(
            source: source, roster: a.roster + b.roster.filter { !a.roster.contains($0) }, channel: a.channel ?? b.channel,
            spans: a.spans + moved.spans, captions: captions.isEmpty ? nil : captions, call: a.call ?? b.call)
    }

    /// Writes the joined tracks into `earlierFolder`, removes the old files
    /// there and returns each track's frames and peak; `later`'s folder is
    /// left for the caller to delete. `later` starts at exactly
    /// `earlier.durationMs + gapMs` on every track, whatever length the
    /// earlier file decodes to.
    static func joinAudio(_ earlier: Meeting, in earlierFolder: URL, _ later: Meeting, in laterFolder: URL, gapMs: Int) throws -> [Meeting.Track.Role: (frames: Int, peak: Float)] {
        let laterStart = (earlier.durationMs + gapMs) * Meeting.framesPerMs
        var out: [Meeting.Track.Role: (frames: Int, peak: Float)] = [:]
        for track in earlier.tracks {
            let merged = earlierFolder.appendingPathComponent("\(track.role.rawValue).merged.caf")
            let writer = try TrackWriter(url: merged)
            try copy(earlierFolder.appendingPathComponent(track.file), into: writer, upTo: laterStart)
            writer.appendSilence(frames: laterStart - writer.framesWritten)
            if let other = later.tracks.first(where: { $0.role == track.role }) {
                try copy(laterFolder.appendingPathComponent(other.file), into: writer, upTo: nil)
            } else {
                writer.appendSilence(frames: later.durationMs * Meeting.framesPerMs)
            }
            out[track.role] = writer.finish()
        }
        // Every joined file is written before any old one goes, so a
        // failure part way leaves the earlier meeting as it was.
        for track in earlier.tracks {
            let merged = earlierFolder.appendingPathComponent("\(track.role.rawValue).merged.caf")
            let old = earlierFolder.appendingPathComponent(track.file)
            let final = earlierFolder.appendingPathComponent("\(track.role.rawValue).caf")
            if FileManager.default.fileExists(atPath: old.path) { try FileManager.default.removeItem(at: old) }
            if old != final, FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
            try FileManager.default.moveItem(at: merged, to: final)
        }
        return out
    }

    /// A second of audio at a time, so an hour costs a second's memory;
    /// never past `limit` frames written, when given.
    private static func copy(_ url: URL, into writer: TrackWriter, upTo limit: Int?) throws {
        let file = try AVAudioFile(forReading: url)
        let rate = Int(file.processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate)) else { return }
        var written = writer.framesWritten
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(rate))
            guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { break }
            var count = Int(buffer.frameLength)
            if let limit { count = min(count, limit - written) }
            guard count > 0 else { break }
            writer.append(Array(UnsafeBufferPointer(start: data, count: count)))
            written += count
        }
    }
}
