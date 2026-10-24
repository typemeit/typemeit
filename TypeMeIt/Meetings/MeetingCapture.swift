import AVFoundation
import CoreAudio
import Foundation
import IOKit
import Synchronization

/// Receives what the capture delivers, on the drain queue.
protocol MeetingCaptureSink: AnyObject {
    /// 16 kHz mono Float32, one call per drain. `others` is nil for a
    /// capture with no tap.
    func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?)
    /// Frames (16 kHz) that passed with no audio, a device rebuild or a
    /// discontinuity in the device's own clock, to be filled with zeros so
    /// meeting time stays sample index over the rate.
    func captureGap(_ capture: MeetingCapture, frames: Int)
    func captureFailed(_ capture: MeetingCapture, error: Error)
}

/// The mic and the far end through one private aggregate device: the
/// microphone as a sub-device and a process tap on the app's processes,
/// driven by one IO proc, so the two tracks share a clock (docs/meetings.md
/// 5.4, 7.5). The IO proc copies both into one ring and returns; a drain
/// queue converts each track to 16 kHz and hands the frames to the sink. Tap and
/// aggregate geometry after insidegui/AudioCap (BSD-2-Clause, copyright
/// Guilherme Rambo) and pasrom/meeting-transcriber `AppTapSession` (MIT).
final class MeetingCapture: @unchecked Sendable {
    /// A device's name is shown live and never persisted or logged.
    struct Device: Equatable, Sendable {
        let uid: String
        let name: String
        let bluetooth: Bool
    }

