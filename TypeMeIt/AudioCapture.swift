import AVFoundation
import CoreAudio
import Foundation

/// The dictation mic, through an input-only AUHAL that exists only while
/// recording, converted to 16 kHz mono Float32. Nothing is opened on the
/// output side and nothing is held between dictations: a Bluetooth headset
/// held as an input stays in its headset profile, and its output with it,
/// so system sounds would play in mono 16 kHz and the headset's mic would
/// come on with them. The callback runs on the audio thread, so the buffer
/// is guarded by a lock. The unit is built, rebuilt and released on the
/// main actor only.
final class AudioCapture: @unchecked Sendable {
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    /// The most frames the unit hands over in one callback, so the render
    /// buffer is allocated once, off the audio thread.
    private static let maxFramesPerCallback: UInt32 = 4096

    private let lock = NSLock()
    private var samples: [Float] = []
    private var recording = false
    private var converter: AVAudioConverter?
    private var unit: AudioUnit?
    private var deviceID = AudioDeviceID(0)
    private var deviceRate: Float64 = 0
    private var renderBuffer: AVAudioPCMBuffer?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []

    /// Level in 0...1 for the pill, published at most 30 times a second.
    var onLevel: (@Sendable (Float) -> Void)?
    var onFirstBuffer: (@Sendable () -> Void)?
    private var lastLevelAt: TimeInterval = 0
    /// Loudest sample since the last level report, so a consonant that lands
    /// between reports still reaches the puff.
    private var peakSinceReport: Float = 0
    private var firstBufferReported = false

    deinit { stopUnit() }

