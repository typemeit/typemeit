import CryptoKit
import Foundation
import Testing
@testable import TypeMeIt

struct ShareSealTests {
    private let payload = SharePayload(from: "a mac", notes: [
        SharedNote(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: "the first one"),
        SharedNote(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_060), text: "and the second"),
    ])

    @Test func theRightSecretGetsTheNotesBack() throws {
        let blob = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        #expect(try ShareSeal.open(blob, secret: "JKMNPQRSTV") == payload)
    }

    @Test func anotherSecretDoesNot() throws {
        let blob = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        #expect(throws: ShareSeal.Failure.cannotOpen) { try ShareSeal.open(blob, secret: "JKMNPQRSTW") }
    }

    @Test func aTamperedDropDoesNotOpen() throws {
        var blob = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        blob[blob.count - 1] ^= 0xFF
        #expect(throws: ShareSeal.Failure.cannotOpen) { try ShareSeal.open(blob, secret: "JKMNPQRSTV") }
    }

    @Test func somethingThatIsNotADropIsTurnedAwayBeforeAnyWork() {
        #expect(throws: ShareSeal.Failure.notOurs) {
            try ShareSeal.open(Data("hello there, this is not a drop".utf8), secret: "JKMNPQRSTV")
        }
        #expect(throws: ShareSeal.Failure.notOurs) {
            try ShareSeal.open(Data(), secret: "JKMNPQRSTV")
        }
    }

    @Test func aDropSaysWhatItIsAndCarriesItsSalt() throws {
        let blob = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        #expect(blob.prefix(4) == Data("tmi1".utf8))
        #expect(blob.count > ShareSeal.magic.count + ShareSeal.saltBytes)
    }

    @Test func thereIsAFreshSaltEveryTime() throws {
        // The same notes under the same secret must not seal to the same
        // bytes, or two drops would be visibly the same drop.
        let one = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        let two = try ShareSeal.seal(payload, secret: "JKMNPQRSTV")
        #expect(one != two)
        #expect(one.dropFirst(4).prefix(ShareSeal.saltBytes) != two.dropFirst(4).prefix(ShareSeal.saltBytes))
    }

    @Test func theSaltIsWhatMakesTheKeyDiffer() {
        let secret = "JKMNPQRSTV"
        let a = ShareSeal.key(secret: secret, salt: Data(repeating: 1, count: 16))
        let b = ShareSeal.key(secret: secret, salt: Data(repeating: 2, count: 16))
        #expect(a != nil)
        #expect(a != b)
    }

    @Test func theRoundsAreNotQuietlyLowered() {
        // The secret is fifty bits. What stands between a guess at it and the
        // notes is this number, so a change to it is a change worth noticing.
        #expect(ShareSeal.rounds == 600_000)
    }
}
