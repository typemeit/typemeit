import CoreAudio
import Foundation

/// Mutes the default output device while recording, through CoreAudio's
/// kAudioDevicePropertyMute, and puts it back afterwards. The mute belongs to
/// the device and outlives the app, so the muted device's UID stays in
/// UserDefaults until the mute is lifted: quitting lifts it, and the next
/// launch lifts one a crash left behind.
@MainActor
enum OutputMute {
    /// The device is held by UID, not object ID: a device that drops and
    /// comes back, as a Bluetooth headset can while a call takes its
    /// microphone, returns under a new object ID.
    private static var previous: (uid: String, wasMuted: Bool)?
    private static let leftMutedKey = "outputMutedUID"

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func isMuted(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value != 0 : nil
    }

    private static func setMuted(_ device: AudioDeviceID, _ on: Bool) {
        var address = muteAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }
        var value: UInt32 = on ? 1 : 0
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr { Log.audio.error("Could not set mute: \(status)") }
    }

    private static func describe(_ device: AudioDeviceID) -> String {
        switch isMuted(device) {
        case true?: "muted"
        case false?: "unmuted"
        case nil: "unreadable"
        }
    }

    static func mute() {
        guard previous == nil, let id = MeetingCapture.defaultDevice(input: false), let device = MeetingCapture.device(id), let reads = isMuted(id) else { return }
        // A mute of ours that has not been lifted yet, while an unmute is
        // still retrying, is not the user's: it is lifted at the end of
        // this dictation like any other.
        let was = reads && UserDefaults.standard.string(forKey: leftMutedKey) != device.uid
        previous = (device.uid, was)
        guard !was else { return }
        UserDefaults.standard.set(device.uid, forKey: leftMutedKey)
        setMuted(id, true)
        DebugLog.write("Mute: \(device.bluetooth ? "Bluetooth" : "output") device \(id) muted, reads \(describe(id))")
    }

    /// For the audio check: whether a dictation's mute is held, whether one
    /// left by a crash is waiting to be lifted, and the default output's
    /// mute as it reads now.
    static var report: String {
        let leftover = previous == nil && UserDefaults.standard.string(forKey: leftMutedKey) != nil
        let output = MeetingCapture.defaultDevice(input: false).map(describe) ?? "no output device"
        return "our mute \(previous == nil ? "not held" : "held")\(leftover ? " · one left by a crash" : "") · default output \(output)"
    }

    /// Returns true when the device was muted by `mute()` and has just been
    /// unmuted.
    @discardableResult
    static func restore() -> Bool {
        guard let p = previous else { return false }
        previous = nil
        guard !p.wasMuted else { return false }
        unmute(uid: p.uid)
        return true
    }

    /// Lifts a mute the last run left on, when it crashed or was killed
    /// while recording.
    static func restoreLeftover() {
        guard let uid = UserDefaults.standard.string(forKey: leftMutedKey) else { return }
        DebugLog.write("Mute: left on by the last run")
        unmute(uid: uid)
    }

    /// A device that is not connected keeps its UID in UserDefaults, for the
    /// next launch to try again. One that still reads muted, as a Bluetooth
    /// headset can while it switches profile, is tried again a few times;
    /// a new dictation's mute ends the retries, and its own restore lifts it.
    private static func unmute(uid: String, attempt: Int = 1) {
        guard let id = AudioCapture.deviceID(forUID: uid) else {
            DebugLog.write("Mute: muted device not connected; left for the next launch")
            return
        }
        setMuted(id, false)
        guard isMuted(id) == true else {
            UserDefaults.standard.removeObject(forKey: leftMutedKey)
            DebugLog.write("Mute: device \(id) unmuted, reads \(describe(id))\(attempt > 1 ? " on try \(attempt)" : "")")
            return
        }
        guard attempt < Fixed.unmuteTries else {
            DebugLog.write("Mute: device \(id) still reads muted after \(counted(attempt, "try", "tries")); left for the next launch")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Fixed.unmuteRetryInterval) {
            guard previous == nil else { return }
            unmute(uid: uid, attempt: attempt + 1)
        }
    }
}
