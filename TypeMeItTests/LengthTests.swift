import Testing
@testable import TypeMeIt

struct LengthTests {
    @Test func underAMinuteIsSeconds() {
        #expect(lengthInSeconds(ms: 4_400) == "4s")
        #expect(lengthInSeconds(ms: 0) == "0s")
    }

    @Test func secondsRoundToTheNearest() {
        #expect(lengthInSeconds(ms: 4_500) == "5s")
    }

    @Test func pastAMinuteIsMinutesAndTwoDigitSeconds() {
        #expect(lengthInSeconds(ms: 65_000) == "1m 05s")
        #expect(lengthInSeconds(ms: 664_000) == "11m 04s")
    }

    /// 59.6 seconds rounds up to the minute and reads as one.
    @Test func roundingUpToAMinuteReadsAsAMinute() {
        #expect(lengthInSeconds(ms: 59_600) == "1m 00s")
    }
}
