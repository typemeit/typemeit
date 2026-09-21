import Foundation
import Testing
@testable import TypeMeIt

struct ShareWireTests {
    private let hello = ShareFrame(kind: .hello, key: Data([1, 2, 3]), name: "a mac")

    @Test func aFrameSurvivesTheRoundTrip() throws {
        var buffer = try ShareWire.encode(hello)
        #expect(try ShareWire.decode(from: &buffer) == hello)
        #expect(buffer.isEmpty)
    }

    @Test func theLengthPrefixIsFourBytesBigEndian() throws {
        let encoded = try ShareWire.encode(ShareFrame(kind: .offer, count: 2))
        let length = encoded.prefix(4).reduce(Int(0)) { ($0 << 8) | Int($1) }
        #expect(length == encoded.count - 4)
        #expect(encoded.prefix(2) == Data([0, 0]))
    }

    @Test func halfAFrameIsLeftInTheBufferUntilTheRestArrives() throws {
        let whole = try ShareWire.encode(hello)
        var buffer = whole.prefix(whole.count - 3)
        #expect(try ShareWire.decode(from: &buffer) == nil)
        #expect(buffer.count == whole.count - 3)
        buffer.append(whole.suffix(3))
        #expect(try ShareWire.decode(from: &buffer) == hello)
    }

    @Test func fewerThanFourBytesIsNotYetALength() throws {
        var buffer = Data([0, 0])
        #expect(try ShareWire.decode(from: &buffer) == nil)
        #expect(buffer.count == 2)
    }

    @Test func twoFramesInOneReadComeOutInOrder() throws {
        let offer = ShareFrame(kind: .offer, count: 3)
        var buffer = try ShareWire.encode(hello) + ShareWire.encode(offer)
        #expect(try ShareWire.decode(from: &buffer) == hello)
        #expect(try ShareWire.decode(from: &buffer) == offer)
        #expect(try ShareWire.decode(from: &buffer) == nil)
    }

    @Test func aLengthBeyondTheLimitIsRefusedBeforeAnythingIsHeld() {
        var buffer = Data([0x7F, 0xFF, 0xFF, 0xFF])
        #expect(throws: ShareWire.Failure.tooLarge(0x7FFFFFFF)) { try ShareWire.decode(from: &buffer) }
    }

    @Test func rubbishInsideAWellFormedLengthIsMalformed() {
        let body = Data("not a frame".utf8)
        var buffer = Data([0, 0, 0, UInt8(body.count)]) + body
        #expect(throws: ShareWire.Failure.malformed) { try ShareWire.decode(from: &buffer) }
    }

    @Test func aFieldTheFrameDoesNotUseIsNil() throws {
        var buffer = try ShareWire.encode(ShareFrame(kind: .decision, accepted: false))
        let frame = try ShareWire.decode(from: &buffer)
        #expect(frame?.accepted == false)
        #expect(frame?.key == nil)
        #expect(frame?.sealed == nil)
    }
}
