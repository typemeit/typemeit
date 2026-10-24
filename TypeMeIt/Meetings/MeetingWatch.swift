import AppKit
import CoreAudio
import Foundation
import Observation

/// Which apps hold the microphone or a speaker right now, grouped by the app
/// that owns the process. Snapshots are taken on the listener's queue on
/// every listener fire and every `Fixed.meetingWatchPollSeconds`, and
/// delivered on the main actor only when the grouped result changed. The
/// poll stays whatever the listeners do: they are the fast path, not the
/// only one (docs/meetings.md 7.3).
@MainActor
@Observable
final class MeetingWatch {
    struct Holder: Equatable, Sendable {
        let owner: ProcessOwner.Owner
        /// Every process object resolved to this owner.
        let objectIDs: [AudioObjectID]
        /// Any of them has input running.
        let input: Bool
        /// Any of them has output running.
        let output: Bool
    }

    private(set) var holders: [Holder] = []
    var onChange: ((_ holders: [Holder]) -> Void)?

    @ObservationIgnored private let queue = DispatchQueue(label: "it.typeme.typemeit.meeting-watch", qos: .utility)
    @ObservationIgnored private var listener: AudioProcesses.Listener?
    @ObservationIgnored private var poll: DispatchSourceTimer?
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var lastGrouped: [Holder] = []
    /// The running apps, refreshed on the main actor before each snapshot is
    /// grouped; NSWorkspace is not for the listener's queue.
    @ObservationIgnored private var apps: [ProcessOwner.RunningApp] = []
    /// Processes that matched no running app when the list was last
    /// refreshed: daemons and bare executables never will, and each would
    /// otherwise have the 1 s poll walk NSWorkspace every second.
    @ObservationIgnored private var unmatched: Set<String> = []
    /// The last snapshot grouped. The poll mostly finds the same processes,
    /// and grouping them again on the main actor is the cost of each second.
    @ObservationIgnored private var lastInfos: [AudioProcessInfo] = []

    func start() {
        guard listener == nil else { return }
        apps = ProcessOwner.runningApps()
        listener = AudioProcesses.Listener(queue: queue) { [weak self] why in self?.snapshot(why: why) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Fixed.meetingWatchPollSeconds), repeating: .seconds(Fixed.meetingWatchPollSeconds))
        // @Sendable, so the closure does not inherit this method's main-actor
        // isolation and trap when the timer fires on the watch queue.
        timer.setEventHandler { @Sendable [weak self] in self?.snapshot(why: "poll") }
        timer.resume()
        poll = timer
        snapshot(why: "start")
    }

    func stop() {
        poll?.cancel()
        poll = nil
        listener = nil
        holders = []
        lastGrouped = []
    }

    /// Runs on `queue`. Groups now and hands the result to the main actor,
    /// which compares and debounces.
    nonisolated private func snapshot(why: String) {
        let infos = AudioProcesses.snapshot()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Refresh the app list only when an unknown process turns up, so
            // the 1 s poll does not walk NSWorkspace every second.
            let unknown = infos.filter { !self.unmatched.contains(MeetingWatch.key($0)) && !MeetingWatch.matches($0, self.apps) }
            if !unknown.isEmpty {
                self.apps = ProcessOwner.runningApps()
                self.lastInfos = []
                for info in unknown where !MeetingWatch.matches(info, self.apps) { self.unmatched.insert(MeetingWatch.key(info)) }
            }
            guard infos != self.lastInfos else { return }
            self.lastInfos = infos
            let grouped = MeetingWatch.group(infos, apps: self.apps)
            guard grouped != self.lastGrouped else { return }
            self.lastGrouped = grouped
            self.debounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.holders = grouped
                DebugLog.write("Meeting watch (\(why)): \(MeetingWatch.describe(grouped))")
                self.onChange?(grouped)
            }
            self.debounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + Fixed.meetingWatchDebounce.timeInterval, execute: item)
        }
    }

    /// Every non-ours, non-ignored owner with input or output, in a stable
    /// order (by bundle id), with the object ids and flags of all its
    /// processes folded together. Pure.
    static func group(_ infos: [AudioProcessInfo], apps: [ProcessOwner.RunningApp]) -> [Holder] {
        var byOwner: [ProcessOwner.Owner: (ids: [AudioObjectID], input: Bool, output: Bool)] = [:]
        for info in infos where info.input || info.output {
            guard !ProcessOwner.isOurs(info), !ProcessOwner.isIgnored(info),
                  let owner = ProcessOwner.owner(of: info, apps: apps) else { continue }
            var entry = byOwner[owner] ?? ([], false, false)
            entry.ids.append(info.objectID)
            entry.input = entry.input || info.input
            entry.output = entry.output || info.output
            byOwner[owner] = entry
        }
        return byOwner
            .map { Holder(owner: $0.key, objectIDs: $0.value.ids.sorted(), input: $0.value.input, output: $0.value.output) }
            .sorted { $0.owner.bundleID < $1.owner.bundleID }
    }

    /// A process as `unmatched` remembers it.
    static func key(_ info: AudioProcessInfo) -> String { info.bundleID ?? info.path ?? String(info.pid) }

    /// Whether a running app in `apps` owns the process by its bundle id.
    /// One without a bundle id is matched by its path, which needs the list
    /// refreshed once.
    static func matches(_ info: AudioProcessInfo, _ apps: [ProcessOwner.RunningApp]) -> Bool {
        guard let id = info.bundleID else { return false }
        return apps.contains { id == $0.bundleID || id.hasPrefix($0.bundleID + ".") }
    }

    static func describe(_ holders: [Holder]) -> String {
        guard !holders.isEmpty else { return "nobody" }
        return holders.map { "\($0.owner.name)[\($0.input ? "in" : "")\($0.output ? "out" : "")]" }.joined(separator: " ")
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
