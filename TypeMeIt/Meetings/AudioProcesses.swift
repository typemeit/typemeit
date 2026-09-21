import AppKit
import CoreAudio
import Foundation

/// One of CoreAudio's per-process objects: which process it is and whether
/// it has input or output running right now.
struct AudioProcessInfo: Equatable, Sendable {
    let objectID: AudioObjectID
    let pid: pid_t
    /// nil when CoreAudio returns an empty string, which it does with
    /// `noErr` for a process with no bundle.
    let bundleID: String?
    /// `proc_pidpath`, nil when the process is gone or unreadable.
    let path: String?
    let input: Bool
    let output: Bool
}

/// Reads CoreAudio's process objects and listens for changes to them.
/// Everything here is a thin shell over property reads; the resolution of a
/// process to an app is `ProcessOwner`, which is pure.
enum AudioProcesses {
    private static func global(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ zero: T) -> T? {
        var address = global(selector)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// A CFString property; CoreAudio hands it over retained.
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = global(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectIDs() -> [AudioObjectID] {
        var address = global(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    static func info(of object: AudioObjectID) -> AudioProcessInfo? {
        guard let pid = property(object, kAudioProcessPropertyPID, pid_t(0)) else { return nil }
        let bundleID = string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        let path = length > 0 ? String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return AudioProcessInfo(
            objectID: object, pid: pid, bundleID: bundleID, path: path,
            input: property(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) != 0,
            output: property(object, kAudioProcessPropertyIsRunningOutput, UInt32(0)) != 0)
    }

    /// The process object for a pid, ours included.
    static func objectID(forPID pid: pid_t) -> AudioObjectID? {
        var address = global(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &object)
        }
        return status == noErr && object != 0 ? object : nil
    }

    /// Every process object CoreAudio lists, read now.
    static func snapshot() -> [AudioProcessInfo] {
        objectIDs().compactMap(info(of:))
    }

    /// Fires `onChange` on `queue` when the process list changes or any
    /// process's `Devices` property fires at input or output scope, which is
    /// the notification CoreAudio does deliver when a process opens or
    /// closes the mic or a speaker (docs/meetings.md 3.2: the IsRunning
    /// listeners register and never fire). Re-registers the per-process
    /// listeners whenever the list changes.
    final class Listener: @unchecked Sendable {
        private let queue: DispatchQueue
        private let onChange: @Sendable (_ why: String) -> Void
        private let lock = NSLock()
        private var perProcess: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]
        private var listBlock: AudioObjectPropertyListenerBlock?
        private static let scopes: [(AudioObjectPropertyScope, String)] = [(kAudioObjectPropertyScopeInput, "input"), (kAudioObjectPropertyScopeOutput, "output")]

        init(queue: DispatchQueue, onChange: @escaping @Sendable (_ why: String) -> Void) {
            self.queue = queue
            self.onChange = onChange
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                self.register()
                self.onChange("process list")
            }
            listBlock = block
            var address = AudioProcesses.global(kAudioHardwarePropertyProcessObjectList)
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
            if status != noErr { Log.meetings.error("Process list listener not added: \(status)") }
            register()
        }

        /// Adds `Devices` listeners for objects new to the list and drops the
        /// ones for objects that have gone.
        private func register() {
            let current = Set(AudioProcesses.objectIDs())
            lock.lock()
            defer { lock.unlock() }
            for (object, entries) in perProcess where !current.contains(object) {
                for (address, block) in entries {
                    var a = address
                    AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
                }
                perProcess[object] = nil
            }
            for object in current where perProcess[object] == nil {
                var entries: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
                for (scope, name) in Listener.scopes {
                    var address = AudioProcesses.global(kAudioProcessPropertyDevices, scope: scope)
                    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                        self?.onChange("devices \(name) on \(object)")
                    }
                    if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                        entries.append((address, block))
                    }
                }
                perProcess[object] = entries
            }
        }

