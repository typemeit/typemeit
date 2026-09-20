import AppKit
import AVFoundation
import Foundation
import Observation

/// The list of meetings: every `meeting.json` under the published folder and
/// under staging, newest first (docs/meetings.md 7.9). Holds the list only;
/// what is recording or transcribing right now is the coordinator's.
@MainActor
@Observable
final class MeetingStore {
    static let shared = MeetingStore()

    private(set) var meetings: [Meeting] = []
    /// Bytes under the published folder, nil while it does not resolve.
    private(set) var diskUsage: Int64?
    /// The published folder resolves; false for an ejected disk or an
    /// offline share, when the store carries on with staging alone.
    private(set) var folderAvailable = true

    @ObservationIgnored private var folders: [UUID: URL] = [:]
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath: String?

    var publishedRoot: URL { Settings.shared.meetingsFolder ?? MeetingFolder.defaultPublishedRoot }

    private init() {
        reload()
    }

    func folder(for id: UUID) -> URL? { folders[id] }

    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }

    // MARK: Reading

    /// Re-reads both roots. Called at launch, when the published folder
    /// changes on disk, and when the setting moves it.
    func reload() {
        let root = publishedRoot
        folderAvailable = FileManager.default.fileExists(atPath: root.path) || (MeetingFolder.parentResolves(root) && Settings.shared.meetingsFolder == nil)
        var found: [(URL, Meeting)] = MeetingFolder.meetings(under: MeetingFolder.stagingRoot)
        if folderAvailable { found += MeetingFolder.meetings(under: root) }
        var byId: [UUID: (URL, Meeting)] = [:]
        for (url, meeting) in found { byId[meeting.id] = (url, meeting) }
        folders = byId.mapValues { $0.0 }
        meetings = byId.values.map { $0.1 }.sorted { $0.started > $1.started }
        diskUsage = folderAvailable ? MeetingFolder.diskUsage(of: root) : nil
        watch(root)
    }

    /// Re-reads when the published folder changes: a rename or a delete in
    /// Finder is just a move, since `meeting.json` carries the id.
    private func watch(_ root: URL) {
        guard watchedPath != root.path else { return }
        watcher?.cancel()
        watcher = nil
        watchedPath = nil
        let fd = open(root.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) {
                self.watcher?.cancel()
                self.watcher = nil
                self.watchedPath = nil
            }
            self.reload()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        watchedPath = root.path
    }

    // MARK: Writing

    /// Writes the JSON atomically and renders the Markdown, into the folder
    /// the meeting is in.
    func save(_ meeting: Meeting) {
        let folder = folders[meeting.id] ?? MeetingFolder.staged(meeting.id)
        folders[meeting.id] = folder
        do { try MeetingFolder.write(meeting, to: folder) } catch {
            Log.meetings.error("Could not write meeting \(meeting.id): \(error.localizedDescription)")
        }
        if let i = meetings.firstIndex(where: { $0.id == meeting.id }) { meetings[i] = meeting } else { meetings.append(meeting); meetings.sort { $0.started > $1.started } }
        if meeting.published { diskUsage = folderAvailable ? MeetingFolder.diskUsage(of: publishedRoot) : nil }
    }

    /// A user title. Rewrites the title part of the folder name only.
    func rename(id: UUID, title: String) {
        guard var meeting = meeting(id), let folder = folders[id] else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != meeting.title else { return }
        meeting.title = trimmed
        meeting.titleSource = .user
        if meeting.published {
            let root = folder.deletingLastPathComponent()
            let name = MeetingFolder.name(started: meeting.started, zone: TimeZone(identifier: meeting.timeZone) ?? .current, duration: meeting.duration, title: trimmed,
                                          existing: MeetingFolder.existingNames(under: root).filter { $0 != folder.lastPathComponent })
            let destination = root.appendingPathComponent(name, isDirectory: true)
            do {
                try FileManager.default.moveItem(at: folder, to: destination)
                folders[id] = destination
            } catch {
                Log.meetings.error("Could not rename the meeting folder: \(error.localizedDescription)")
            }
        }
        save(meeting)
    }

    /// Phase 2: a speaker's name, per meeting.
    func rename(speaker: String, to name: String, in id: UUID) {
        guard var meeting = meeting(id), let i = meeting.speakers.firstIndex(where: { $0.id == speaker }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meeting.speakers[i].name = trimmed
        save(meeting)
    }

    /// Moves the folders to the Trash.
    func delete(ids: Set<UUID>) {
        let urls = ids.compactMap { folders[$0] }
        RecordingPlayer.shared.stopIfPlaying(any: ids)
        MeetingFolder.recycle(urls)
        for id in ids { folders[id] = nil }
        meetings.removeAll { ids.contains($0.id) }
        diskUsage = folderAvailable ? MeetingFolder.diskUsage(of: publishedRoot) : nil
    }

    func deleteAll() {
        delete(ids: Set(meetings.map(\.id)))
    }

    /// Applies `Settings.meetingLimit` newest first; 0 keeps everything.
    /// Only published, transcribed meetings count and go.
    func prune() {
        let limit = Settings.shared.meetingLimit
        guard limit > 0 else { return }
        let published = meetings.filter { $0.published && $0.isDone }
        guard published.count > limit else { return }
        delete(ids: Set(published.dropFirst(limit).map(\.id)))
    }

    /// Adopts a meeting the recorder wrote into staging.
    func adopt(_ meeting: Meeting, folder: URL) {
        folders[meeting.id] = folder
        if !meetings.contains(where: { $0.id == meeting.id }) {
            meetings.append(meeting)
            meetings.sort { $0.started > $1.started }
        }
    }

    /// Forgets a meeting whose folder was deleted (a call too short to keep).
    func drop(_ id: UUID) {
        folders[id] = nil
        meetings.removeAll { $0.id == id }
    }

    // MARK: Publishing

    /// Moves a transcribed meeting from staging to the published folder,
    /// named with its duration. False when the folder does not resolve,
    /// in which case the meeting stays staged and is tried again later.
    @discardableResult
    func publish(_ id: UUID) -> Bool {
        guard var meeting = meeting(id), let folder = folders[id], !meeting.published, meeting.isDone else { return false }
        let root = publishedRoot
        guard MeetingFolder.parentResolves(root) else {
            folderAvailable = false
            return false
        }
        let name = MeetingFolder.name(started: meeting.started, zone: TimeZone(identifier: meeting.timeZone) ?? .current,
                                      duration: meeting.duration, title: meeting.title, existing: MeetingFolder.existingNames(under: root))
        do {
            let destination = try MeetingFolder.move(folder, under: root, name: name)
            folders[id] = destination
            meeting.published = true
            folderAvailable = true
            save(meeting)
            DebugLog.write("Meeting published: \(name)")
            return true
        } catch {
            Log.meetings.error("Could not publish the meeting: \(error.localizedDescription)")
            folderAvailable = false
            return false
        }
    }

    /// Every done, unpublished meeting: at launch and whenever the folder
    /// resolves again.
    func republishPending() {
        let pending = meetings.filter { $0.isDone && !$0.published }.map(\.id)
        guard !pending.isEmpty else { return }
        guard MeetingFolder.parentResolves(publishedRoot) else { return }
        for id in pending { publish(id) }
    }

    /// Staged meetings left from a quit or a crash: one still marked
    /// recording gets its end from its track's length, then every staged
    /// meeting not yet done is returned for transcription.
    func recoverAtLaunch() -> [Meeting] {
        var toTranscribe: [Meeting] = []
        for var meeting in meetings where !meeting.published && !meeting.isDone {
            guard let folder = folders[meeting.id] else { continue }
            if meeting.ended == nil {
                var longest = 0
                for i in meeting.tracks.indices {
                    let url = folder.appendingPathComponent(meeting.tracks[i].file)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    meeting.tracks[i].frames = TrackWriter.frames(inFileOfSize: size)
                    longest = max(longest, meeting.tracks[i].frames)
                }
                meeting.durationMs = longest / Meeting.framesPerMs
                meeting.recordedMs = meeting.durationMs
                meeting.ended = meeting.started.addingTimeInterval(TimeInterval(meeting.durationMs) / 1000)
                if meeting.kind == .call, meeting.durationMs < Fixed.meetingMinimumSeconds * 1000 {
                    DebugLog.write("Meeting recovered at launch and dropped: \(meeting.durationMs) ms")
                    try? FileManager.default.removeItem(at: folder)
                    drop(meeting.id)
                    continue
                }
                DebugLog.write("Meeting recovered at launch: \(meeting.durationMs) ms recorded")
                save(meeting)
            }
            if meeting.transcription.state == .running { meeting.transcription.state = .pending; save(meeting) }
            toTranscribe.append(meeting)
        }
        return toTranscribe
    }

    /// The meetings waiting for the speech model to be installed.
    var pendingForModel: [Meeting] { meetings.filter { $0.transcription.state == .pending && !$0.published } }
}
