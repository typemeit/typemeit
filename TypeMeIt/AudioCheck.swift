import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Settings' "check audio": every audio device and every app using one,
/// what type me it itself holds, then a short mic test the way dictation
/// opens the mic and a short meeting capture of its own tone. Written to the
/// debug log as one block, with the setting on or off, and copied, so a
/// user can paste it into a bug report while the problem is happening.
@MainActor
enum AudioCheck {
    static let micTestSeconds = 2
    static let captureTestSeconds = 2
    nonisolated static let toneHz: Double = 1000
    nonisolated static let toneLevel: Float = 0.05
    /// Bluetooth plays music at 44.1 or 48 kHz; a headset in its call
    /// profile runs at 8, 16 or 24 kHz.
    nonisolated static let lowestMusicRate: Double = 44_100

    struct DeviceState: Equatable, Sendable {
        let name: String
        let transport: UInt32
        let inputChannels: Int
        let outputChannels: Int
        let rate: Double
        let alive: Bool
        let defaultInput: Bool
        let defaultOutput: Bool

        var bluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
        /// A Bluetooth output below music rates has been switched to its call profile.
        var inCallMode: Bool { bluetooth && outputChannels > 0 && rate < AudioCheck.lowestMusicRate }
    }

    static func run() async {
        let lines = await report()
        DebugLog.writeReport(lines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    static func report() async -> [String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = ["Audio check: \(Bundle.main.bundleIdentifier ?? "type me it") \(AppVersion.current) on macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"]
        lines.append(settingsLine())
        lines.append("lid \(MeetingCapture.lidClosed() ? "closed" : "open")")
        lines.append("devices:")
        lines += deviceStates().map { "  " + line(for: $0) }
        lines.append("apps using audio:")
        lines += appLines()
        lines.append(ourStateLine())
        if Pipeline.shared.isBusy {
            lines.append("live tests skipped: dictating")
        } else if MeetingCoordinator.shared.recording != nil {
            lines.append("live tests skipped: recording a meeting")
        } else {
            lines.append(await micTest())
            lines.append(await captureTest())
        }
        return lines
    }

    // MARK: Snapshot

    private static func settingsLine() -> String {
        let settings = Settings.shared
        let mic = settings.microphoneUID.map { uid in
            AudioCapture.deviceID(forUID: uid).flatMap(MeetingCapture.device)?.name ?? "\(uid), not connected"
        } ?? "system default"
        return "settings: mic \(mic) · record meetings \(settings.meetingAsk ? "ask" : "never") · pre-roll \(settings.meetingPreRoll ? "on" : "off") · mute audio \(settings.muteWhileRecording ? "on" : "off") · pause audio \(settings.pauseWhileRecording ? "on" : "off")"
    }

    private static func deviceStates() -> [DeviceState] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let defaultInput = MeetingCapture.defaultDevice(input: true)
        let defaultOutput = MeetingCapture.defaultDevice(input: false)
        return ids.map { id in
            DeviceState(
                name: MeetingCapture.string(id, kAudioDevicePropertyDeviceNameCFString) ?? "device \(id)",
                transport: MeetingCapture.property(id, kAudioDevicePropertyTransportType, UInt32(0)) ?? 0,
                inputChannels: MeetingCapture.streams(of: id, input: true).reduce(0, +),
                outputChannels: MeetingCapture.streams(of: id, input: false).reduce(0, +),
                rate: MeetingCapture.property(id, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 0,
                alive: MeetingCapture.property(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)) != 0,
                defaultInput: id == defaultInput,
                defaultOutput: id == defaultOutput)
        }
    }

    nonisolated static func line(for device: DeviceState) -> String {
        var parts = [transportName(device.transport)]
        if device.inputChannels > 0 { parts.append("in \(device.inputChannels) ch") }
        if device.outputChannels > 0 { parts.append("out \(device.outputChannels) ch") }
        parts.append("\(Int(device.rate)) Hz")
        if device.inCallMode { parts.append("call mode") }
        if !device.alive { parts.append("not alive") }
        if device.defaultInput { parts.append("default input") }
        if device.defaultOutput { parts.append("default output") }
        return "\(device.name): " + parts.joined(separator: " · ")
    }

    nonisolated static func transportName(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "bluetooth"
        case kAudioDeviceTransportTypeUSB: "usb"
        case kAudioDeviceTransportTypeAggregate: "aggregate"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeDisplayPort: "displayport"
        case kAudioDeviceTransportTypeHDMI: "hdmi"
        case kAudioDeviceTransportTypeAirPlay: "airplay"
        case kAudioDeviceTransportTypeThunderbolt: "thunderbolt"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity"
        default: MeetingCapture.fourCC(transport)
        }
    }

