// The child process for listeners-other.swift. Plays a system sound three
// times through AVAudioPlayer and stays alive for about twelve seconds so the
// parent has a long-lived process object to watch. It also registers
// IsRunningOutput, IsRunning and IsRunningInput listeners on its own process
// object and polls the three flags every 0.5 s; the parent discards this
// output, so run it alone to see its own view.
//
//   xcrun swiftc -O -o /tmp/audio-child audio-child.swift && /tmp/audio-child
import AVFoundation
import CoreAudio
import Foundation

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

let me = getpid()
let obj = translate(me)
print("self pid=\(me) processObject=\(obj)")

var outA = addr(kAudioProcessPropertyIsRunningOutput)
let s1 = AudioObjectAddPropertyListenerBlock(obj, &outA, DispatchQueue.main) { _, _ in
    print("FIRE IsRunningOutput -> \(u32(obj, kAudioProcessPropertyIsRunningOutput))")
}
var runA = addr(kAudioProcessPropertyIsRunning)
let s2 = AudioObjectAddPropertyListenerBlock(obj, &runA, DispatchQueue.main) { _, _ in
    print("FIRE IsRunning -> \(u32(obj, kAudioProcessPropertyIsRunning))")
}
var inA = addr(kAudioProcessPropertyIsRunningInput)
let s3 = AudioObjectAddPropertyListenerBlock(obj, &inA, DispatchQueue.main) { _, _ in
    print("FIRE IsRunningInput -> \(u32(obj, kAudioProcessPropertyIsRunningInput))")
}
print("register status: out=\(s1) running=\(s2) input=\(s3)")

var player: AVAudioPlayer?
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let url = URL(fileURLWithPath: "/System/Library/Sounds/Submarine.aiff")
    player = try? AVAudioPlayer(contentsOf: url)
    player?.numberOfLoops = 2
    player?.play()
    print("started playback; isRunningOutput now \(u32(obj, kAudioProcessPropertyIsRunningOutput))")
}
var ticks = 0
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
    ticks += 1
    print("t=\(Double(ticks) * 0.5) run=\(u32(obj, kAudioProcessPropertyIsRunning)) out=\(u32(obj, kAudioProcessPropertyIsRunningOutput)) in=\(u32(obj, kAudioProcessPropertyIsRunningInput))")
    if ticks > 24 { exit(0) }
}
RunLoop.main.run()
