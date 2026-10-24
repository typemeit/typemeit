import Testing
@testable import TypeMeIt

struct PluralTests {
    @Test func oneTakesTheSingular() {
        #expect(counted(1, "word") == "1 word")
    }

    @Test func otherCountsTakeThePlural() {
        #expect(counted(0, "word") == "0 words")
        #expect(counted(2, "dictation") == "2 dictations")
    }

    @Test func anIrregularPluralIsPassedIn() {
        #expect(counted(3, "clean-up", "clean-ups") == "3 clean-ups")
    }

    @Test func largeCountsAreGrouped() {
        #expect(counted(1200, "word") == "1,200 words")
    }
}
