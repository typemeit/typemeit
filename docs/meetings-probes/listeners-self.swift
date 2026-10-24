// Registers a wildcard listener and three IsRunningInput listeners (global,
// input and wildcard scope) on this process's own process object, then opens
// and closes the microphone through AVAudioEngine and prints every
// notification with its selector. Measured (macOS 26, 2026-09-19): every
// registration returns noErr; the only notification that fires when the mic
// opens or closes is kAudioProcessPropertyDevices ('pdv#') in the input
// scope; IsRunningInput listeners never fire, though polling the property
// shows the value changing.
//
//   xcrun swiftc -O -o /tmp/listeners-self listeners-self.swift && /tmp/listeners-self
//
// Needs the Microphone grant for the terminal it runs from. Creates no tap.
import CoreAudio
import AVFoundation
import Foundation
import Darwin

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func readList() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size)/MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(s); var size = UInt32(MemoryLayout<UInt32>.size); var v: UInt32 = 0
    _ = AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v); return v
}
func i32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> Int32 {
    var a = addr(s); var size = UInt32(MemoryLayout<Int32>.size); var v: Int32 = -1
    _ = AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v); return v
}
func fourcc(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 255), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
    return String(bytes: b.map { $0 >= 32 && $0 < 127 ? $0 : 46 }, encoding: .ascii) ?? "????"
}
let t0 = Date()
func log(_ s: String) { print(String(format: "%7.3f  %@", Date().timeIntervalSince(t0), s)) }

let me = getpid()
var meObj: AudioObjectID = 0
for o in readList() where i32(o, kAudioProcessPropertyPID) == me { meObj = o }
log("our pid \(me) obj \(meObj)")

// Wildcard listener on our own process object: report EVERY notification.
var wild = AudioObjectPropertyAddress(
    mSelector: kAudioObjectPropertySelectorWildcard,
    mScope: kAudioObjectPropertyScopeWildcard,
    mElement: kAudioObjectPropertyElementWildcard)
let st = AudioObjectAddPropertyListenerBlock(meObj, &wild, DispatchQueue.main) { n, addrs in
    for i in 0..<Int(n) {
        let a = addrs[i]
        log("WILDCARD FIRE obj=\(meObj) sel='\(fourcc(a.mSelector))' scope='\(fourcc(a.mScope))' elem=\(a.mElement)")
    }
}
log("wildcard listener status = \(st)")

// Also register input-scoped listeners, in case scope matters.
for scope in [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeWildcard] {
    var a = addr(kAudioProcessPropertyIsRunningInput, scope)
    let s2 = AudioObjectAddPropertyListenerBlock(meObj, &a, DispatchQueue.main) { _, _ in
        log("IN-LISTENER FIRE scope='\(fourcc(scope))' in=\(u32(meObj, kAudioProcessPropertyIsRunningInput))")
    }
    log("IsRunningInput listener scope='\(fourcc(scope))' status = \(s2)")
}

let engine = AVAudioEngine()
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    log("--- mic on --- (in=\(u32(meObj, kAudioProcessPropertyIsRunningInput)))")
    engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: engine.inputNode.inputFormat(forBus: 0)) { _, _ in }
    try? engine.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { log("poll in=\(u32(meObj, kAudioProcessPropertyIsRunningInput))") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
    log("--- mic off ---"); engine.stop(); engine.inputNode.removeTap(onBus: 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { log("poll in=\(u32(meObj, kAudioProcessPropertyIsRunningInput))") }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { log("done"); exit(0) }
RunLoop.main.run()
