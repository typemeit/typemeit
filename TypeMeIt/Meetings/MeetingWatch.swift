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

    func start() {
        guard listener == nil else { return }
        apps = ProcessOwner.runningApps()
        listener = AudioProcesses.Listener(queue: queue) { [weak self] why in self?.snapshot(why: why) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(Fixed.meetingWatchPollSeconds), repeating: .seconds(Fixed.meetingWatchPollSeconds))
        timer.setEventHandler { [weak self] in self?.snapshot(why: "poll") }
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
            // Refresh the app list only when an unknown bundle turns up, so
            // the 1 s poll does not walk NSWorkspace every second.
            let known = Set(self.apps.map(\.bundleID))
            if infos.contains(where: { info in info.bundleID.map { id in !known.contains(where: { id == $0 || id.hasPrefix($0 + ".") }) } ?? true }) {
                self.apps = ProcessOwner.runningApps()
            }
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
