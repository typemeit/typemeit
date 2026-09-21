import Foundation
import Testing
@testable import TypeMeIt

struct ShareCodeTests {
    @Test func aCodeIsEightCharactersOfTheAlphabet() {
        for _ in 0..<100 {
            let code = ShareCode.make()
            #expect(code.count == ShareCode.length)
            #expect(code.allSatisfy { ShareCode.alphabet.contains($0) })
        }
    }

    @Test func theCharactersThatGetMisreadAreNotUsed() {
        // I against 1, L against 1, O against 0. A code is read off one
        // screen and typed into another, so none of them are in it.
        for bad in "ILO01" {
            #expect(!ShareCode.alphabet.contains(bad))
        }
    }

    @Test func twoCodesAreNotTheSame() {
        let codes = Set((0..<200).map { _ in ShareCode.make() })
        #expect(codes.count == 200)
    }

    @Test func aCodeIsTakenHoweverItIsTyped() {
        #expect(ShareCode.tidy("abcd2345") == "ABCD2345")
        #expect(ShareCode.tidy("ABCD-2345") == "ABCD2345")
        #expect(ShareCode.tidy("  abcd 2345 ") == "ABCD2345")
    }

    @Test func somethingThatIsNotACodeIsRefused() {
        #expect(ShareCode.tidy("ABCD234") == nil)
        #expect(ShareCode.tidy("ABCD23456") == nil)
        #expect(ShareCode.tidy("") == nil)
        // The excluded characters are not quietly read as something else.
        #expect(ShareCode.tidy("ABCD2I45") == nil)
        #expect(ShareCode.tidy("ABCD2O45") == nil)
    }

    @Test func aCodeIsShownInTwoHalves() {
        #expect(ShareCode.spaced("ABCD2345") == "ABCD-2345")
    }

    @Test func whatIsShownIsWhatCanBeTypedBack() {
        let code = ShareCode.make()
        #expect(ShareCode.tidy(ShareCode.spaced(code)) == code)
    }

    @Test func theRoomIsAHashAndNotTheCode() {
        let room = ShareCode.room(for: "ABCD2345")
        #expect(room.count == 64)
        #expect(room.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!room.contains("ABCD2345".lowercased()))
    }

    @Test func oneCodeAlwaysNamesTheSameRoom() {
        #expect(ShareCode.room(for: "ABCD2345") == ShareCode.room(for: "ABCD2345"))
        #expect(ShareCode.room(for: "ABCD2345") != ShareCode.room(for: "ABCD2346"))
    }
}
