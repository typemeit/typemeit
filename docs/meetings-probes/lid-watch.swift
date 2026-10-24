// Logs the lid (IOPMrootDomain's AppleClamshellState) and every built-in
// input device, with whether Core Audio calls it alive, its input streams and
// its rate, plus the default input: once at start and again whenever any of
// it changes, polled every 250 ms. Run it beside
// `-meetingProbeCapture self <s>` on the dev app, which logs the mic's peak
// each second, then close and open the lid (with an external display and
// power, or the Mac sleeps).
//
//   xcrun swiftc -O -o /tmp/lid-watch lid-watch.swift && /tmp/lid-watch
//
// Opens no device, so it never prompts for the microphone.
import CoreAudio
import Foundation
import IOKit

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func scalar<T: BitwiseCopyable>(_ id: AudioObjectID, _ s: AudioObjectPropertySelector, _ zero: T, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
    var a = addr(s, scope)
    var value = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr ? value : nil
}

func name(_ id: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let value else { return "?" }
    return value.takeRetainedValue() as String
}

func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func inputStreams(_ id: AudioObjectID) -> Int {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return 0 }
    return Int(size) / MemoryLayout<AudioStreamID>.size
}

func lid() -> String {
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard root != 0 else { return "no root domain" }
    defer { IOObjectRelease(root) }
    guard let state = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else { return "no lid" }
    return state ? "closed" : "open"
}

func snapshot() -> String {
    let builtIn = devices().filter { scalar($0, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn && inputStreams($0) > 0 }
    let mics = builtIn.map { id in
        "\(name(id)) [\(id)] alive \(scalar(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)).map(String.init) ?? "?") streams \(inputStreams(id)) \(scalar(id, kAudioDevicePropertyNominalSampleRate, Float64(0)).map { "\(Int($0)) Hz" } ?? "?")"
    }
    let defaultInput = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, AudioObjectID(0)).map(name) ?? "none"
    return "lid \(lid()); built-in inputs: \(mics.isEmpty ? "none" : mics.joined(separator: ", ")); default input \(defaultInput)"
}

let clock = DateFormatter()
clock.dateFormat = "HH:mm:ss.SSS"
var last = ""
while true {
    let now = snapshot()
    if now != last {
        print("\(clock.string(from: Date())) \(now)")
        fflush(stdout)
        last = now
    }
    Thread.sleep(forTimeInterval: 0.25)
}
