import AVFoundation
import SwiftUI

/// Feeds the type me it camera while a meeting app shows it: the real
/// camera through `CameraCompositor`, which adds the cloud while Claude
/// works on a question and the answer when it comes, while a meeting
/// records with on camera turned on. The real camera runs only while some
/// app is showing the type me it camera.
@MainActor @Observable
final class CameraFeed {
    static let shared = CameraFeed()

    /// The type me it camera is added and allowed, so macOS lists it.
    private(set) var installed = false
    /// A meeting app is showing it.
    private(set) var watched = false
    /// The cameras it can show, the type me it camera left out.
    private(set) var cameras: [AVCaptureDevice] = []

    /// How often the feed checks whether an app is showing the camera.
    static let checkInterval: Duration = .milliseconds(500)
    /// How often it looks for the camera while macOS doesn't list it, so a
    /// camera just added or allowed is found without a relaunch.
    static let lookInterval: TimeInterval = 3
    /// How often the cloud is drawn, while Claude works.
    static let cloudInterval: Duration = .milliseconds(33)
    /// The cloud's image, square, in points; the puff fills about half of it.
    static let cloudPoints: CGFloat = 420
    /// A debug build launched with TYPEMEIT_CAMERA_CLOUD set keeps the cloud
    /// on the camera whatever the meeting does, to check how it looks.
    static let holdsCloud: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["TYPEMEIT_CAMERA_CLOUD"] != nil
        #else
        false
        #endif
    }()

    @ObservationIgnored private let compositor = CameraCompositor()
    @ObservationIgnored private var sink: CameraSink?
    @ObservationIgnored private var capture: CameraCapture?
    @ObservationIgnored private var checking: Task<Void, Never>?
    @ObservationIgnored private var drawing: Task<Void, Never>?
    @ObservationIgnored private let settings = Settings.shared
    @ObservationIgnored private var looked = false
    @ObservationIgnored private var lastLook = Date.distantPast
    /// The cloud or an answer is on the camera.
    @ObservationIgnored private var extrasShowing = false

    private init() {}

    func start() {
        guard checking == nil else { return }
        if Self.holdsCloud { asking() }
        // The camera is looked for at launch, when a camera comes or goes, and every few seconds while it isn't there.
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let feed = CameraFeed.shared
                    feed.looked = false
                    feed.refreshCameras()
                }
            }
        }
        checking = Task { [weak self] in
            while !Task.isCancelled {
                self?.check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    // MARK: Looks

    /// The cloud and answers show only while a meeting records with ask and
    /// on camera turned on.
    private var showsExtras: Bool {
        Self.holdsCloud || (settings.askClaude && settings.askClaudeOnCamera && MeetingCoordinator.shared.recording != nil)
    }

    /// Claude is working on a question: the cloud sits on the user's forehead,
    /// white or black against what is behind it, lightning striking through
    /// it once a second as it does through the pill while a dictation is
    /// processed.
    func asking() {
        guard showsExtras else { return }
        extrasShowing = true
        compositor.show(.asking)
        drawing?.cancel()
        drawing = Task { [weak self] in
            let start = Date().timeIntervalSinceReferenceDate
            while !Task.isCancelled, let self {
                if self.capture != nil,
                   let cloud = Self.cloud(at: Date().timeIntervalSinceReferenceDate - start, over: self.compositor.backdrop) {
                    self.compositor.setCloud(cloud)
                }
                try? await Task.sleep(for: Self.cloudInterval)
            }
        }
    }

    /// Claude answered: the answer in front, the user behind it.
    func answer(question: String, answer: String) {
        guard !Self.holdsCloud else { return }
        guard showsExtras else { return clear() }
        extrasShowing = true
        drawing?.cancel()
        compositor.setCard(CameraAnswerCard.image(question: question, answer: answer))
        compositor.show(.answer)
    }

    func clear() {
        guard !Self.holdsCloud else { return }
        extrasShowing = false
        drawing?.cancel()
        compositor.show(.camera)
    }

    /// The pill's puff at full size, `seconds` into it. The shader seeds
    /// each strike's route from its time, so each one is different.
    private static func cloud(at seconds: Double, over backdrop: ScreenSampler.Backdrop?) -> CGImage? {
        let now = 100 + seconds
        let puff = PuffView(expansion: 1, tint: backdrop == .light ? .black : .white, frozenTime: now,
                            strike: Date(timeIntervalSinceReferenceDate: now.rounded(.down)), density: 1.2)
        let renderer = ImageRenderer(content: puff.frame(width: cloudPoints, height: cloudPoints))
        renderer.scale = 1
        return renderer.cgImage
    }

    // MARK: Following the camera

    private func check() {
        if !looked || (sink == nil && Date().timeIntervalSince(lastLook) > Self.lookInterval) {
            looked = true
            lastLook = Date()
            stopCapture()
            sink = CameraSink.find()
            refreshCameras()
        }
        installed = sink != nil
        // The meeting stopped recording, or on camera went off, mid-answer.
        if extrasShowing, !showsExtras { clear() }
        guard let sink else {
            watched = false
            stopCapture()
            return
        }
        watched = sink.watchers > 0
        if watched, capture == nil {
            startCapture(sink)
        } else if !watched, capture != nil {
            stopCapture()
        }
    }

    func refreshCameras() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
            .filter { $0.localizedName != CameraIDs.name && $0.uniqueID.caseInsensitiveCompare(CameraIDs.deviceID.uuidString) != .orderedSame }
    }

    /// The chosen camera, or the Mac's default, or the built-in one, or the first there is.
    private var chosenCamera: AVCaptureDevice? {
        let systemDefault = AVCaptureDevice.default(for: .video).flatMap { device in cameras.first { $0.uniqueID == device.uniqueID } }
        return cameras.first { $0.uniqueID == settings.meetingCamera }
            ?? systemDefault
            ?? cameras.first { $0.deviceType == .builtInWideAngleCamera }
            ?? cameras.first
    }

    private func startCapture(_ sink: CameraSink) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            Task {
                // The next check starts the capture once it is allowed.
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            return
        default:
            return
        }
        guard let camera = chosenCamera else {
            DebugLog.write("Camera: no camera to show")
            return
        }
        guard let capture = CameraCapture(camera: camera, compositor: compositor, sink: sink) else { return }
        self.capture = capture
        capture.start()
        DebugLog.write("Camera: showing \(camera.localizedName) through the type me it camera")
    }

    private func stopCapture() {
        guard let capture else { return }
        self.capture = nil
        capture.stop()
        DebugLog.write("Camera: stopped, no app is showing the type me it camera")
    }

    /// The chosen camera changed while showing: show the new one.
    func cameraChanged() {
        stopCapture()
        check()
    }
}

