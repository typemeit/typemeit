// Lists every Core Audio process object with its pid, bundle id, path and
// running flags, registers a listener on the process-object list and one
// IsRunningInput listener on the first object, then launches afplay and
// prints which objects appeared. Measured (macOS 26, 2026-09-19): the list
// listener fires four to six times for one afplay launch and not at all when
// an existing object opens the mic; helpers such as com.google.Chrome.helper
// and com.tinyspeck.slackmacgap.helper are in the list before a call starts,
// so the list listener misses call starts. A process with no bundle answers
// noErr with an empty string.
//
//   xcrun swiftc -O -o /tmp/dumpprocs dumpprocs.swift && /tmp/dumpprocs
//
// Creates no tap, so it never prompts for System Audio Recording.
import CoreAudio
import Foundation
import Darwin

func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func readList() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> (OSStatus, String?) {
    var a = addr(s)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var v: CFString?
    let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(o, &a, 0, nil, &size, $0) }
    return (st, v as String?)
}

func u32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> (OSStatus, UInt32) {
    var a = addr(s)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var v: UInt32 = 0
    let st = AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v)
    return (st, v)
}

func i32(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> (OSStatus, Int32) {
    var a = addr(s)
    var size = UInt32(MemoryLayout<Int32>.size)
    var v: Int32 = -1
    let st = AudioObjectGetPropertyData(o, &a, 0, nil, &size, &v)
    return (st, v)
}

func path(_ pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(MAXPATHLEN))
    return n > 0 ? String(cString: buf) : "<none>"
}

// translate PID round trip
func translate(_ pid: pid_t) -> (OSStatus, AudioObjectID) {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var q = pid
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var out: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    let st = withUnsafeMutablePointer(to: &q) { qp in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), qp, &size, &out)
    }
    return (st, out)
}

let ids = readList()
print("process objects: \(ids.count)")
var emptyBundleNoErr = 0
for o in ids {
    let (bst, b) = str(o, kAudioProcessPropertyBundleID)
    let (pst, p) = i32(o, kAudioProcessPropertyPID)
    let (rst, r) = u32(o, kAudioProcessPropertyIsRunning)
    let (ist, i) = u32(o, kAudioProcessPropertyIsRunningInput)
    let (ost, ou) = u32(o, kAudioProcessPropertyIsRunningOutput)
    let bundle = b ?? "<nil>"
    if bst == noErr && (b?.isEmpty ?? false) { emptyBundleNoErr += 1 }
    let (tst, tid) = translate(pid_t(p))
    print("obj=\(o) pid=\(p)[\(pst)] bundle='\(bundle)'[\(bst)] run=\(r)[\(rst)] in=\(i)[\(ist)] out=\(ou)[\(ost)] xlate=\(tid)[\(tst)] path=\(path(pid_t(p)))")
}
print("empty-bundle-with-noErr count: \(emptyBundleNoErr)")

// listener probe on the process object list
let sem = DispatchSemaphore(value: 0)
var la = addr(kAudioHardwarePropertyProcessObjectList)
let st = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &la, DispatchQueue.main) { _, _ in
    print("LISTENER FIRED: process object list changed")
    sem.signal()
}
print("AudioObjectAddPropertyListenerBlock(ProcessObjectList) status = \(st)")

// per-process IsRunningInput listener on the first object
if let first = ids.first {
    var ia = addr(kAudioProcessPropertyIsRunningInput)
    let st2 = AudioObjectAddPropertyListenerBlock(first, &ia, DispatchQueue.main) { _, _ in
        print("LISTENER FIRED: IsRunningInput changed on \(first)")
    }
    print("AudioObjectAddPropertyListenerBlock(obj \(first), IsRunningInput) status = \(st2)")
}

// Run the main loop briefly, spawn afplay to force a process-list change.
DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
    let t = Process()
    t.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    t.arguments = ["/System/Library/Sounds/Submarine.aiff"]
    try? t.run()
}
DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
    print("--- after afplay, re-reading list ---")
    let ids2 = readList()
    print("process objects now: \(ids2.count)")
    for o in ids2 where !ids.contains(o) {
        let (bst, b) = str(o, kAudioProcessPropertyBundleID)
        let (_, p) = i32(o, kAudioProcessPropertyPID)
        let (_, i) = u32(o, kAudioProcessPropertyIsRunningInput)
        let (_, ou) = u32(o, kAudioProcessPropertyIsRunningOutput)
        print("NEW obj=\(o) pid=\(p) bundle='\(b ?? "<nil>")'[status \(bst)] in=\(i) out=\(ou) path=\(path(pid_t(p)))")
    }
    exit(0)
}
RunLoop.main.run()
