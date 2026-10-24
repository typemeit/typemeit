import CoreAudio
import Foundation
import Testing
@testable import TypeMeIt

private func info(objectID: AudioObjectID, bundleID: String?, input: Bool, output: Bool) -> AudioProcessInfo {
    AudioProcessInfo(objectID: objectID, pid: pid_t(objectID) + 1000, bundleID: bundleID, path: nil, input: input, output: output)
}

@MainActor
struct MeetingWatchTests {
    private static let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    private static let slackURL = URL(fileURLWithPath: "/Applications/Slack.app")
    private static let apps = [
        ProcessOwner.RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome", url: chromeURL),
        ProcessOwner.RunningApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", url: slackURL),
    ]

    private static let infos: [AudioProcessInfo] = [
        info(objectID: 10, bundleID: "com.google.Chrome.helper", input: true, output: false),
        info(objectID: 20, bundleID: "com.google.Chrome.helper", input: false, output: true),
        info(objectID: 30, bundleID: "it.typeme.typemeit.dev", input: false, output: true),
        info(objectID: 40, bundleID: "com.apple.CoreSpeech", input: true, output: true),
        info(objectID: 50, bundleID: "com.example.Idle", input: false, output: false),
        info(objectID: 60, bundleID: "com.tinyspeck.slackmacgap.helper", input: false, output: true),
    ]

    @Test func twoChromeHelpersFoldIntoOneHolderWithBothFlags() {
        let holders = MeetingWatch.group(Self.infos, apps: Self.apps)
        let chrome = holders.first { $0.owner.bundleID == "com.google.Chrome" }
        #expect(chrome?.objectIDs == [10, 20])
        #expect(chrome?.input == true)
        #expect(chrome?.output == true)
    }

    @Test func ourOwnIgnoredAndFlaglessProcessesAreExcluded() {
        let holders = MeetingWatch.group(Self.infos, apps: Self.apps)
        #expect(!holders.contains { $0.owner.bundleID == "it.typeme.typemeit.dev" })
        #expect(!holders.contains { $0.owner.bundleID == "com.apple.CoreSpeech" })
        #expect(!holders.contains { $0.owner.bundleID == "com.example.Idle" })
    }

    @Test func onlyTheTwoRealOwnersRemainSortedByBundleID() {
        let holders = MeetingWatch.group(Self.infos, apps: Self.apps)
        #expect(holders.map(\.owner.bundleID) == ["com.google.Chrome", "com.tinyspeck.slackmacgap"])
    }

    @Test func groupingIsStableAcrossRepeatedCalls() {
        let first = MeetingWatch.group(Self.infos, apps: Self.apps)
        let second = MeetingWatch.group(Self.infos, apps: Self.apps)
        #expect(first == second)
    }

    @Test func matchesTheExactExpectedHolders() {
        let holders = MeetingWatch.group(Self.infos, apps: Self.apps)
        let expected = [
            MeetingWatch.Holder(
                owner: ProcessOwner.Owner(bundleID: "com.google.Chrome", name: "Google Chrome", appURL: Self.chromeURL),
                objectIDs: [10, 20], input: true, output: true),
            MeetingWatch.Holder(
                owner: ProcessOwner.Owner(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", appURL: Self.slackURL),
                objectIDs: [60], input: false, output: true),
        ]
        #expect(holders == expected)
    }
}
