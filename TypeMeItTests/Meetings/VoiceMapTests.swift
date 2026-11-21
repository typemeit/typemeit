import Foundation
import Testing
@testable import TypeMeIt

struct VoiceMapTests {
    /// Clips scattered around one direction per person.
    private func voices(_ name: String, around axis: Int, count: Int, seed: Int) -> [VoiceMap.Example] {
        (0..<count).map { i in
            var vector = (0..<16).map { Float(($0 * 31 + i * 17 + seed * 7) % 13) / 100 }
            vector[axis] += 1
            return VoiceMap.Example(name: name, vector: vector)
        }
    }

    @Test func twoDistinctVoicesSitApart() throws {
        let map = try #require(VoiceMap.make(voices("Ana", around: 0, count: 30, seed: 1) + voices("Hugh", around: 5, count: 20, seed: 2)))
        #expect(map.people.map(\.name) == ["Ana", "Hugh"])
        #expect(map.people.map(\.clips) == [30, 20])
        #expect(map.people.map(\.apart) == [1, 1])
        #expect(map.people.map(\.nearest) == [[], []])
        // Every Ana dot is nearer Ana's middle than Hugh's.
        let (ana, hugh) = (map.people[0], map.people[1])
        for dot in map.dots where dot.person == 0 {
            #expect(hypot(dot.x - ana.x, dot.y - ana.y) < hypot(dot.x - hugh.x, dot.y - hugh.y))
        }
    }

    @Test func oneNameIsCaseInsensitiveAndKeepsItsFirstSpelling() throws {
        let map = try #require(VoiceMap.make(voices("Ana", around: 0, count: 10, seed: 1) + voices("ana", around: 0, count: 10, seed: 3)
            + voices("Hugh", around: 5, count: 10, seed: 2)))
        #expect(map.people.map(\.name) == ["Ana", "Hugh"])
    }

    @Test func oneVoiceIsNoMap() {
        #expect(VoiceMap.make(voices("Ana", around: 0, count: 10, seed: 1)) == nil)
    }

    @Test func clipsAreThinnedToTheCap() throws {
        let map = try #require(VoiceMap.make(voices("Ana", around: 0, count: Fixed.voiceMapClipsPerPerson * 2, seed: 1)
            + voices("Hugh", around: 5, count: 10, seed: 2)))
        #expect(map.people[0].clips == Fixed.voiceMapClipsPerPerson * 2)
        #expect(map.dots.filter { $0.person == 0 }.count == Fixed.voiceMapClipsPerPerson)
    }

    @Test func aVoiceLikeAnothersListsThemNearest() throws {
        // Hugh's and Edie's clips share one direction; Ana's are apart.
        let map = try #require(VoiceMap.make(voices("Ana", around: 0, count: 20, seed: 1)
            + voices("Hugh", around: 5, count: 20, seed: 2) + voices("Edie", around: 5, count: 20, seed: 3)))
        let hugh = try #require(map.people.firstIndex { $0.name == "Hugh" })
        let edie = try #require(map.people.firstIndex { $0.name == "Edie" })
        #expect(map.people[hugh].nearest.map(\.person) == [edie])
        #expect(map.people[hugh].apart < 1)
    }
}
