import Foundation
import Testing
@testable import TypeMeIt

struct VoicePrintTests {
    private let print: [Float] = [1, 0, 0]

    @Test func theNearestSpeakerWithinTheLimitAndClearOfTheRunnerUpIsTheUser() {
        let speakers: [String: [Float]] = ["s1": [0.9, 0.1, 0], "s2": [0, 1, 0]]
        #expect(VoicePrint.match(speakers, print: print, distance: 0.4, margin: 0.1) == "s1")
    }

    @Test func nobodyWithinTheLimitIsNobody() {
        let speakers: [String: [Float]] = ["s1": [0.3, 1, 0], "s2": [0, 1, 0]]
        #expect(VoicePrint.match(speakers, print: print, distance: 0.4, margin: 0.1) == nil)
    }

    @Test func twoSpeakersTooCloseToCallIsNobody() {
        let speakers: [String: [Float]] = ["s1": [1, 0.1, 0], "s2": [1, 0, 0.12]]
        #expect(VoicePrint.match(speakers, print: print, distance: 0.4, margin: 0.1) == nil)
    }

    @Test func aLoneSpeakerNeedsOnlyTheLimit() {
        #expect(VoicePrint.match(["s1": [1, 0.2, 0]], print: print, distance: 0.4, margin: 0.1) == "s1")
    }

    @Test func distanceIgnoresLength() {
        #expect(VoicePrint.distance([2, 0], [5, 0]) == 0)
        #expect(VoicePrint.distance([1, 0], [0, 3]) == 1)
    }

    @Test func foldingAveragesDirectionsNotLengths() throws {
        let date = Date(timeIntervalSince1970: 0)
        var p = VoicePrint.folding([10, 0], into: nil, at: date)
        p = VoicePrint.folding([0, 1], into: p, at: date)
        #expect(p.count == 2)
        #expect(p.centroid == [1, 1])
    }

    @Test func anEmbeddingOfAnotherLengthStartsAgain() {
        let date = Date(timeIntervalSince1970: 0)
        let p = VoicePrint.folding([0, 1, 0], into: VoicePrint.Print(centroid: [1, 0], count: 7, updated: date), at: date)
        #expect(p == VoicePrint.Print(centroid: [0, 1, 0], count: 1, updated: date))
    }
}
