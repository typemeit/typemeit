import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import TypeMeIt

struct CameraCompositorTests {
    @Test func aFaceInTheMiddleOfTheCameraIsInTheMiddleOfTheFrame() {
        let face = CameraCompositor.faceInFrame(CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), cameraSize: CGSize(width: 1920, height: 1440))
        #expect(abs(face.midX - 0.5) < 0.001 && abs(face.midY - 0.5) < 0.001)
    }

    @Test func aTallerCameraLosesItsTopAndBottomToTheFrame() {
        // 1920 by 1440 fills 1280 by 720 at two thirds, 960 high: 120 cut from the top and the bottom.
        let face = CameraCompositor.faceInFrame(CGRect(x: 0.45, y: 0.75, width: 0.1, height: 0.2), cameraSize: CGSize(width: 1920, height: 1440))
        #expect(abs(face.minY - (0.75 * 960 - 120) / 720) < 0.001)
        #expect(abs(face.height - 0.2 * 960 / 720) < 0.001)
        #expect(abs(face.minX - 0.45) < 0.001)
    }

    @Test func theCloudSitsOnTheForehead() {
        let face = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2)
        let place = CameraCompositor.cloudPlace(face: face)
        #expect(place.centre.x == face.midX)
        // Near the top of the face's box, where the forehead is.
        #expect(abs(place.centre.y - face.maxY) < face.height / 4)
        #expect(place.puff < face.height)
    }

    @Test func aCameraOfAnotherShapeFillsTheFrame() {
        let square = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1080, height: 1080))
        #expect(CameraCompositor.filling(square).extent == CGRect(origin: .zero, size: CameraCompositor.size))
    }

    @Test func anAnswerCoversTheMiddleOfTheFrame() async throws {
        let compositor = CameraCompositor()
        let card = try #require(CIContext().createCGImage(CIImage(color: .blue).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200)),
                                                          from: CGRect(x: 0, y: 0, width: 400, height: 200)))
        compositor.setCard(card)
        compositor.show(.answer)
        try await Task.sleep(for: .seconds(CameraCompositor.fadeSeconds + 0.1))
        let camera = try #require(pixels(white: true))
        let frame = try #require(compositor.render(camera))
        #expect(CVPixelBufferGetWidth(frame) == Int(CameraIDs.width))
        #expect(CVPixelBufferGetHeight(frame) == Int(CameraIDs.height))
        let middle = pixel(frame, x: Int(CameraIDs.width) / 2, y: Int(CameraIDs.height) / 2)
        let corner = pixel(frame, x: 10, y: 10)
        #expect(middle.blue > 200 && middle.red < 50)
        // The camera behind is dimmed, not hidden.
        #expect(corner.red > 80 && corner.red < 200)
    }

    private func pixels(white: Bool) -> CVPixelBuffer? {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixels)
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), white ? 255 : 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return pixels
    }

    private func pixel(_ pixels: CVPixelBuffer, x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(pixels)!.advanced(by: y * CVPixelBufferGetBytesPerRow(pixels))
        let bgra = row.advanced(by: x * 4).assumingMemoryBound(to: UInt8.self)
        return (bgra[2], bgra[0])
    }
}
