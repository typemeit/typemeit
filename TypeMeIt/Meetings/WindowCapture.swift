import AppKit
import ApplicationServices
import Foundation
import Observation

/// Dev builds' Capture Meet Window and Capture Slack Window: what the
/// meeting window exposes for `seconds`, the whole tree at the start and at
/// the end and what appeared and went at every poll between, which is where
/// a speaking indicator shows. The name rules are written from these
/// (docs/meetings.md 8.6). Written to `MeetingProbes.directory`; it holds
/// whatever the window shows and stays on this Mac.
@MainActor
@Observable
final class WindowCapture {
    static let shared = WindowCapture()
    nonisolated static let seconds = 180
    /// Time for the app to build its accessibility tree once asked to.
    nonisolated static let settleSeconds = 2

    private(set) var running: Roster.Target?

    private init() {}

    func start(_ target: Roster.Target) {
        guard running == nil else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { target.bundleIDs.contains($0.bundleIdentifier ?? "") && $0.activationPolicy == .regular }) else {
            DebugLog.write("Window capture: no \(target.rawValue) app is running")
            return
        }
        running = target
        DebugLog.write("Window capture: \(target.rawValue) in \(app.localizedName ?? "?") for \(WindowCapture.seconds) s")
        let pid = app.processIdentifier
        Run(pid: pid, target: target).start { file in
            Task { @MainActor in
                self.running = nil
                // The recording's own reader needs the tree left on.
                if MeetingCoordinator.shared.recording == nil {
                    AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), target.activation as CFString, kCFBooleanFalse)
                }
                DebugLog.write("Window capture: \(file?.lastPathComponent ?? "not written")")
            }
        }
    }

    /// One capture's state, touched only on its queue.
    private final class Run: @unchecked Sendable {
        let pid: pid_t
        let target: Roster.Target
        private let queue = DispatchQueue(label: "it.typeme.typemeit.window-capture", qos: .utility)
        private var timer: DispatchSourceTimer?
        private var lines: [String] = []
        private var previous: Set<String>?
        private let began = ContinuousClock.now
        private let file: URL

        init(pid: pid_t, target: Roster.Target) {
            self.pid = pid
            self.target = target
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            file = MeetingProbes.directory.appendingPathComponent("capture-\(target.rawValue)-\(stamp).txt")
            lines = ["\(target.rawValue) window, from \(ISO8601DateFormatter().string(from: Date())), every \(Fixed.meetingSpeakingPollMs) ms"]
        }

        func start(done: @escaping @Sendable (URL?) -> Void) {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), target.activation as CFString, kCFBooleanTrue)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(WindowCapture.settleSeconds), repeating: .milliseconds(Fixed.meetingSpeakingPollMs))
            timer.setEventHandler { [self] in tick(done: done) }
            timer.resume()
            self.timer = timer
        }

        private func tick(done: @Sendable (URL?) -> Void) {
            let ms = (ContinuousClock.now - began).milliseconds
            let current = Roster.windowLines(pid: pid, target: target)
            let now = Set(current)
            if let previous {
                let gone = previous.subtracting(now).sorted(), came = now.subtracting(previous).sorted()
                if !gone.isEmpty || !came.isEmpty { lines += ["t=\(ms)"] + gone.map { "- " + $0 } + came.map { "+ " + $0 } }
            } else {
                lines += ["snapshot at \(ms) ms"] + current
            }
            previous = now
            guard ms >= WindowCapture.seconds * 1000 else { return }
            timer?.cancel()
            timer = nil
            lines += ["snapshot at \(ms) ms"] + current
            do {
                try FileManager.default.createDirectory(at: MeetingProbes.directory, withIntermediateDirectories: true)
                try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                done(file)
            } catch {
                DebugLog.write("Window capture: \(error.localizedDescription)")
                done(nil)
            }
        }
    }
}
