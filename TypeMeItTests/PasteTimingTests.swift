import Testing
@testable import TypeMeIt

struct PasteTimingTests {
    @Test func restoreFollowsTheReadByTheQuietPeriod() {
        let plan = PasteTiming.plan(posted: true, readAfterMs: 130)
        #expect(plan == PasteTiming.Plan(restoreAfterMs: 130 + Fixed.pasteQuietMs, submitAfterMs: 130 + Fixed.autoSubmitDelayMs))
    }

    @Test func returnGoesOutBeforeTheRestore() {
        let plan = PasteTiming.plan(posted: true, readAfterMs: 0)
        #expect(plan.submitAfterMs! < plan.restoreAfterMs)
    }

    @Test func unreadClipboardWaitsForTheCapAndNeverSubmits() {
        #expect(PasteTiming.plan(posted: true, readAfterMs: nil) == PasteTiming.Plan(restoreAfterMs: Fixed.pasteUnreadCapMs, submitAfterMs: nil))
    }

    @Test func readBeforeTheChordFallsBackToTheTimer() {
        #expect(PasteTiming.plan(posted: true, readAfterMs: -40) == PasteTiming.Plan(restoreAfterMs: Fixed.pasteReadEarlyMs, submitAfterMs: Fixed.pasteReadEarlyMs))
    }

    @Test func unpostedChordRestoresSoonAndNeverSubmits() {
        #expect(PasteTiming.plan(posted: false, readAfterMs: nil) == PasteTiming.Plan(restoreAfterMs: Fixed.pasteNotPostedMs, submitAfterMs: nil))
        #expect(PasteTiming.plan(posted: false, readAfterMs: 10) == PasteTiming.Plan(restoreAfterMs: Fixed.pasteNotPostedMs, submitAfterMs: nil))
    }

    @Test func constantsKeepTheirOrder() {
        #expect(Fixed.autoSubmitDelayMs < Fixed.pasteQuietMs)
        #expect(Fixed.pasteQuietMs < Fixed.pasteReadEarlyMs)
        #expect(Fixed.pasteReadEarlyMs < Fixed.pasteUnreadCapMs)
    }
}
