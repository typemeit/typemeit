import Foundation
import Testing
@testable import TypeMeIt

@MainActor
struct ToastCountdownTests {
    private let step = ToastTiming.countdownStep

    @Test func stepsWhileItStopsCountingDoNotCount() async {
        var steps = 0
        var checks = 0
        let ranOut = await ToastTiming.countDown(step * 3, deadline: nil, counting: {
            checks += 1
            return checks != 2
        }, sleep: { _ in steps += 1 })
        #expect(ranOut)
        #expect(steps == 4)
    }

    @Test func theDeadlineEndsACountThatNeverRuns() async {
        var steps = 0
        let ranOut = await ToastTiming.countDown(step * 80, deadline: step * 5, counting: { false }, sleep: { _ in steps += 1 })
        #expect(ranOut)
        #expect(steps == 5)
    }

    @Test func aCancelledCountDoesNotRunOut() async {
        var steps = 0
        let ranOut = await ToastTiming.countDown(step * 3, deadline: nil, counting: { true }, sleep: { _ in
            steps += 1
            withUnsafeCurrentTask { $0?.cancel() }
        })
        #expect(!ranOut)
        #expect(steps == 1)
    }

    @Test func aCountWhoseOwnerIsGoneDoesNotRunOut() async {
        var steps = 0
        let ranOut = await ToastTiming.countDown(step * 3, deadline: nil, counting: { steps < 2 ? true : nil }, sleep: { _ in steps += 1 })
        #expect(!ranOut)
        #expect(steps == 2)
    }
}
