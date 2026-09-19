import AppKit
import CoreAudio

/// Pauses whatever is playing while recording by pressing the play/pause
/// media key, the way F8 does, and presses it again afterwards. The key
/// is a toggle, so it is only pressed when another process is running
/// audio output; pressing it into silence would start playback.
@MainActor
enum MediaPause {
    /// Two media key presses closer than this read as one gesture to the
    /// system, and the second is lost.
    private static let minimumKeyGap: TimeInterval = 1.5

    private static var pressedAt: Date?

    private static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T) -> T? {
        var address = global(selector)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Bundle ids of the processes other than this one with output running,
    /// from CoreAudio's per-process objects. The app's own cues keep a
    /// stream open and must not count.
    private static func playingProcesses() -> [String] {
        var address = global(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return objects.compactMap { object in
            guard property(object, kAudioProcessPropertyPID, pid_t(0)) != me,
                  property(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0 else { return nil }
            let bundle: CFString? = property(object, kAudioProcessPropertyBundleID, "" as CFString)
            return (bundle as String?) ?? "pid \(property(object, kAudioProcessPropertyPID, pid_t(0)) ?? 0)"
        }
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
        guard pressedAt == nil else { return }
        let playing = playingProcesses()
        guard !playing.isEmpty else { DebugLog.write("Pause: nothing playing"); return }
        DebugLog.write("Pause: play/pause pressed, output running in \(playing.joined(separator: ", "))")
        pressedAt = Date()
        pressPlayPause()
    }

    /// Presses again to resume, no sooner than `minimumKeyGap` after the
    /// pause press.
    static func resume() {
        guard let pressedAt else { return }
        self.pressedAt = nil
        let wait = max(0, minimumKeyGap - Date().timeIntervalSince(pressedAt))
        DebugLog.write("Pause: play/pause pressed again to resume\(wait > 0 ? String(format: ", after %.1f s", wait) : "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { pressPlayPause() }
    }
}
