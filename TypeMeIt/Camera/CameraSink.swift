import AVFoundation
import CoreMediaIO

/// The type me it camera (Camera/Extension) as the app reaches it through
/// Core Media I/O: whether a meeting app is showing it, and the queue the
/// app's frames go into. Opened, fed and closed on `CameraCapture.queue`.
final class CameraSink: @unchecked Sendable {
    private let device: CMIOObjectID
    private let source: CMIOStreamID
    private let sink: CMIOStreamID
    private var queue: CMSimpleQueue?
    private var format: CMVideoFormatDescription?

    private init(device: CMIOObjectID, source: CMIOStreamID, sink: CMIOStreamID) {
        self.device = device
        self.source = source
        self.sink = sink
    }

    /// The camera's AVFoundation device, when the camera is installed.
    static var captureDevice: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
            .first { $0.uniqueID.caseInsensitiveCompare(CameraIDs.deviceID.uuidString) == .orderedSame || $0.localizedName == CameraIDs.name }
    }

    static func find() -> CameraSink? {
        guard let uid = captureDevice?.uniqueID,
              let device = objects(CMIOObjectID(kCMIOObjectSystemObject), CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
                .first(where: { string($0, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == uid })
        else { return nil }
        // The extension adds its source stream first and its sink second.
        let streams = objects(device, CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
        guard streams.count >= 2 else { return nil }
        return CameraSink(device: device, source: streams[0], sink: streams[1])
    }

    /// How many apps are showing the camera, from the extension's own count.
    var watchers: Int {
        Self.string(source, CameraIDs.watchersSelector).flatMap { Int($0) } ?? 0
    }

    func open() -> Bool {
        guard queue == nil else { return true }
        var copied: Unmanaged<CMSimpleQueue>?
        let status = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &copied)
        guard status == noErr, let copied else {
            DebugLog.write("Camera: the sink's queue did not open (\(status))")
            return false
        }
        queue = copied.takeRetainedValue()
        let started = CMIODeviceStartStream(device, sink)
        guard started == noErr else {
            DebugLog.write("Camera: the sink did not start (\(started))")
            queue = nil
            return false
        }
        return true
    }

    func close() {
        guard queue != nil else { return }
        CMIODeviceStopStream(device, sink)
        queue = nil
    }

    /// Hands a frame to the camera; dropped while the last one is still queued.
    func send(_ pixels: CVPixelBuffer) {
        guard let queue, CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: pixels) {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(CameraIDs.framesPerSecond)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &frame)
        // The queue owns what it holds; the extension takes it from there.
        if let frame { CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(frame).toOpaque()) }
    }

    // MARK: Core Media I/O properties

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func string(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var address = address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value) == noErr
        else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
