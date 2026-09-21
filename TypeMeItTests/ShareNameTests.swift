import Foundation
import Testing
@testable import TypeMeIt

struct ShareNameTests {
    @Test func aNameIsTakenAsItIs() {
        #expect(Sharing.clean("Lottie's MacBook") == "Lottie's MacBook")
    }

    @Test func nothingUsableFallsBackToSomethingToShow() {
        #expect(Sharing.clean(nil) == "another mac")
        #expect(Sharing.clean("   ") == "another mac")
    }

    @Test func lineBreaksCannotBeUsedToFakeAWindow() {
        #expect(Sharing.clean("a mac\naccept: yes") == "a mac accept: yes")
    }

    @Test func aLongNameIsCutSoTheWindowStillFits() {
        let cleaned = Sharing.clean(String(repeating: "m", count: 80))
        #expect(cleaned.count == 41)
        #expect(cleaned.hasSuffix("…"))
    }

    @Test func mdnsPlumbingIsNotShownToAPerson() {
        #expect(Sharing.withoutLocal("Maximilians-MacBook-Pro.local") == "Maximilians-MacBook-Pro")
        #expect(Sharing.withoutLocal("lottie") == "lottie")
    }
}
