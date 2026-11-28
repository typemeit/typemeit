import AppKit

/// Pauses whatever is playing while recording by pressing the play/pause
/// media key, the way F8 does, and presses it again afterwards. The key
/// is a toggle, so it is only pressed when another process is running
/// audio output; pressing it into silence would start playback.
@MainActor
enum MediaPause {
    /// Two media key presses closer than this read as one gesture to the
    /// system, and the second is lost.
    private static let minimumKeyGap: TimeInterval = 1.5

    private enum Press {
        case idle
        /// The first press paused playback.
        case paused(at: Date)
        /// The second press waits out `minimumKeyGap`. Cancelling it leaves
        /// playback paused from the first press.
        case resumePending(Task<Void, Never>, pausedAt: Date)
    }

    private static var press: Press = .idle

    /// Bundle ids of the processes other than this one with output running,
    /// from CoreAudio's per-process objects. The app's own cues keep a
    /// stream open and must not count.
    private static func playingProcesses() -> [String] {
        AudioProcesses.snapshot().filter { $0.output && !ProcessOwner.isOurs($0) }.map { $0.bundleID ?? "pid \($0.pid)" }
    }

    private static let playPauseKey = Int(NX_KEYTYPE_PLAY)

    /// Posts the media key down and up as the system-defined events the
    /// keyboard driver sends for F8. Needs Accessibility, like the paste.
    private static func pressPlayPause() {
        for down in [true, false] {
            let flags: UInt = down ? 0xa00 : 0xb00
            let state = down ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: flags),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (playPauseKey << 16) | (state << 8), data2: -1)
            guard let cg = event?.cgEvent else { Log.audio.error("Could not create media key event"); return }
            cg.post(tap: .cghidEventTap)
        }
    }

    static func pause() {
        switch press {
        case .paused:
            return
        case .resumePending(let resumePress, let pausedAt):
            // A new recording inside the gap: playback is still paused, so the resume press is called off.
            resumePress.cancel()
            press = .paused(at: pausedAt)
            DebugLog.write("Pause: resume called off, playback stays paused")
            return
        case .idle:
            break
        }
        let playing = playingProcesses()
        guard !playing.isEmpty else { DebugLog.write("Pause: nothing playing"); return }
        DebugLog.write("Pause: play/pause pressed, output running in \(playing.joined(separator: ", "))")
        press = .paused(at: Date())
        pressPlayPause()
    }

    /// Presses again to resume, no sooner than `minimumKeyGap` after the
    /// pause press.
    static func resume() {
        guard case .paused(let pausedAt) = press else { return }
        let wait = max(0, minimumKeyGap - Date().timeIntervalSince(pausedAt))
        DebugLog.write("Pause: play/pause pressed again to resume\(wait > 0 ? String(format: ", after %.1f s", wait) : "")")
        let resumePress = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            press = .idle
            pressPlayPause()
        }
        press = .resumePending(resumePress, pausedAt: pausedAt)
    }
}