        deinit {
            if let listBlock {
                var address = AudioProcesses.global(kAudioHardwarePropertyProcessObjectList)
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listBlock)
            }
            for (object, entries) in perProcess {
                for (address, block) in entries {
                    var a = address
                    AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
                }
            }
        }
    }
}

/// Which app a CoreAudio process object belongs to. Chrome's and Slack's
/// audio lives in helpers that report their own bundle ids, so a helper is
/// folded into the app that owns it; a daemon with no app is named for
/// itself. Pure: the running apps are passed in.
enum ProcessOwner {
    struct Owner: Hashable, Sendable {
        /// The owning app's bundle id, or the process's own for a daemon.
        let bundleID: String
        /// "Slack", "Google Chrome", "FaceTime".
        let name: String
        /// The app bundle, nil for a daemon.
        let appURL: URL?

        /// Shared web content (Safari and every WKWebView app) is never put
        /// on the never-ask list: one cross would silence every web app.
        var canNeverAsk: Bool { bundleID != Fixed.meetingWebContentBundleID }
    }

    struct RunningApp: Equatable, Sendable {
        let bundleID: String
        let name: String
        let url: URL?
    }

    static let ourBundlePrefix = "it.typeme.typemeit"
    static let webContentName = "web content"

    /// The apps running now, as the resolver takes them.
    @MainActor
    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            return RunningApp(bundleID: id, name: app.localizedName ?? id, url: app.bundleURL)
        }
    }

    /// Resolution, in order:
    /// 1. `bundleID` non-empty: the running app whose bundle id equals it or
    ///    is a prefix of it followed by "." (`com.google.Chrome.helper` is
    ///    Chrome). No running app: a daemon, named from
    ///    `Fixed.meetingDaemonNames`, else its last bundle-id component;
    ///    `com.apple.WebKit.GPU` is every web app's and is `web content`.
    /// 2. `bundleID` empty: the outermost `.app` in `path` names its running
    ///    app, or the bundle folder itself; else the executable name.
    static func owner(of info: AudioProcessInfo, apps: [RunningApp]) -> Owner? {
        if let bundleID = info.bundleID {
            if bundleID == Fixed.meetingWebContentBundleID {
                return Owner(bundleID: bundleID, name: webContentName, appURL: nil)
            }
            // NSWorkspace lists a helper bundle as a running app of its own,
            // so the shortest matching id is the app that owns it.
            let owning = apps.filter { bundleID == $0.bundleID || bundleID.hasPrefix($0.bundleID + ".") }
                .min { $0.bundleID.count < $1.bundleID.count }
            if let owning { return Owner(bundleID: owning.bundleID, name: owning.name, appURL: owning.url) }
            let name = Fixed.meetingDaemonNames[bundleID] ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
            return Owner(bundleID: bundleID, name: name, appURL: nil)
        }
        guard let path = info.path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let appIndex = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appPath = parts[...appIndex].joined(separator: "/")
            let appURL = URL(fileURLWithPath: appPath)
            if let running = apps.first(where: { $0.url?.standardizedFileURL.path == appURL.standardizedFileURL.path }) {
                return Owner(bundleID: running.bundleID, name: running.name, appURL: running.url)
            }
            let name = String(parts[appIndex].dropLast(".app".count))
            return Owner(bundleID: appPath, name: name, appURL: appURL)
        }
        let executable = parts.last.map(String.init) ?? path
        return Owner(bundleID: path, name: executable, appURL: nil)
    }

    /// Our pid, or a bundle id starting with `it.typeme.typemeit`: the
    /// release and the dev build are two apps and neither may prompt the
    /// other.
    static func isOurs(_ info: AudioProcessInfo, ourPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Bool {
        info.pid == ourPID || info.bundleID?.hasPrefix(ourBundlePrefix) == true
    }

    /// Apple daemons that hold the mic for the system.
    static func isIgnored(_ info: AudioProcessInfo) -> Bool {
        info.bundleID.map { Fixed.meetingIgnoredBundleIDs.contains($0) } ?? false
    }
}