/// The real camera's frames, each made into the type me it camera's frame
/// and handed to its sink. One queue for every capture, so a capture that
/// stops has closed the sink before the next one opens it.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    static let queue = DispatchQueue(label: "it.typeme.camera.capture", qos: .userInteractive)

    private let session = AVCaptureSession()
    private let camera: AVCaptureDevice
    private let compositor: CameraCompositor
    private let sink: CameraSink

    init?(camera: AVCaptureDevice, compositor: CameraCompositor, sink: CameraSink) {
        self.camera = camera
        self.compositor = compositor
        self.sink = sink
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            DebugLog.write("Camera: \(camera.localizedName) did not open")
            return nil
        }
        session.addInput(input)
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: Self.queue)
        guard session.canAddOutput(output) else { return nil }
        session.addOutput(output)
    }

    func start() {
        Self.queue.async {
            guard self.sink.open() else { return }
            self.session.startRunning()
            self.holdFrameRate()
        }
    }

    /// In dim light the camera lengthens its exposure and drops to about 15
    /// frames a second unless asked for more, as a meeting app asks it
    /// directly. Held at the camera's own rate, the picture is darker but
    /// moves smoothly. Set once running, since starting the session resets it.
    private func holdFrameRate() {
        let rate = Double(CameraIDs.framesPerSecond)
        guard camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.maxFrameRate >= rate }),
              (try? camera.lockForConfiguration()) != nil else { return }
        let frame = CMTime(value: 1, timescale: CameraIDs.framesPerSecond)
        camera.activeVideoMinFrameDuration = frame
        camera.activeVideoMaxFrameDuration = frame
        camera.unlockForConfiguration()
    }

    func stop() {
        Self.queue.async {
            self.session.stopRunning()
            self.sink.close()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = sampleBuffer.imageBuffer, let frame = compositor.render(pixels) else { return }
        sink.send(frame)
    }
}