    /// Every process with audio running, ours and the ones meeting watch
    /// ignores included, with the devices it has open.
    private static func appLines() -> [String] {
        let apps = ProcessOwner.runningApps()
        let ourPID = ProcessInfo.processInfo.processIdentifier
        let lines = AudioProcesses.snapshot().filter { $0.input || $0.output }.map { info in
            let name = ProcessOwner.owner(of: info, apps: apps)?.name ?? info.bundleID ?? "pid \(info.pid)"
            var uses: [String] = []
            if info.input { uses.append("in on \(deviceNames(AudioProcesses.devices(of: info.objectID, input: true)))") }
            if info.output { uses.append("out on \(deviceNames(AudioProcesses.devices(of: info.objectID, input: false)))") }
            return "  \(name)\(info.pid == ourPID ? " (type me it)" : ""): " + uses.joined(separator: " · ")
        }
        return lines.isEmpty ? ["  none"] : lines
    }

    private static func deviceNames(_ ids: [AudioObjectID]) -> String {
        let names = ids.map { MeetingCapture.string($0, kAudioDevicePropertyDeviceNameCFString) ?? "device \($0)" }
        return names.isEmpty ? "unknown" : names.joined(separator: ", ")
    }

    private static func ourStateLine() -> String {
        let coordinator = MeetingCoordinator.shared
        let meeting = coordinator.recording != nil ? "recording a meeting" : coordinator.holdsPreRoll ? "holding a pre-roll" : "no meeting capture"
        return "type me it: \(Pipeline.shared.isBusy ? "dictating" : "not dictating") · \(meeting) · \(OutputMute.report)"
    }

    // MARK: Live tests

    /// Bluetooth outputs by name and rate, to catch a switch to the call profile.
    private static func bluetoothOutputRates() -> [String: Double] {
        Dictionary(deviceStates().filter { $0.bluetooth && $0.outputChannels > 0 }.map { ($0.name, $0.rate) }, uniquingKeysWith: { first, _ in first })
    }

    nonisolated static func rateChanges(before: [String: Double], during: [String: Double]) -> String {
        guard !before.isEmpty || !during.isEmpty else { return "no bluetooth output" }
        let changed = before.keys.sorted().compactMap { name -> String? in
            guard let was = before[name], let now = during[name], was != now else { return nil }
            return "\(name) \(Int(was)) → \(Int(now)) Hz\(now < lowestMusicRate ? " (call mode)" : "")"
        }
        return changed.isEmpty ? "bluetooth outputs unchanged" : changed.joined(separator: ", ")
    }

