import CryptoKit
import Foundation
import Testing
@testable import TypeMeIt

struct ShareHandshakeTests {
    private let notes = SharePayload(notes: [
        SharedNote(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_000), text: "the first one"),
        SharedNote(id: UUID(), timestamp: Date(timeIntervalSince1970: 1_700_000_060), text: "and the second"),
    ])

    /// Both ends of one exchange, having been given the same pairing code.
    private func pair(code: String = "ABCD2345") throws -> (ShareHandshake.Agreement, ShareHandshake.Agreement) {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        return (try ShareHandshake.agree(ours: a, theirs: b.publicKey.rawRepresentation, pairing: code),
                try ShareHandshake.agree(ours: b, theirs: a.publicKey.rawRepresentation, pairing: code))
    }

    @Test func bothEndsReachTheSameKey() throws {
        let (mine, theirs) = try pair()
        let sealed = try ShareHandshake.seal(notes, with: mine.key)
        #expect(try ShareHandshake.open(sealed, with: theirs.key) == notes)
    }

    @Test func bothEndsShowTheSameDigits() throws {
        let (mine, theirs) = try pair()
        #expect(mine.code == theirs.code)
    }

    @Test func theDigitsAreFourOfThem() throws {
        // Every run is a fresh pair, so this also says the leading zeros a
        // small number needs are there rather than trimmed.
        for _ in 0..<50 {
            let (mine, _) = try pair()
            #expect(mine.code.count == 4)
            #expect(mine.code.allSatisfy(\.isNumber))
        }
    }

    @Test func aThirdPartyInTheMiddleShowsDifferentDigits() throws {
        // What a listener that answered first would produce: the two ends
        // agree with the attacker, not with each other, so the digits on the
        // two screens do not match and the user sees it.
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let middle = Curve25519.KeyAgreement.PrivateKey()
        let toA = try ShareHandshake.agree(ours: a, theirs: middle.publicKey.rawRepresentation, pairing: "ABCD2345")
        let toB = try ShareHandshake.agree(ours: b, theirs: middle.publicKey.rawRepresentation, pairing: "ABCD2345")
        #expect(toA.code != toB.code)
    }

    @Test func aKeyFromAnotherExchangeDoesNotOpenTheNotes() throws {
        let (mine, _) = try pair()
        let (other, _) = try pair()
        let sealed = try ShareHandshake.seal(notes, with: mine.key)
        #expect(throws: ShareHandshake.Failure.cannotOpen) { try ShareHandshake.open(sealed, with: other.key) }
    }

    @Test func aTamperedPayloadDoesNotOpen() throws {
        let (mine, theirs) = try pair()
        var sealed = try ShareHandshake.seal(notes, with: mine.key)
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: ShareHandshake.Failure.cannotOpen) { try ShareHandshake.open(sealed, with: theirs.key) }
    }

    @Test func somethingThatIsNotAPublicKeyIsRefused() {
        let ours = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: ShareHandshake.Failure.badKey) {
            try ShareHandshake.agree(ours: ours, theirs: Data([1, 2, 3]), pairing: "ABCD2345")
        }
    }

    @Test func theSameKeysUnderAnotherCodeAgreeOnSomethingElse() throws {
        // What the introducing server would be left with: it relayed the
        // public keys, so it has those, but it only ever saw a hash of the
        // code and cannot reach either end's key without it.
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let right = try ShareHandshake.agree(ours: a, theirs: b.publicKey.rawRepresentation, pairing: "ABCD2345")
        let wrong = try ShareHandshake.agree(ours: a, theirs: b.publicKey.rawRepresentation, pairing: "ABCD2346")
        #expect(right.code != wrong.code)
        let sealed = try ShareHandshake.seal(notes, with: right.key)
        #expect(throws: ShareHandshake.Failure.cannotOpen) { try ShareHandshake.open(sealed, with: wrong.key) }
    }

    @Test func theTranscriptIsTheSameWhicheverEndBuildsIt() {
        let a = Data([1, 2, 3])
        let b = Data([9, 9])
        #expect(ShareHandshake.transcript(a, b) == ShareHandshake.transcript(b, a))
        #expect(ShareHandshake.transcript(a, b) == a + b)
    }

    @Test func fourZeroBytesAreFourZeroDigits() {
        #expect(ShareHandshake.code(from: SymmetricKey(data: Data([0, 0, 0, 0]))) == "0000")
    }

    @Test func theDigitsAreTheLastFourOfTheNumberTheBytesMake() {
        // 0x00 00 30 39 is 12345, which shows as 2345.
        #expect(ShareHandshake.code(from: SymmetricKey(data: Data([0x00, 0x00, 0x30, 0x39]))) == "2345")
    }
}

struct ShareNameTests {
    @Test func aNameIsTakenAsItIs() {
        #expect(IncomingShare.clean("Lottie's MacBook") == "Lottie's MacBook")
    }

    @Test func nothingUsableFallsBackToSomethingToShow() {
        #expect(IncomingShare.clean(nil) == "another mac")
        #expect(IncomingShare.clean("   ") == "another mac")
    }

    @Test func lineBreaksCannotBeUsedToFakeAPrompt() {
        #expect(IncomingShare.clean("a mac\naccept: yes") == "a mac accept: yes")
    }

    @Test func mdnsPlumbingIsNotShownToAPerson() {
        #expect(Sharing.withoutLocal("Maximilians-MacBook-Pro.local") == "Maximilians-MacBook-Pro")
        #expect(Sharing.withoutLocal("lottie") == "lottie")
    }

    @Test func aLongNameIsCutSoThePromptStillFits() {
        let name = String(repeating: "m", count: 80)
        let cleaned = IncomingShare.clean(name)
        #expect(cleaned.count == 41)
        #expect(cleaned.hasSuffix("…"))
    }
}
