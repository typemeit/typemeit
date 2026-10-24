import Testing
@testable import TypeMeIt

struct TimesFasterTests {
    @Test func aMeetingReadsInWholeTimes() {
        #expect(timesFaster(audioMs: 3_699_000, tookMs: 268_656) == "14× faster")
    }

    @Test func aSlowerRunKeepsOneDecimal() {
        #expect(timesFaster(audioMs: 5_000, tookMs: 2_000) == "2.5× faster")
    }

    @Test func aFastRunRoundsToTwoFigures() {
        #expect(timesFaster(audioMs: 64_200, tookMs: 400) == "160× faster")
    }

    @Test func slowerThanRealtimeStaysAFraction() {
        #expect(timesFaster(audioMs: 1_000, tookMs: 4_000) == "0.25× faster")
    }

    @Test func noTimeIsInstant() {
        #expect(timesFaster(audioMs: 1_000, tookMs: 0) == "instant")
    }
}
