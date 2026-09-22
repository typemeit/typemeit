// Launches a compiled audio-child.swift, finds its process object through
// kAudioHardwarePropertyTranslatePIDToProcessObject, registers wildcard,
// IsRunningOutput (global and output scope) and IsRunning listeners on that
// object, and polls the two flags every 0.4 s while the child plays a sound.
// Measured (macOS 26, 2026-09-20): every registration returns noErr; the
// polled IsRunningOutput flag goes 0, 1, 0; the IsRunning listener ('pir?')
// fires at both transitions; neither IsRunningOutput listener fires; the
// wildcard listener reports exactly 'pir?' in the global scope and
// kAudioProcessPropertyDevices ('pdv#') in the input and output scopes.
// This is why the watch listens on Devices and polls.
//
//   xcrun swiftc -O -o /tmp/audio-child audio-child.swift
//   xcrun swiftc -O -o /tmp/listeners-other listeners-other.swift
//   /tmp/listeners-other /tmp/audio-child
//
// Creates no tap. The child must outlive the polling loop: a process object
// is destroyed when its process exits, and a listener on a destroyed object
// is indistinguishable from one that never fires.
import CoreAudio
import Foundation
import Darwin

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func translate(_ pid: pid_t) -> AudioObjectID {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var q = pid
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var out = AudioObjectID(kAudioObjectUnknown)
    _ = withUnsafeMutablePointer(to: &q) { qp in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), qp, &size, &out)
    }
    return out
}
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var v: UInt32 = 0
    _ = AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v)
    return v
}

let t = Process()
t.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])  // a compiled audio-child.swift
t.arguments = []
t.standardOutput = FileHandle.nullDevice
try! t.run()
let pid = t.processIdentifier
print("child pid=\(pid)")
usleep(400_000)
let obj = translate(pid)
print("child processObject=\(obj) run=\(u32(obj, kAudioProcessPropertyIsRunning)) out=\(u32(obj, kAudioProcessPropertyIsRunningOutput))")

var outA = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
var outG = addr(kAudioProcessPropertyIsRunningOutput)
var wildA = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard, mElement: kAudioObjectPropertyElementWildcard)
let sW = AudioObjectAddPropertyListenerBlock(obj, &wildA, DispatchQueue.main) { n, addrs in
    for i in 0..<Int(n) {
        let a = addrs[i]
        func fcc(_ v: UInt32) -> String { String(bytes: [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)], encoding: .ascii) ?? "?" }
        print("WILDCARD FIRE sel=\(fcc(a.mSelector)) scope=\(fcc(a.mScope))")
    }
}
print("wildcard register = \(sW)")
let sG = AudioObjectAddPropertyListenerBlock(obj, &outG, DispatchQueue.main) { _, _ in
    print("FIRE globalScope.IsRunningOutput")
}
print("global-scope out register = \(sG)")
let s1 = AudioObjectAddPropertyListenerBlock(obj, &outA, DispatchQueue.main) { _, _ in
    print("FIRE other.IsRunningOutput -> \(u32(obj, kAudioProcessPropertyIsRunningOutput))")
}
var runA = addr(kAudioProcessPropertyIsRunning)
let s2 = AudioObjectAddPropertyListenerBlock(obj, &runA, DispatchQueue.main) { _, _ in
    print("FIRE other.IsRunning -> \(u32(obj, kAudioProcessPropertyIsRunning))")
}
print("register on OTHER process: out=\(s1) running=\(s2)")

var ticks = 0
Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
    ticks += 1
    print("t=\(Double(ticks) * 0.4) run=\(u32(obj, kAudioProcessPropertyIsRunning)) out=\(u32(obj, kAudioProcessPropertyIsRunningOutput))")
    if ticks > 40 { exit(0) }
}
RunLoop.main.run()