    /// Pinned at the start; changes only once, to the built-in mic, after a
    /// Bluetooth mic goes away.
    private(set) var mic: Device
    private var fellBackToBuiltIn = false
    private(set) var tapProcesses: [AudioObjectID]?
    /// The mic clocks the tap whatever the output, so a probe can try the
    /// Bluetooth geometry on speakers (docs/meetings.md S1).
    private let clockOnMic: Bool
    weak var sink: MeetingCaptureSink?

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "it.typeme.typemeit.meeting-io", qos: .userInteractive)
    /// Above `.utility`: on 16 October, with the Mac throttled on a flat
    /// battery and a meeting transcribing, a utility drain fell over 4 s
    /// behind again and again and 72 s of a 13-minute call was dropped.
    private let drainQueue = DispatchQueue(label: "it.typeme.typemeit.meeting-drain", qos: .userInitiated)
    private let listenerQueue = DispatchQueue(label: "it.typeme.typemeit.meeting-devices", qos: .utility)
    private var drainTimer: DispatchSourceTimer?
    /// Keeps the drain's timer on time against App Nap from the first frame,
    /// the pre-roll's included, until `stop`.
    private var activity: NSObjectProtocol?
    private var producer: Producer?
    private var stopped = false
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Host time of the very first IO proc callback: frame 0 of every track.
    private(set) var firstHostTime: UInt64 = 0
    private(set) var micFormat = AudioStreamBasicDescription()
    private(set) var tapFormat: AudioStreamBasicDescription?
    /// Whether the output device clocks the aggregate now; false once stopped.
    var outputIsClock: Bool {
        lock.lock(); defer { lock.unlock() }
        return producer?.outputIsClock ?? false
    }

    /// Everything one built aggregate owns. Replaced whole on a rebuild, so
    /// the IO proc of a torn-down device never touches the new one's rings.
    private final class Producer: @unchecked Sendable {
        var tapID: AudioObjectID = 0
        var aggregateID: AudioObjectID = 0
        var procID: AudioDeviceIOProcID?
        var outputUID: String?
        var outputIsClock = false
        var micBuffers: Range<Int> = 0..<0
        var tapBuffer: Int?
        var rate: Double = 0
        /// The mic on the first channel, the tap on the second when there is one.
        let ring: AudioRing
        /// `ring.overruns` already reported as a gap. Drain queue only.
        var reportedOverruns = 0
        var micConverter: AVAudioConverter?
        var othersConverter: AVAudioConverter?
        /// Host time of this producer's first callback, and of the end of
        /// its last one, for the gap between it and its successor. Written
        /// by the IO proc, read by the drain, so atomic.
        let firstHostTime = Atomic<UInt64>(0)
        let lastHostTime = Atomic<UInt64>(0)
        var expectedSampleTime: Double = -1
        /// Frames at the device rate skipped by the device's own clock.
        let pendingGapFrames = Atomic<Int>(0)
        var callbacks = 0

        init(rate: Double, tap: Bool) {
            ring = AudioRing(frames: Int(rate) * Fixed.meetingRingSeconds, channels: tap ? 2 : 1)
        }
    }

    enum CaptureError: LocalizedError {
        case status(String, OSStatus)
        case noDevice(String)
        case rebuildFailed
        var errorDescription: String? {
            switch self {
            case .status(let what, let code): "\(what) failed (\(code))"
            case .noDevice(let which): "no \(which) device"
            case .rebuildFailed: "the audio device could not be rebuilt"
            }
        }
    }

    /// Builds and starts. `tapProcesses` nil records the mic alone (the room).
    init(mic: Device, tapProcesses: [AudioObjectID]?, sink: MeetingCaptureSink, clockOnMic: Bool = false) throws {
        self.mic = mic
        self.tapProcesses = tapProcesses
        self.clockOnMic = clockOnMic
        self.sink = sink
        let built = try build()
        lock.lock()
        producer = built
        lock.unlock()
        installListeners()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "capturing a meeting")
        startDrain()
        DebugLog.write("Meeting capture: mic \(mic.bluetooth ? "bluetooth" : "wired or built-in"), \(tapProcesses.map { "tap on \($0.count) process objects" } ?? "no tap"), \(built.outputIsClock ? "output" : "mic") clock, \(built.rate) Hz, mic buffers \(built.micBuffers), tap buffer \(built.tapBuffer.map(String.init) ?? "-")")
    }

    deinit { stop() }

    // MARK: Build

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw CaptureError.status(what, status) }
    }

    static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ zero: T) -> T? {
        var address = address(selector, scope: scope)
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        AudioProcesses.string(object, selector)
    }

    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        let id: AudioDeviceID? = property(AudioObjectID(kAudioObjectSystemObject), input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID(0))
        return id.flatMap { $0 == 0 ? nil : $0 }
    }

    static func device(_ id: AudioDeviceID) -> Device? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioDevicePropertyDeviceNameCFString) else { return nil }
        let transport: UInt32 = property(id, kAudioDevicePropertyTransportType, 0) ?? 0
        return Device(uid: uid, name: name, bluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE)
    }

    /// The built-in microphone, if the Mac has one and can hear through it:
    /// with the lid closed a MacBook cuts its mic off in hardware, so a
    /// recording there would get silence in place of the user.
    static func builtInMicrophone() -> Device? {
        guard !lidClosed() else { return nil }
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            property(id, kAudioDevicePropertyTransportType, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn
                && streams(of: id).contains { $0 > 0 }
        }.flatMap(device)
    }

    /// The microphone to record, chosen once at the start and pinned
    /// (docs/meetings.md 7.5). Nothing here writes the Mac-wide default.
    static func microphone(preferredUID: String?, room: Bool = false) -> Device? {
        microphone(picked: preferredUID.flatMap(AudioCapture.deviceID(forUID:)).flatMap(device),
                   defaultInput: defaultDevice(input: true).flatMap(device),
                   builtIn: builtInMicrophone(), room: room)
    }

    /// IOPMrootDomain's AppleClamshellState, which a Mac with no lid lacks.
    /// Readable inside the App Sandbox.
    static func lidClosed() -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        return IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
    }

    /// The settings' choice when it is present, else the default input,
    /// with the built-in mic in place of a Bluetooth one unless the user
    /// picked that headset for a room. In a room, opening the headset's mic
    /// drops whatever it plays to call quality. In a call it puts the headset
    /// the call app is using into our aggregate: on 19 October one dropped
    /// out 53 s after the pre-roll did that.
    static func microphone(picked: Device?, defaultInput: Device?, builtIn: Device?, room: Bool) -> Device? {
        guard let chosen = picked ?? defaultInput else { return builtIn }
        if chosen.bluetooth, !(room && picked != nil), let builtIn { return builtIn }
        return chosen
    }

    /// The aggregate's clock: the output device when there is a tap, else
    /// the mic. A Bluetooth output stays out of the aggregate and the mic
    /// clocks the tap: as a sub-device the headset would bring its input
    /// streams, the ones the call app holds.
    static func clockUID(mic: Device, output: Device?) -> String {
        guard let output, !output.bluetooth else { return mic.uid }
        return output.uid
    }

    /// What `meeting.json` records about the devices in use: their kinds, never their names.
    static func audioDescription(mic: Device) -> Meeting.Audio {
        var audio = Meeting.Audio()
        if let id = AudioCapture.deviceID(forUID: mic.uid), let transport: UInt32 = property(id, kAudioDevicePropertyTransportType, 0) { audio.inputTransport = fourCC(transport) }
        guard let output = defaultDevice(input: false) else { return audio }
        if let transport: UInt32 = property(output, kAudioDevicePropertyTransportType, 0) { audio.outputTransport = fourCC(transport) }
        if let source: UInt32 = property(output, kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput, 0) { audio.outputDataSource = fourCC(source) }
        return audio
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(value)
    }

    /// A device's streams at input or output scope: one entry per stream with its channel count.
    static func streams(of device: AudioObjectID, input: Bool = true) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(list).map { Int($0.mNumberChannels) }
    }

    private func build() throws -> Producer {
        guard let micID = AudioCapture.deviceID(forUID: mic.uid) else { throw CaptureError.noDevice("microphone") }
        var tapID: AudioObjectID = 0
        var tapFormat: AudioStreamBasicDescription?
        var output: Device?
        if let tapProcesses {
            let description = CATapDescription(monoMixdownOfProcesses: tapProcesses)
            description.uuid = UUID()
            description.name = "type me it meeting"
            description.isPrivate = true
            description.isProcessRestoreEnabled = true
            try MeetingCapture.check(AudioHardwareCreateProcessTap(description, &tapID), "creating the tap")
            tapFormat = MeetingCapture.property(tapID, kAudioTapPropertyFormat, AudioStreamBasicDescription())
            guard let device = MeetingCapture.defaultDevice(input: false).flatMap(MeetingCapture.device) else {
                AudioHardwareDestroyProcessTap(tapID)
                throw CaptureError.noDevice("output")
            }
            output = device
        }

        // The mic first, so its input streams lead the IO proc's buffer
        // list; an output device that is the clock contributes its own
        // input streams, if any, after the mic's.
        let mainUID = MeetingCapture.clockUID(mic: mic, output: clockOnMic ? nil : output)
        var subDevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: mic.uid]]
        if mic.uid != mainUID {
            subDevices[0][kAudioSubDeviceDriftCompensationKey] = 1
            subDevices.append([kAudioSubDeviceUIDKey: mainUID])
        }
        var composition: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "type me it meeting",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: mainUID,
            kAudioAggregateDeviceSubDeviceListKey: subDevices,
        ]
        if tapID != 0, let uuid = MeetingCapture.string(tapID, kAudioTapPropertyUID) {
            composition[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: uuid, kAudioSubTapDriftCompensationKey: 1]]
        }
        var aggregateID: AudioObjectID = 0
        do {
            try MeetingCapture.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "creating the aggregate device")
        } catch {
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
            throw error
        }

        let rate = MeetingCapture.property(aggregateID, kAudioDevicePropertyNominalSampleRate, Double(0)) ?? 0
        let streams = MeetingCapture.streams(of: aggregateID)
        let micStreams = MeetingCapture.streams(of: micID).count
        let producer = Producer(rate: rate, tap: tapID != 0)
        producer.tapID = tapID
        producer.aggregateID = aggregateID
        producer.outputUID = output?.uid
        producer.outputIsClock = output?.uid == mainUID
        producer.rate = rate
        producer.micBuffers = 0..<min(micStreams, streams.count)
        producer.tapBuffer = tapID != 0 && streams.count > micStreams ? streams.count - 1 : nil
        guard rate > 0, !producer.micBuffers.isEmpty else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
            throw CaptureError.noDevice("microphone stream")
        }
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        producer.micConverter = AVAudioConverter(from: mono, to: AudioCapture.targetFormat)
        if producer.tapBuffer != nil { producer.othersConverter = AVAudioConverter(from: mono, to: AudioCapture.targetFormat) }
        lock.lock()
        micFormat = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        self.tapFormat = tapFormat
        lock.unlock()

        var procID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            MeetingCapture.consume(producer, inputData, inputTime)
        }
        do {
            try MeetingCapture.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, block), "creating the IO proc")
            producer.procID = procID
            try MeetingCapture.check(AudioDeviceStart(aggregateID, procID), "starting the aggregate device")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
            throw error
        }
        return producer
    }

    /// The IO proc. Copies the mic's first stream and the tap's stream into
    /// the ring as one frame each, downmixing a multichannel buffer to mono
    /// in place of an allocation, and returns. No lock, no allocation, no
    /// Swift concurrency.
    private static func consume(_ p: Producer, _ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let time = inputTime.pointee
        let mic = p.micBuffers.first.flatMap { $0 < buffers.count ? mono(buffers[$0]) : nil }
        let tap = p.tapBuffer.flatMap { $0 < buffers.count ? mono(buffers[$0]) : nil }
        // The shorter of the two is padded with zeros, so the tracks stay aligned.
        p.ring.write(mic?.samples, count: mic?.frames ?? 0, tap?.samples, count: tap?.frames ?? 0)
        let frames = max(mic?.frames ?? 0, tap?.frames ?? 0)
        // The clock is followed from the first callback that carries audio;
        // the device's opening callbacks can be empty and its sample time
        // settles with them.
        if frames > 0 {
            if p.callbacks == 0 { p.firstHostTime.store(time.mHostTime, ordering: .releasing) }
            p.callbacks += 1
            if p.expectedSampleTime >= 0, time.mSampleTime > p.expectedSampleTime + 1 {
                p.pendingGapFrames.add(Int(time.mSampleTime - p.expectedSampleTime), ordering: .relaxed)
            }
            p.expectedSampleTime = time.mSampleTime + Double(frames)
        }
        p.lastHostTime.store(time.mHostTime + UInt64(Double(frames) / p.rate * MeetingCapture.hostTicksPerSecond), ordering: .releasing)
    }

    /// One buffer's frames as mono, nil when it has none. A multichannel
    /// buffer is averaged into its first channel's slots: the buffer is ours
    /// until the proc returns.
    private static func mono(_ buffer: AudioBuffer) -> (samples: UnsafePointer<Float>, frames: Int)? {
        let channels = max(1, Int(buffer.mNumberChannels))
        let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
        guard frames > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        if channels > 1 {
            let scale = 1 / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += data[f * channels + c] }
                data[f] = sum * scale
            }
        }
        return (UnsafePointer(data), frames)
    }

    private static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    static func hostTicks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * hostTicksPerSecond)
    }

    /// Runs `first` on the drain queue and then points the capture at
    /// `sink`, so nothing the capture delivers falls between the two.
    func handOver<T>(to sink: MeetingCaptureSink, first: () -> T) -> T {
        drainQueue.sync {
            let result = first()
            self.sink = sink
            return result
        }
    }

    static func seconds(fromHostTime from: UInt64, to: UInt64) -> Double {
        to > from ? Double(to - from) / hostTicksPerSecond : 0
    }

    // MARK: Drain

    private func startDrain() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(Fixed.meetingDrainMs), repeating: .milliseconds(Fixed.meetingDrainMs))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private var micScratch: [Float] = []
    private var othersScratch: [Float] = []

    /// On the drain queue: converts the ring's new frames to 16 kHz and
    /// hands them to the sink, after any gap the device's clock skipped and
    /// before any the ring dropped for want of a drain.
    private func drain() {
        lock.lock()
        guard let p = producer, !stopped else { lock.unlock(); return }
        let first = p.firstHostTime.load(ordering: .acquiring)
        if firstHostTime == 0, first != 0 { firstHostTime = first }
        let gap = p.pendingGapFrames.exchange(0, ordering: .relaxed)
        lock.unlock()
        if gap > 0 {
            let frames = Int(Double(gap) / p.rate * AudioCapture.targetFormat.sampleRate)
            Log.meetings.notice("Capture clock skipped \(gap) frames; filling \(frames)")
            sink?.captureGap(self, frames: frames)
        }
        micScratch.removeAll(keepingCapacity: true)
        othersScratch.removeAll(keepingCapacity: true)
        _ = p.ring.read(into: &micScratch, &othersScratch)
        let dropped = p.ring.overruns - p.reportedOverruns
        p.reportedOverruns += dropped
        let mic = convert(micScratch, with: p.micConverter, rate: p.rate)
        let others = p.ring.channels > 1 ? convert(othersScratch, with: p.othersConverter, rate: p.rate) : nil
        if !mic.isEmpty || others?.isEmpty == false { sink?.capture(self, mic: mic, others: others) }
        if dropped > 0 {
            // Silence in place of what was lost, so meeting time stays sample index over the rate.
            let frames = Int(Double(dropped) / p.rate * AudioCapture.targetFormat.sampleRate)
            DebugLog.write("Meeting capture fell behind: \(frames / Meeting.framesPerMs) ms dropped")
            sink?.captureGap(self, frames: frames)
        }
    }

    private func convert(_ samples: [Float], with converter: AVAudioConverter?, rate: Double) -> [Float] {
        guard !samples.isEmpty, let converter else { return [] }
        let inFormat = converter.inputFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)), let channel = input.floatChannelData?[0] else { return [] }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        let ratio = AudioCapture.targetFormat.sampleRate / rate
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioCapture.targetFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * ratio) + 64) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { Log.meetings.error("Meeting conversion failed: \(error.localizedDescription)"); return [] }
        guard let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }

    // MARK: Device changes

    private func installListeners() {
        let selectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices]
        for selector in selectors {
            var address = MeetingCapture.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block) == noErr {
                listeners.append((address, block))
            }
        }
    }

    private func removeListeners() {
        for (address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, listenerQueue, block)
        }
        listeners = []
    }

    /// On the listener queue. Rebuilds when a member device is gone or the
    /// default output moved, reporting the outage as a gap so the writers
    /// fill it and every later timestamp stays right.
    private func devicesChanged() {
        lock.lock()
        guard let p = producer, !stopped else { lock.unlock(); return }
        let micGone = AudioCapture.deviceID(forUID: mic.uid) == nil
        let outputMoved = p.outputUID != nil && MeetingCapture.defaultDevice(input: false).flatMap { MeetingCapture.string($0, kAudioDevicePropertyDeviceUID) } != p.outputUID
        lock.unlock()
        guard micGone || outputMoved else { return }
        Log.meetings.notice("Audio devices changed (\(micGone ? "mic gone" : "output moved")); rebuilding the capture")
        DebugLog.write("Meeting capture rebuild: \(micGone ? "mic gone" : "output moved")")
        rebuild()
    }

    private func rebuild() {
        lock.lock()
        let old = producer
        producer = nil
        if mic.bluetooth, !fellBackToBuiltIn, AudioCapture.deviceID(forUID: mic.uid) == nil, let builtIn = MeetingCapture.builtInMicrophone() {
            fellBackToBuiltIn = true
            mic = builtIn
            DebugLog.write("Meeting capture: the bluetooth mic went away; recording the built-in mic")
        }
        lock.unlock()
        if let old { tearDown(old) }
        var built: Producer?
        var lastError: Error = CaptureError.rebuildFailed
        for attempt in 1...Fixed.meetingRebuildAttempts {
            do { built = try build(); break } catch {
                lastError = error
                Log.meetings.error("Capture rebuild \(attempt) failed: \(error.localizedDescription)")
                Thread.sleep(forTimeInterval: TimeInterval(Fixed.meetingRebuildIntervalSeconds))
            }
        }
        guard let built else {
            lock.lock(); stopped = true; lock.unlock()
            sink?.captureFailed(self, error: lastError)
            return
        }
        // A `stop` since the rebuild began found no producer to tear down, so
        // installing this one would leave it running, holding the mic and
        // output it was built on, until the app quits.
        lock.lock()
        let stoppedDuringRebuild = stopped
        if !stoppedDuringRebuild { producer = built }
        lock.unlock()
        if stoppedDuringRebuild {
            DebugLog.write("Meeting capture rebuild: stopped meanwhile; the new device torn down")
            tearDown(built)
            return
        }
        // The gap runs from the old producer's last frame to the new one's
        // first callback, which has not happened yet: wait one drain for it.
        let lastHostTime = old?.lastHostTime.load(ordering: .acquiring) ?? 0
        drainQueue.asyncAfter(deadline: .now() + .milliseconds(Fixed.meetingDrainMs * 2)) { [weak self] in
            guard let self else { return }
            let first = built.firstHostTime.load(ordering: .acquiring)
            guard lastHostTime > 0, first > lastHostTime else { return }
            let frames = Int(MeetingCapture.seconds(fromHostTime: lastHostTime, to: first) * AudioCapture.targetFormat.sampleRate)
            self.sink?.captureGap(self, frames: frames)
        }
    }

    // MARK: Tap changes

    /// Retargets the tap at `processes` in place; rebuilds when the HAL
    /// refuses the description update.
    func updateTap(processes: [AudioObjectID]) {
        lock.lock()
        tapProcesses = processes
        let p = producer
        lock.unlock()
        guard let p, p.tapID != 0 else { return }
        let description = CATapDescription(monoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.isProcessRestoreEnabled = true
        var address = MeetingCapture.address(kAudioTapPropertyDescription)
        var value: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectSetPropertyData(p.tapID, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size), $0)
        }
        if status == noErr {
            DebugLog.write("Meeting tap retargeted at \(processes.count) process objects")
        } else {
            Log.meetings.notice("Tap description update refused (\(status)); rebuilding")
            listenerQueue.async { [weak self] in self?.rebuild() }
        }
    }

    // MARK: Stop

    /// Teardown in the order that does not corrupt the file: stop, destroy
    /// the proc, a barrier onto the drain queue, then the aggregate and the
    /// tap (docs/meetings.md 3.2).
    private func tearDown(_ p: Producer) {
        if let procID = p.procID {
            AudioDeviceStop(p.aggregateID, procID)
            AudioDeviceDestroyIOProcID(p.aggregateID, procID)
        }
        drainQueue.sync(flags: .barrier) {}
        AudioHardwareDestroyAggregateDevice(p.aggregateID)
        if p.tapID != 0 { AudioHardwareDestroyProcessTap(p.tapID) }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let p = producer
        producer = nil
        lock.unlock()
        removeListeners()
        drainTimer?.cancel()
        drainTimer = nil
        if let p { tearDown(p) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}
