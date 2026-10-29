import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Vision

/// The frames the type me it camera shows: the real camera as it is; while
/// Claude works, the cloud on the person's forehead, which Vision's face
/// detection finds; with an answer, the answer in front and the person
/// dimmed behind it. Called on the capture queue; `show` and the images come
/// from the main actor. Face detection runs on a queue of its own, one frame
/// at a time, and each frame uses the newest face found.
final class CameraCompositor: @unchecked Sendable {
    enum Look: Equatable, Sendable {
        case camera
        case asking
        case answer
    }

    static let size = CGSize(width: CGFloat(CameraIDs.width), height: CGFloat(CameraIDs.height))
    /// How long one look takes to turn into the next.
    static let fadeSeconds = 0.35
    /// How much of its image's side the puff fills.
    static let cloudFill: CGFloat = 0.34
    /// The puff's width as a multiple of the face's height.
    static let faceCover: CGFloat = 0.55
    /// How far above the face's middle the cloud's centre sits, as a share of
    /// the face's height: at the forehead.
    static let faceLift: CGFloat = 0.55
    /// Where the cloud goes until a face is found.
    static let cloudAlone = CloudPlace(face: nil, centre: CGPoint(x: 0.5, y: 0.5), puff: 0.5)
    /// How much of the way to the face just found the cloud moves.
    static let follow: CGFloat = 0.5
    /// Frames between reads of how light the picture behind the cloud is.
    static let backdropEvery = 15
    /// Frames between the debug overlay's timings going to the debug log.
    static let timingLogEvery = 150
    /// The person behind an answer: blurred this much and dimmed to this.
    static let backgroundBlur = 12.0
    static let backgroundDim: CGFloat = 0.5
    /// A debug build launched with TYPEMEIT_CAMERA_DEBUG set draws what the
    /// cloud is placed by: the face found, where the cloud is headed and
    /// where it is now, how light the picture behind it is, and how long
    /// frames take.
    static let drawsDebug: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["TYPEMEIT_CAMERA_DEBUG"] != nil
        #else
        false
        #endif
    }()

    /// Where the cloud goes, as shares of the frame, y counting up: the face
    /// it covers, its centre, and the puff's width as a share of the frame's
    /// height.
    struct CloudPlace: Equatable, Sendable {
        var face: CGRect?
        var centre: CGPoint
        var puff: CGFloat
    }

    /// How a frame went, for the debug overlay.
    private struct Timing {
        var renderMilliseconds = 0.0
        var lastFrame: TimeInterval?
        var framesPerSecond = 0.0
    }

    private let lock = NSLock()
    private var look = Look.camera
    private var previous = Look.camera
    private var changed = 0.0
    private var cloud: CIImage?
    private var card: CIImage?
    private var detecting = false
    /// Snap to the next face found rather than glide there.
    private var placed = false
    private var cloudNow = CameraCompositor.cloudAlone
    private var target: CloudPlace?
    private var backdropNow: ScreenSampler.Backdrop?
    private var luminance: Double?
    private var timing = Timing()

    private let context = CIContext(options: [.cacheIntermediates: false, .name: "camera"])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var pool: CVPixelBufferPool?
    private let faces = VNDetectFaceRectanglesRequest()
    private let sequence = VNSequenceRequestHandler()
    private let faceQueue = DispatchQueue(label: "it.typeme.camera.face", qos: .userInitiated)
    private var frames = 0

    // MARK: From the main actor

    func show(_ look: Look) {
        lock.withLock {
            guard look != self.look else { return }
            previous = self.look
            self.look = look
            changed = ProcessInfo.processInfo.systemUptime
            // Where someone was at the last question says nothing about now.
            if look == .asking { placed = false }
        }
    }

    /// This instant of the cloud, square, with alpha.
    func setCloud(_ image: CGImage) {
        lock.withLock { cloud = CIImage(cgImage: image) }
    }

    /// The answer as it shows on camera, with alpha.
    func setCard(_ image: CGImage?) {
        lock.withLock { card = image.map { CIImage(cgImage: $0) } }
    }

    /// Whether the picture behind the cloud is light or dark, once read.
    var backdrop: ScreenSampler.Backdrop? {
        lock.withLock { backdropNow }
    }

    // MARK: On the capture queue

    /// The frame to show for this one from the real camera.
    func render(_ camera: CVPixelBuffer) -> CVPixelBuffer? {
        let started = ProcessInfo.processInfo.systemUptime
        let (look, previous, since, cloud, card) = lock.withLock {
            (self.look, self.previous, started - changed, self.cloud, self.card)
        }
        let frame = Self.filling(CIImage(cvPixelBuffer: camera))
        let fade = min(1, since / Self.fadeSeconds)
        let wantsFace = look == .asking || (fade < 1 && previous == .asking)
        if wantsFace { findFace(camera) }
        let place = lock.withLock { cloudNow }
        frames += 1
        if wantsFace, frames % Self.backdropEvery == 0 { readBackdrop(frame, behind: place) }
        let showing = { (look: Look) -> CIImage in
            switch look {
            case .camera: frame
            case .asking: cloud.map { Self.asking(frame, cloud: $0, at: place) } ?? frame
            case .answer: card.map { Self.answering(frame, card: $0) } ?? frame
            }
        }
        var output = showing(look)
        if fade < 1 {
            let transition = CIFilter.dissolveTransition()
            transition.inputImage = showing(previous)
            transition.targetImage = output
            transition.time = Float(fade)
            output = transition.outputImage ?? output
        }
        if Self.drawsDebug {
            let (target, luminance, timing) = lock.withLock { (self.target, self.luminance, self.timing) }
            output = Self.debugOverlay(output, place: place, target: target, luminance: luminance, timing: timing)
        }
        guard let pixels = outputBuffer() else { return nil }
        context.render(output, to: pixels, bounds: CGRect(origin: .zero, size: Self.size), colorSpace: colorSpace)
        if Self.drawsDebug {
            let finished = ProcessInfo.processInfo.systemUptime
            let timing = lock.withLock {
                self.timing.renderMilliseconds = (finished - started) * 1000
                if let last = self.timing.lastFrame { self.timing.framesPerSecond = 1 / max(started - last, 0.001) }
                self.timing.lastFrame = started
                return self.timing
            }
            if frames % Self.timingLogEvery == 0 {
                DebugLog.write(String(format: "Camera: %.0f fps, this frame took %.1f ms", timing.framesPerSecond, timing.renderMilliseconds))
            }
        }
        return pixels
    }

    /// The camera's picture scaled to fill the frame, cropped at its middle.
    static func filling(_ image: CIImage) -> CIImage {
        image.transformed(by: fillingTransform(for: image.extent.size)).cropped(to: CGRect(origin: .zero, size: size))
    }

    private static func fillingTransform(for source: CGSize) -> CGAffineTransform {
        let scale = max(size.width / source.width, size.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: (size.width - source.width * scale) / 2,
                                             y: (size.height - source.height * scale) / 2))
    }

    /// Finds the biggest face in this frame on the face queue, unless it is
    /// still busy with an earlier one, and moves the cloud toward it.
    private func findFace(_ camera: CVPixelBuffer) {
        let start = lock.withLock {
            guard !detecting else { return false }
            detecting = true
            return true
        }
        guard start else { return }
        faceQueue.async {
            let cameraSize = CGSize(width: CVPixelBufferGetWidth(camera), height: CVPixelBufferGetHeight(camera))
            let biggest = (try? self.sequence.perform([self.faces], on: camera)) == nil ? nil
                : self.faces.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
            let target = biggest.map { Self.cloudPlace(face: Self.faceInFrame($0.boundingBox, cameraSize: cameraSize)) }
            self.lock.withLock {
                self.detecting = false
                guard let target else { return }
                self.target = target
                if self.placed {
                    self.cloudNow.centre.x += (target.centre.x - self.cloudNow.centre.x) * Self.follow
                    self.cloudNow.centre.y += (target.centre.y - self.cloudNow.centre.y) * Self.follow
                    self.cloudNow.puff += (target.puff - self.cloudNow.puff) * Self.follow
                    self.cloudNow.face = target.face
                } else {
                    self.cloudNow = target
                    self.placed = true
                }
            }
        }
    }

    /// A face's box from Vision, in shares of the camera's picture, in
    /// shares of the frame that picture fills.
    static func faceInFrame(_ box: CGRect, cameraSize: CGSize) -> CGRect {
        let inFrame = VNImageRectForNormalizedRect(box, Int(cameraSize.width), Int(cameraSize.height))
            .applying(fillingTransform(for: cameraSize))
        return CGRect(x: inFrame.minX / size.width, y: inFrame.minY / size.height,
                      width: inFrame.width / size.width, height: inFrame.height / size.height)
    }

    /// The cloud on the forehead of a face at `face`, in shares of the frame.
    static func cloudPlace(face: CGRect) -> CloudPlace {
        CloudPlace(face: face, centre: CGPoint(x: face.midX, y: face.midY + face.height * faceLift), puff: face.height * faceCover)
    }

    /// Reads how light the picture is where the cloud covers it, the way the
    /// pill reads the screen under it.
    private func readBackdrop(_ frame: CIImage, behind place: CloudPlace) {
        let side = place.puff * Self.size.height
        let behind = CGRect(x: place.centre.x * Self.size.width - side / 2, y: place.centre.y * Self.size.height - side / 2,
                            width: side, height: side).intersection(frame.extent)
        guard !behind.isEmpty else { return }
        let average = CIFilter.areaAverage()
        average.inputImage = frame
        average.extent = behind
        guard let mean = average.outputImage, let pixel = context.createCGImage(mean, from: mean.extent),
              let luminance = ScreenSampler.luminance(of: pixel) else { return }
        lock.withLock {
            self.luminance = luminance
            backdropNow = ScreenSampler.backdrop(luminance: luminance)
        }
    }

    /// The cloud over the frame, in front of the person's head.
    private static func asking(_ frame: CIImage, cloud: CIImage, at place: CloudPlace) -> CIImage {
        let side = place.puff / cloudFill * size.height
        let scale = side / cloud.extent.height
        return cloud.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: place.centre.x * size.width - side / 2,
                                             y: place.centre.y * size.height - side / 2)))
            .cropped(to: frame.extent)
            .composited(over: frame)
    }

    // MARK: Debug overlay

    /// Red: the face found and the cloud's target centre. Yellow: the
    /// cloud's centre and puff now. The numbers are shares of the frame, y up.
    private static func debugOverlay(_ image: CIImage, place: CloudPlace, target: CloudPlace?, luminance: Double?,
                                     timing: Timing) -> CIImage {
        let red = CIColor(red: 1, green: 0.2, blue: 0.2), yellow = CIColor(red: 1, green: 0.9, blue: 0)
        var overlaid = image
        var lines = [String]()
        if let target, let face = target.face {
            overlaid = outline(face, red, over: overlaid)
            overlaid = cross(target.centre, red, over: overlaid)
            lines.append(String(format: "face x %.2f–%.2f  y %.2f–%.2f", face.minX, face.maxX, face.minY, face.maxY))
            lines.append(String(format: "target %.2f, %.2f  puff %.2f", target.centre.x, target.centre.y, target.puff))
        } else {
            lines.append("no face yet")
        }
        let puffWidth = place.puff * size.height / size.width
        overlaid = outline(CGRect(x: place.centre.x - puffWidth / 2, y: place.centre.y - place.puff / 2, width: puffWidth, height: place.puff),
                           yellow, over: overlaid)
        overlaid = cross(place.centre, yellow, over: overlaid)
        lines.append(String(format: "now %.2f, %.2f  puff %.2f", place.centre.x, place.centre.y, place.puff))
        if let luminance {
            lines.append(String(format: "behind %.2f: %@ cloud", luminance,
                                ScreenSampler.backdrop(luminance: luminance) == .light ? "black" : "white"))
        }
        lines.append(String(format: "frame %.1f ms  %.0f fps", timing.renderMilliseconds, timing.framesPerSecond))
        let text = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ])
        let generator = CIFilter.attributedTextImageGenerator()
        generator.text = text
        guard let label = generator.outputImage else { return overlaid }
        // Flipped, so it reads in a meeting app's mirrored self-view, and
        // at the top middle, clear of Meet's buttons.
        let margin: CGFloat = 16
        return label.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
            .concatenating(CGAffineTransform(translationX: (size.width + label.extent.width) / 2,
                                             y: size.height - label.extent.height - margin)))
            .composited(over: overlaid)
    }

    /// `rect`'s edges, in shares of the frame, drawn over `image`.
    private static func outline(_ rect: CGRect, _ color: CIColor, over image: CIImage) -> CIImage {
        let box = CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
        let line: CGFloat = 3
        let edges = [CGRect(x: box.minX, y: box.minY, width: box.width, height: line),
                     CGRect(x: box.minX, y: box.maxY - line, width: box.width, height: line),
                     CGRect(x: box.minX, y: box.minY, width: line, height: box.height),
                     CGRect(x: box.maxX - line, y: box.minY, width: line, height: box.height)]
        return edges.reduce(image) { CIImage(color: color).cropped(to: $1).composited(over: $0) }
    }

    /// A cross at `point`, in shares of the frame, drawn over `image`.
    private static func cross(_ point: CGPoint, _ color: CIColor, over image: CIImage) -> CIImage {
        let x = point.x * size.width, y = point.y * size.height
        let arm: CGFloat = 18, line: CGFloat = 3
        return [CGRect(x: x - arm, y: y - line / 2, width: arm * 2, height: line),
                CGRect(x: x - line / 2, y: y - arm, width: line, height: arm * 2)]
            .reduce(image) { CIImage(color: color).cropped(to: $1).composited(over: $0) }
    }

    /// The answer in front, the person blurred and dimmed behind it.
    private static func answering(_ frame: CIImage, card: CIImage) -> CIImage {
        let dim = CIFilter.colorMatrix()
        dim.inputImage = frame.clampedToExtent().applyingGaussianBlur(sigma: backgroundBlur).cropped(to: frame.extent)
        dim.rVector = CIVector(x: backgroundDim, y: 0, z: 0, w: 0)
        dim.gVector = CIVector(x: 0, y: backgroundDim, z: 0, w: 0)
        dim.bVector = CIVector(x: 0, y: 0, z: backgroundDim, w: 0)
        let background = dim.outputImage ?? frame
        let placed = card.transformed(by: CGAffineTransform(translationX: ((size.width - card.extent.width) / 2).rounded(),
                                                            y: ((size.height - card.extent.height) / 2).rounded()))
        return placed.composited(over: background)
    }

    private func outputBuffer() -> CVPixelBuffer? {
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(CameraIDs.width),
                kCVPixelBufferHeightKey as String: Int(CameraIDs.height),
                // Frames reach the extension as IOSurfaces.
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixels)
        return pixels
    }
}
