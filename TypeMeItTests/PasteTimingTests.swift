import Testing
@testable import TypeMeIt

struct PasteTimingTests {
    @Test func restoreFollowsTheReadByTheQuietPeriod() {
        #expect(PasteTiming.restoreAfterMs(posted: true, readAfterMs: 130) == 130 + Fixed.pasteQuietMs)
    }

    @Test func unreadClipboardWaitsForTheCap() {
        #expect(PasteTiming.restoreAfterMs(posted: true, readAfterMs: nil) == Fixed.pasteUnreadCapMs)
    }

    @Test func readBeforeTheChordFallsBackToTheTimer() {
        #expect(PasteTiming.restoreAfterMs(posted: true, readAfterMs: -40) == Fixed.pasteReadEarlyMs)
    }

    @Test func unpostedChordRestoresSoon() {
        #expect(PasteTiming.restoreAfterMs(posted: false, readAfterMs: nil) == Fixed.pasteNotPostedMs)
        #expect(PasteTiming.restoreAfterMs(posted: false, readAfterMs: 10) == Fixed.pasteNotPostedMs)
    }

    @Test func constantsKeepTheirOrder() {
        #expect(Fixed.pasteQuietMs < Fixed.pasteReadEarlyMs)
        #expect(Fixed.pasteReadEarlyMs < Fixed.pasteUnreadCapMs)
    }
}
