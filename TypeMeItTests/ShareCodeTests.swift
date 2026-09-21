import Foundation
import Testing
@testable import TypeMeIt

struct ShareCodeTests {
    @Test func aCodeIsEighteenCharactersOfTheAlphabet() {
        for _ in 0..<100 {
            let pickup = ShareCode.make()
            #expect(pickup.name.count == ShareCode.nameLength)
            #expect(pickup.secret.count == ShareCode.secretLength)
            #expect(pickup.code.allSatisfy { ShareCode.alphabet.contains($0) })
        }
    }

    @Test func theCharactersThatGetMisreadAreNotUsed() {
        // I against 1, L against 1, O against 0. A code gets read off one
        // screen and typed into another, so none of them are in it.
        for bad in "ILO01" {
            #expect(!ShareCode.alphabet.contains(bad))
        }
    }

    @Test func theTwoHalvesAreDrawnSeparately() {
        // The whole point of the split: the server is told the name, so if
        // the secret followed from it the server could work it out. A run of
        // codes sharing a name would have to share a secret for that to be
        // true of these.
        let pickups = (0..<200).map { _ in ShareCode.make() }
        #expect(Set(pickups.map(\.name)).count == 200)
        #expect(Set(pickups.map(\.secret)).count == 200)
    }

    @Test func aCodeIsTakenHoweverItIsTyped() {
        let pickup = ShareCode.tidy("abcd2345-jkmn-pqrs-tv")
        #expect(pickup?.name == "ABCD2345")
        #expect(pickup?.secret == "JKMNPQRSTV")
    }

    @Test func spacesAndCaseAreForgiven() {
        #expect(ShareCode.tidy("  abcd 2345 jkmn pqrs tv ")?.code == "ABCD2345JKMNPQRSTV")
    }

    @Test func somethingThatIsNotACodeIsRefused() {
        #expect(ShareCode.tidy("ABCD2345JKMNPQRST") == nil)
        #expect(ShareCode.tidy("ABCD2345JKMNPQRSTVW") == nil)
        #expect(ShareCode.tidy("") == nil)
        // The excluded characters are not quietly read as something else.
        #expect(ShareCode.tidy("ABCD2I45JKMNPQRSTV") == nil)
        #expect(ShareCode.tidy("ABCD2O45JKMNPQRSTV") == nil)
    }

    @Test func aCodeIsShownInFours() {
        #expect(ShareCode.spaced("ABCD2345JKMNPQRSTV") == "ABCD-2345-JKMN-PQRS-TV")
    }

    @Test func whatIsShownIsWhatCanBeTypedBack() {
        let pickup = ShareCode.make()
        #expect(ShareCode.tidy(ShareCode.spaced(pickup.code)) == pickup)
    }
}
