import CoreAudio
import Foundation

/// Whether a meeting app has the microphone open.
///
/// CoreAudio's process objects report input per process, so our own capture
/// never counts and no guess about what the mic is doing is needed. The scan
/// runs once when a dictation starts: a few property reads, cheap enough for
/// the key-down path, and a listener would have to track processes appearing
/// and disappearing for a value read that rarely.
enum MeetingMic {
    /// Bundle identifiers, lowercased, of the apps a meeting runs in.
    /// Browsers are deliberately absent: a tab holding the mic says nothing
    /// about whether it is Meet or a page whose permission was never revoked,
    /// and this list is the gate for a mode, not a label, so it errs quiet.
    private static let meetingApps: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.skype.skype",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.apple.facetime",
    ]

    static func isMeetingApp(_ bundleID: String) -> Bool {
        meetingApps.contains(bundleID.lowercased())
    }

    /// The bundle identifier of the meeting app recording right now, or nil.
    static func holder() -> String? {
        for process in processObjects() {
            guard let id = bundleID(process), isMeetingApp(id), isRunningInput(process) else { continue }
            return id
        }
        return nil
    }

    // MARK: CoreAudio

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Every process the system currently has an audio object for.
    private static func processObjects() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var addr = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = address(kAudioProcessPropertyIsRunningInput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr && value != 0
    }
}
