import AppKit
import CoreAudio

/// Pauses whatever is playing while recording by pressing the play/pause
/// media key, the way F8 does, and presses it again afterwards. The key
/// is a toggle, so it is only pressed when the default output device has
/// audio running through it; pressing it into silence would start playback.
@MainActor
enum MediaPause {
    private static var paused = false

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    /// Whether any process has an output stream running on `device`.
    private static func isRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
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
        guard !paused, let device = defaultOutputDevice(), isRunning(device) else { return }
        paused = true
        pressPlayPause()
    }

    static func resume() {
        guard paused else { return }
        paused = false
        pressPlayPause()
    }
}
