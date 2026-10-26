import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio

/// What Core Media I/O starts the extension with: one camera.
final class CameraProvider: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private var camera: CameraDevice!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        camera = CameraDevice()
        do {
            try provider.addDevice(camera.device)
        } catch {
            fatalError("The camera was not added: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { providerProperties.manufacturer = CameraIDs.manufacturer }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// The camera: a source stream meeting apps read, and a sink stream the app
/// writes its frames into. A frame the app writes goes straight out; while
/// none has come for a moment, the camera shows a frame saying so.
final class CameraDevice: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    static let frameDuration = CMTime(value: 1, timescale: CMTimeScale(CameraIDs.framesPerSecond))
    /// After this long without a frame from the app, the placeholder shows.
    static let staleNanoseconds: UInt64 = 500_000_000
    /// How long to wait before asking the sink again when it had nothing.
    static let retry: DispatchTimeInterval = .milliseconds(10)

    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStream!
    private var sink: CameraStream!
    private let format: CMVideoFormatDescription
    private let placeholder: CVPixelBuffer?

    /// The state below is only touched on this queue, but for `watchers`,
    /// which the streams' properties read from Core Media I/O's own queue.
    private let queue = DispatchQueue(label: "it.typeme.camera.frames", qos: .userInteractive)
    private let watchersLock = NSLock()
    private var watchers = 0
    private var feeder: CMIOExtensionClient?
    private var lastFrame: UInt64 = 0
    private var timer: DispatchSourceTimer?

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: CameraIDs.width, height: CameraIDs.height, extensions: nil,
                                       formatDescriptionOut: &description)
        format = description!
        placeholder = Self.drawPlaceholder()
        super.init()
        device = CMIOExtensionDevice(localizedName: CameraIDs.name, deviceID: CameraIDs.deviceID, legacyDeviceID: nil, source: self)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: Self.frameDuration,
                                                     minFrameDuration: Self.frameDuration, validFrameDurations: nil)
        source = CameraStream(name: CameraIDs.name, id: CameraIDs.sourceStreamID, direction: .source, format: streamFormat, camera: self)
        sink = CameraStream(name: "\(CameraIDs.name) input", id: CameraIDs.sinkStreamID, direction: .sink, format: streamFormat, camera: self)
        do {
            // The app finds the sink as the second stream.
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("The camera's streams were not added: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { deviceProperties.model = CameraIDs.name }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Watchers

    var watcherCount: Int { watchersLock.withLock { watchers } }

    func sourceStarted() {
        queue.async { self.watchersChanged(by: 1) }
    }

    func sourceStopped() {
        queue.async { self.watchersChanged(by: -1) }
    }

    private func watchersChanged(by change: Int) {
        let watchers = watchersLock.withLock {
            self.watchers = max(0, self.watchers + change)
            return self.watchers
        }
        let property = CMIOExtensionProperty(rawValue: CameraIDs.watchersProperty)
        source.stream.notifyPropertiesChanged([property: CMIOExtensionPropertyState<AnyObject>(value: String(watchers) as NSString)])
        if watchers > 0, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: CameraDevice.frameDuration.seconds, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        } else if watchers == 0 {
            timer?.cancel()
            timer = nil
        }
    }

    /// Sends the placeholder while the app sends nothing.
    private func tick() {
        let now = Self.hostNanoseconds
        guard now &- lastFrame > Self.staleNanoseconds, let placeholder, let frame = sampleBuffer(placeholder, at: now) else { return }
        source.stream.send(frame, discontinuity: [], hostTimeInNanoseconds: now)
    }

    // MARK: Sink

    func sinkStarted(by client: CMIOExtensionClient) {
        queue.async {
            self.feeder = client
            self.consume(from: client)
        }
    }

    func sinkStopped() {
        queue.async { self.feeder = nil }
    }

    /// Takes the app's frames one after another and sends each straight on.
    private func consume(from client: CMIOExtensionClient) {
        sink.stream.consumeSampleBuffer(from: client) { [weak self] frame, sequence, _, _, _ in
            guard let self else { return }
            self.queue.async {
                guard self.feeder === client else { return }
                guard let frame else {
                    self.queue.asyncAfter(deadline: .now() + Self.retry) {
                        if self.feeder === client { self.consume(from: client) }
                    }
                    return
                }
                let now = Self.hostNanoseconds
                self.lastFrame = now
                if self.watcherCount > 0 { self.source.stream.send(frame, discontinuity: [], hostTimeInNanoseconds: now) }
                self.sink.stream.notifyScheduledOutputChanged(CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                self.consume(from: client)
            }
        }
    }

    // MARK: Frames

    static var hostNanoseconds: UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
    }

    private func sampleBuffer(_ pixels: CVPixelBuffer, at nanoseconds: UInt64) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: Self.frameDuration,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(nanoseconds), timescale: CMTimeScale(NSEC_PER_SEC)),
                                        decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &frame)
        return frame
    }

    /// A dark frame that says the app is sending nothing.
    private static func drawPlaceholder() -> CVPixelBuffer? {
        let width = Int(CameraIDs.width), height = Int(CameraIDs.height)
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &pixels)
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return pixels }
        context.setFillColor(CGColor(srgbRed: 0.0431, green: 0.0431, blue: 0.0431, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateUIFontForLanguage(.userFixedPitch, 30, nil)
        let text = NSAttributedString(string: "no video from type me it", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.7059, green: 0.7059, blue: 0.7059, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return pixels
    }
}

/// One of the camera's two streams.
final class CameraStream: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private unowned let camera: CameraDevice
    /// The app that asked to write into the sink, until it starts it.
    private var asking: CMIOExtensionClient?

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat, camera: CameraDevice) {
        self.format = format
        self.direction = direction
        self.camera = camera
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    private static let watchers = CMIOExtensionProperty(rawValue: CameraIDs.watchersProperty)

    var availableProperties: Set<CMIOExtensionProperty> {
        let shared: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        guard direction == .sink else { return shared.union([Self.watchers]) }
        return shared.union([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                             .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { streamProperties.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { streamProperties.frameDuration = CameraDevice.frameDuration }
        // One frame queued at a time: a late frame is dropped, not shown late.
        if properties.contains(.streamSinkBufferQueueSize) { streamProperties.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { streamProperties.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(Self.watchers) {
            streamProperties.setPropertyState(CMIOExtensionPropertyState(value: String(camera.watcherCount) as NSString), forProperty: Self.watchers)
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    /// Anyone may watch, and any app may write. Core Media I/O gives every
    /// client's signing id as "unknown", and the sandbox keeps the extension
    /// from reading another process's signature, so a writer cannot be told
    /// apart. The camera shows what is written only while a meeting app has
    /// it chosen.
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if direction == .sink { asking = client }
        return true
    }

    func startStream() throws {
        if direction == .source {
            camera.sourceStarted()
        } else if let asking {
            camera.sinkStarted(by: asking)
        }
    }

    func stopStream() throws {
        if direction == .source { camera.sourceStopped() } else { camera.sinkStopped() }
    }
}