    // MARK: Device selection

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID)
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    // MARK: Unit

    private static func failure(_ what: String, _ status: OSStatus) -> NSError {
        NSError(domain: "type me it.Audio", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) failed: \(status)"])
    }

    /// AUHAL's input is element 1; element 0 is the output it is never
    /// asked to open.
    private static let inputElement: AudioUnitElement = 1

    private func startUnit(uid: String?) throws {
        guard unit == nil else { return }
        guard let device = uid.flatMap(AudioCapture.deviceID(forUID:)) ?? MeetingCapture.defaultDevice(input: true) else {
            throw NSError(domain: "type me it.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioCapture.failure("Finding AUHAL", -1) }
        var created: AudioUnit?
        var status = AudioComponentInstanceNew(component, &created)
        guard status == noErr, let newUnit = created else { throw AudioCapture.failure("Creating AUHAL", status) }
        do {
            try configure(newUnit, device: device)
            status = AudioUnitInitialize(newUnit)
            guard status == noErr else { throw AudioCapture.failure("Initializing AUHAL", status) }
            unit = newUnit
            deviceID = device
            status = AudioOutputUnitStart(newUnit)
            guard status == noErr else { throw AudioCapture.failure("Starting AUHAL", status) }
        } catch {
            unit = nil
            renderBuffer = nil
            AudioOutputUnitStop(newUnit)
            AudioUnitUninitialize(newUnit)
            AudioComponentInstanceDispose(newUnit)
            throw error
        }
        installListeners(device: device)
    }

    private func configure(_ unit: AudioUnit, device: AudioDeviceID) throws {
        var on: UInt32 = 1, off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        var status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, AudioCapture.inputElement, &on, flagSize)
        guard status == noErr else { throw AudioCapture.failure("Enabling input", status) }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize)
        guard status == noErr else { throw AudioCapture.failure("Disabling output", status) }
        var device = device
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw AudioCapture.failure("Selecting the input device", status) }

        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, AudioCapture.inputElement, &hardware, &size)
        guard status == noErr, hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else {
            throw NSError(domain: "type me it.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio input device"])
        }
        // AUHAL cannot change the input's rate, only its sample type and
        // channels; of a multichannel mic the first channel is kept.
        guard let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: client, frameCapacity: AudioCapture.maxFramesPerCallback) else {
            throw AudioCapture.failure("Making the client format", -1)
        }
        var clientDescription = client.streamDescription.pointee
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, AudioCapture.inputElement, &clientDescription, size)
        guard status == noErr else { throw AudioCapture.failure("Setting the client format", status) }
        var maxFrames = AudioCapture.maxFramesPerCallback
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))

        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<AudioCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, bus, frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard status == noErr else { throw AudioCapture.failure("Setting the input callback", status) }
        converter = AVAudioConverter(from: client, to: AudioCapture.targetFormat)
        renderBuffer = buffer
        deviceRate = hardware.mSampleRate
    }

    /// Stops and releases the unit, so nothing stays registered with the
    /// device between dictations.
    private func stopUnit() {
        removeListeners()
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        renderBuffer = nil
    }

    private func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ timeStamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) -> OSStatus {
        guard let unit, let buffer = renderBuffer, frames <= buffer.frameCapacity else { return noErr }
        buffer.frameLength = frames
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, list)
        if status == noErr { consume(buffer) }
        return status
    }

    // MARK: Device changes

    /// While recording: the default input moving, a device leaving, or the
    /// mic's rate changing (a Bluetooth headset switching profile) builds
    /// the unit again on the device that applies now. The samples so far
    /// are kept.
    private func installListeners(device: AudioDeviceID) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let watched: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal),
            (system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal),
            (device, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        ]
        for (object, selector, scope) in watched {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            // Delivered on the main queue, as the listener is added with it.
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.devicesChanged(selector) }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
                listeners.append((object, address, block))
            }
        }
    }

    private func removeListeners() {
        for (object, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        listeners = []
    }

    /// On the main queue. The default input moving matters only when the
    /// default is what is being recorded, and the device list only when the
    /// mic is gone from it or the picked mic is back.
    @MainActor private func devicesChanged(_ selector: AudioObjectPropertySelector) {
        guard unit != nil else { return }
        let picked = lastUID.flatMap(AudioCapture.deviceID(forUID:))
        switch selector {
        case kAudioHardwarePropertyDefaultInputDevice:
            guard picked == nil, MeetingCapture.defaultDevice(input: true) != deviceID else { return }
        case kAudioHardwarePropertyDevices:
            guard MeetingCapture.device(deviceID) == nil || (lastUID != nil && picked != deviceID) else { return }
        default:
            guard MeetingCapture.property(deviceID, kAudioDevicePropertyNominalSampleRate, Float64(0)) != deviceRate else { return }
        }
        Log.audio.info("Audio input changed (\(MeetingCapture.fourCC(selector))); restarting")
        DebugLog.write("Capture restart: \(MeetingCapture.fourCC(selector)) changed")
        stopUnit()
        do { try startUnit(uid: lastUID) } catch {
            Log.audio.error("Could not restart capture: \(error.localizedDescription)")
        }
    }

    private var lastUID: String?

    @MainActor func start(uid: String?) throws {
        lastUID = uid
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        recording = true
        firstBufferReported = false
        peakSinceReport = 0
        lock.unlock()
        try startUnit(uid: uid)
    }

    /// Returns 16 kHz mono Float32 samples.
    @MainActor func stop() -> [Float] {
        lock.lock()
        recording = false
        let out = samples
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        stopUnit()
        return out
    }

    @MainActor func cancel() {
        lock.lock()
        recording = false
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
        stopUnit()
    }

    /// On the audio thread.
    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let isRecording = recording
        lock.unlock()
        guard isRecording, let converter else { return }

        let ratio = AudioCapture.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioCapture.targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { Log.audio.error("Conversion failed: \(error.localizedDescription)"); return }
        let n = Int(out.frameLength)
        guard n > 0, let data = out.floatChannelData?[0] else { return }
        var peak: Float = 0
        for i in 0..<n { peak = max(peak, abs(data[i])) }
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: n))
        let report = !firstBufferReported
        firstBufferReported = true
        lock.unlock()
        if report { onFirstBuffer?() }

        let now = Date().timeIntervalSinceReferenceDate
        peakSinceReport = max(peakSinceReport, peak)
        if now - lastLevelAt >= 1.0 / 30.0 {
            lastLevelAt = now
            let level = AudioCapture.level(forPeak: peakSinceReport)
            peakSinceReport = 0
            onLevel?(level)
        }
    }

    // MARK: Devices for the settings UI

    struct Device: Identifiable, Hashable, Sendable {
        var id: String  // uniqueID
        var name: String
    }

    /// Every connected device with an input stream, named as CoreAudio
    /// names it.
    static func connectedInputs() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { MeetingCapture.streams(of: $0).contains { $0 > 0 } }
            .compactMap(MeetingCapture.device)
            .map { Device(id: $0.uid, name: $0.name) }
    }

    /// The one input with this name, or nil when none or several have it:
    /// two of the same model are told apart only by UID.
    static func uid(named name: String, among inputs: [Device]) -> String? {
        let named = inputs.filter { $0.name == name }
        return named.count == 1 ? named[0].id : nil
    }

    static func inputDevices() -> [Device] {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        return session.devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// A peak sample as a meter level in 0...1: −52 dBFS is empty, −2 dBFS full.
    static func level(forPeak peak: Float) -> Float {
        let db = 20 * log10(max(peak * 0.8, 1e-6))
        return min(1, max(0, (db + 52) / 50))
    }

    static func peak(_ pcm: [Float]) -> Float {
        var p: Float = 0
        for v in pcm { let a = abs(v); if a > p { p = a } }
        return p
    }
}
