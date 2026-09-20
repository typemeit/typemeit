import CoreAudio
import Foundation
import Testing
@testable import TypeMeIt

private func info(objectID: AudioObjectID = 1, pid: pid_t = 100, bundleID: String? = nil, path: String? = nil, input: Bool = false, output: Bool = true) -> AudioProcessInfo {
    AudioProcessInfo(objectID: objectID, pid: pid, bundleID: bundleID, path: path, input: input, output: output)
}

struct ProcessOwnerTests {
    @Test func chromeHelperResolvesToChrome() {
        let apps = [ProcessOwner.RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome", url: URL(fileURLWithPath: "/Applications/Google Chrome.app"))]
        let owner = ProcessOwner.owner(of: info(bundleID: "com.google.Chrome.helper"), apps: apps)
        #expect(owner == ProcessOwner.Owner(bundleID: "com.google.Chrome", name: "Google Chrome", appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app")))
    }

    @Test func slackHelperResolvesToSlack() {
        let apps = [ProcessOwner.RunningApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", url: URL(fileURLWithPath: "/Applications/Slack.app"))]
        let owner = ProcessOwner.owner(of: info(bundleID: "com.tinyspeck.slackmacgap.helper"), apps: apps)
        #expect(owner == ProcessOwner.Owner(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", appURL: URL(fileURLWithPath: "/Applications/Slack.app")))
    }

    @Test func aPlainAppResolvesToItself() {
        let apps = [ProcessOwner.RunningApp(bundleID: "com.example.Notes", name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"))]
        let owner = ProcessOwner.owner(of: info(bundleID: "com.example.Notes"), apps: apps)
        #expect(owner == ProcessOwner.Owner(bundleID: "com.example.Notes", name: "Notes", appURL: URL(fileURLWithPath: "/Applications/Notes.app")))
    }

    @Test func avconferencedWithNoRunningAppIsFaceTime() {
        let owner = ProcessOwner.owner(of: info(bundleID: "com.apple.avconferenced"), apps: [])
        #expect(owner == ProcessOwner.Owner(bundleID: "com.apple.avconferenced", name: "FaceTime", appURL: nil))
        #expect(owner?.appURL == nil)
    }

    @Test func webKitGPUIsWebContentAndCanNeverBeNeverAsked() {
        let owner = ProcessOwner.owner(of: info(bundleID: "com.apple.WebKit.GPU"), apps: [])
        #expect(owner == ProcessOwner.Owner(bundleID: "com.apple.WebKit.GPU", name: "web content", appURL: nil))
        #expect(owner?.canNeverAsk == false)
    }

    @Test func emptyBundleIDWithAPathResolvesToTheExecutableName() {
        let owner = ProcessOwner.owner(of: info(bundleID: nil, path: "/usr/bin/afplay"), apps: [])
        #expect(owner == ProcessOwner.Owner(bundleID: "/usr/bin/afplay", name: "afplay", appURL: nil))
    }

    @Test func aPathWithTwoDotAppsPicksTheOutermostWithNoRunningAppMatch() {
        let path = "/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner"
        let owner = ProcessOwner.owner(of: info(bundleID: nil, path: path), apps: [])
        #expect(owner == ProcessOwner.Owner(bundleID: "/Applications/Outer.app", name: "Outer", appURL: URL(fileURLWithPath: "/Applications/Outer.app")))
    }

    @Test func aPathWithTwoDotAppsPrefersTheRunningAppAtTheOutermostURL() {
        let path = "/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner"
        let apps = [ProcessOwner.RunningApp(bundleID: "com.example.Outer", name: "Outer App", url: URL(fileURLWithPath: "/Applications/Outer.app"))]
        let owner = ProcessOwner.owner(of: info(bundleID: nil, path: path), apps: apps)
        #expect(owner == ProcessOwner.Owner(bundleID: "com.example.Outer", name: "Outer App", appURL: URL(fileURLWithPath: "/Applications/Outer.app")))
    }

    @Test func isOursMatchesOurBundlePrefixOrOurPID() {
        #expect(ProcessOwner.isOurs(info(pid: 999, bundleID: "it.typeme.typemeit"), ourPID: 1))
        #expect(ProcessOwner.isOurs(info(pid: 999, bundleID: "it.typeme.typemeit.dev"), ourPID: 1))
        #expect(ProcessOwner.isOurs(info(pid: 42, bundleID: "com.example.Notes"), ourPID: 42))
    }

    @Test func isOursIsFalseForAnUnrelatedProcess() {
        #expect(!ProcessOwner.isOurs(info(pid: 999, bundleID: "com.example.Notes"), ourPID: 1))
    }

    @Test func isIgnoredMatchesTheAppleDaemonList() {
        #expect(ProcessOwner.isIgnored(info(bundleID: "com.apple.CoreSpeech")))
        #expect(!ProcessOwner.isIgnored(info(bundleID: "com.tinyspeck.slackmacgap")))
    }
}