    /// The dictation mic, opened as a dictation opens it.
    private static func micTest() async -> String {
        let uid = Settings.shared.microphoneUID
        let name = uid.flatMap(AudioCapture.deviceID(forUID:)).flatMap(MeetingCapture.device)?.name
            ?? MeetingCapture.defaultDevice(input: true).flatMap(MeetingCapture.device)?.name ?? "default input"
        let before = bluetoothOutputRates()
        let capture = AudioCapture()
        do { try capture.start(uid: uid) } catch {
            return "mic test (\(name)): could not start: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(micTestSeconds))
        let during = bluetoothOutputRates()
        let samples = capture.stop()
        return "mic test (\(name), \(micTestSeconds) s): \(counted(samples.count, "frame")) · peak \(String(format: "%.3f", AudioCapture.peak(samples))) · \(rateChanges(before: before, during: during))"
    }

    /// A meeting capture of a call's geometry, tapping this app while it
    /// plays a quiet tone: which device clocks it and whether the far end
    /// carries the tone at its own pitch.
    private static func captureTest() async -> String {
        guard let mic = MeetingCapture.microphone(preferredUID: Settings.shared.microphoneUID),
              let object = AudioProcesses.objectID(forPID: ProcessInfo.processInfo.processIdentifier) else {
            return "capture test: no microphone or no process object"
        }
        let before = bluetoothOutputRates()
        let tone: AVAudioEngine
        do { tone = try playTone() } catch {
            return "capture test: tone not started: \(error.localizedDescription)"
        }
        let sink = CheckSink()
        let capture: MeetingCapture
        do { capture = try MeetingCapture(mic: mic, tapProcesses: [object], sink: sink) } catch {
            tone.stop()
            return "capture test (\(mic.name)): could not start: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(captureTestSeconds))
        let during = bluetoothOutputRates()
        let clock = capture.outputIsClock ? "output" : "mic"
        capture.stop()
        tone.stop()
        let result = sink.result
        let rate = AudioCapture.targetFormat.sampleRate
        let farEnd = result.farEnd.peak < Fixed.meetingSilenceFloor ? "far end silent"
            : "far end peak \(String(format: "%.3f", result.farEnd.peak)) · tone \(Int(toneHz)) Hz heard at \(String(format: "%.1f", result.farEnd.pitch(rate: rate) ?? 0)) Hz"
        var parts = ["\(clock) clock", "\(Int(capture.micFormat.mSampleRate)) Hz", "tap \(capture.tapFormat.map { "\(Int($0.mSampleRate)) Hz" } ?? "none")",
                     "mic peak \(String(format: "%.3f", result.micPeak))", farEnd, "gaps \(result.gapFrames / Meeting.framesPerMs) ms"]
        if let failure = result.failure { parts.append("failed: \(failure)") }
        parts.append(rateChanges(before: before, during: during))
        return "capture test (\(mic.name), \(captureTestSeconds) s): " + parts.joined(separator: " · ")
    }

    private final class CheckSink: MeetingCaptureSink, @unchecked Sendable {
        private let lock = NSLock()
        private var micPeak: Float = 0
        private var farEnd = ToneMeter()
        private var gapFrames = 0
        private var failure: String?

        var result: (micPeak: Float, farEnd: ToneMeter, gapFrames: Int, failure: String?) {
            lock.lock(); defer { lock.unlock() }
            return (micPeak, farEnd, gapFrames, failure)
        }

        func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?) {
            lock.lock(); defer { lock.unlock() }
            micPeak = max(micPeak, AudioCapture.peak(mic))
            if let others { farEnd.add(others) }
        }
        func captureGap(_ capture: MeetingCapture, frames: Int) {
            lock.lock(); gapFrames += frames; lock.unlock()
        }
        func captureFailed(_ capture: MeetingCapture, error: Error) {
            lock.lock(); failure = error.localizedDescription; lock.unlock()
        }
    }

    /// A quiet sine on the default output, from this process. Nonisolated:
    /// the render block runs on the audio IO thread, and one formed in a
    /// main-actor function traps on its isolation check there.
    nonisolated static func playTone() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let step = 2 * Double.pi * toneHz / rate
        var phase = 0.0
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = toneLevel * Float(sin(phase))
                phase += step
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        return engine
    }
}

/// The peak and pitch of what a track carried, the pitch from rising zero
/// crossings: enough to tell a tone from one resampled at the wrong rate.
struct ToneMeter: Sendable {
    private(set) var peak: Float = 0
    private(set) var frames = 0
    private var risingCrossings = 0
    private var last: Float = 0

    mutating func add(_ samples: [Float]) {
        for sample in samples {
            if last < 0, sample >= 0 { risingCrossings += 1 }
            last = sample
            peak = max(peak, abs(sample))
        }
        frames += samples.count
    }

    /// Cycles a second for a track at `rate`; nil before any frames.
    func pitch(rate: Double) -> Double? {
        frames > 0 ? Double(risingCrossings) * rate / Double(frames) : nil
    }
}
