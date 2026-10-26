import Foundation
import Testing
@testable import TypeMeIt

/// Every setting, as text, keyed by property name, so a whole Settings can be
/// compared at once.
@MainActor
private func snapshot(_ settings: Settings) -> [String: String] {
    [
        "microphoneUID": String(describing: settings.microphoneUID),
        "microphoneName": String(describing: settings.microphoneName),
        "muteWhileRecording": String(describing: settings.muteWhileRecording),
        "pauseWhileRecording": String(describing: settings.pauseWhileRecording),
        "audioFeedback": String(describing: settings.audioFeedback),
        "postProcessingEnabled": String(describing: settings.postProcessingEnabled),
        "customWords": String(describing: settings.customWords),
        "writingStyles": String(describing: settings.writingStyles.map(\.rawValue).sorted()),
        "learnFromCorrections": String(describing: settings.learnFromCorrections),
        "historyLimit": String(describing: settings.historyLimit),
        "keepRecordings": String(describing: settings.keepRecordings),
        "autoUpdate": String(describing: settings.autoUpdate),
        "askBeforeUpdating": String(describing: settings.askBeforeUpdating),
        "launchAtLogin": String(describing: settings.launchAtLogin),
        "appearance": String(describing: settings.appearance),
        "cloudColorEnabled": String(describing: settings.cloudColorEnabled),
        "cloudColor": String(describing: settings.cloudColor),
        "lastBackdrop": String(describing: settings.lastBackdrop),
        "cloudPosition": String(describing: settings.cloudPosition),
        "screenContextEnabled": String(describing: settings.screenContextEnabled),
        "onboardingComplete": String(describing: settings.onboardingComplete),
        "speechModelVersion": String(describing: settings.speechModelVersion),
        "copyLastShortcut": String(describing: settings.copyLastShortcut),
        "undoneWords": String(describing: settings.undoneWords),
        "meetingAsk": String(describing: settings.meetingAsk),
        "meetingPreRoll": String(describing: settings.meetingPreRoll),
        "mcpEnabled": String(describing: settings.mcpEnabled),
        "mcpOffTools": String(describing: settings.mcpOffTools),
        "meetingKeepAudio": String(describing: settings.meetingKeepAudio),
        "meetingLearnVoices": String(describing: settings.meetingLearnVoices),
        "meetingAskBeforeTranscribing": String(describing: settings.meetingAskBeforeTranscribing),
        "meetingLimit": String(describing: settings.meetingLimit),
        "askClaude": String(describing: settings.askClaude),
        "meetingHooks": String(describing: settings.meetingHooks),
        "askClaudeSystemPrompt": String(describing: settings.askClaudeSystemPrompt),
        "askClaudePermissionMode": String(describing: settings.askClaudePermissionMode),
        "askClaudeFolder": String(describing: settings.askClaudeFolder),
        "askClaudeModel": String(describing: settings.askClaudeModel),
        "askClaudeTools": String(describing: settings.askClaudeTools),
        "recordRoomShortcut": String(describing: settings.recordRoomShortcut),
        "debugLogs": String(describing: settings.debugLogs),
    ]
}

/// A UserDefaults suite of its own for one test, removed when it is done.
@MainActor
private func withThrowawayDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
    let suiteName = "SettingsTests-\(UUID().uuidString)"
    let throwaway = UserDefaults(suiteName: suiteName)!
    defer { throwaway.removePersistentDomain(forName: suiteName) }
    try body(throwaway, suiteName)
}

/// Sets every setting away from its default. `debugLogs` is written as false:
/// on, it would write a header to the real debug log.
@MainActor
private func changeEverySetting(_ settings: Settings) {
    settings.microphoneUID = "BuiltInMicrophoneDevice"
    settings.microphoneName = "Desk Mic"
    settings.muteWhileRecording = false
    settings.pauseWhileRecording = true
    settings.audioFeedback.toggle()
    settings.postProcessingEnabled.toggle()
    settings.customWords = ["Zanzibar", "Quokka"]
    settings.writingStyles = [.digits, .lists]
    settings.learnFromCorrections.toggle()
    settings.historyLimit = 250
    settings.keepRecordings.toggle()
    settings.autoUpdate.toggle()
    settings.askBeforeUpdating.toggle()
    settings.launchAtLogin.toggle()
    settings.appearance = .dark
    settings.cloudColorEnabled.toggle()
    settings.cloudColor = .lavender
    settings.lastBackdrop = .dark
    settings.cloudPosition = .top
    settings.screenContextEnabled.toggle()
    settings.onboardingComplete.toggle()
    settings.speechModelVersion = "v9"
    settings.copyLastShortcut = KeyCombo(keyCode: 8, modifiers: [.command, .shift], keyLabel: "C")
    settings.undoneWords = ["teh"]
    settings.meetingAsk.toggle()
    settings.meetingPreRoll.toggle()
    settings.mcpEnabled.toggle()
    settings.mcpOffTools = ["search_meetings"]
    settings.meetingKeepAudio.toggle()
    settings.meetingLearnVoices.toggle()
    settings.meetingAskBeforeTranscribing.toggle()
    settings.meetingLimit = 40
    settings.askClaude.toggle()
    settings.meetingHooks = [MeetingHook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "summary", prompt: "Summarise it.", on: false)]
    settings.askClaudeSystemPrompt = "Answer briefly."
    settings.askClaudePermissionMode = "plan"
    settings.askClaudeFolder = "/tmp/project"
    settings.askClaudeModel = "opus"
    settings.askClaudeTools = ["Read", "Grep"]
    settings.recordRoomShortcut = KeyCombo(keyCode: 15, modifiers: [.option], keyLabel: "R")
    settings.debugLogs = false
}

@MainActor
struct SettingsTests {
    @Test func anEmptyDomainGivesEveryDefault() {
        withThrowawayDefaults { throwaway, _ in
            #expect(snapshot(Settings(defaults: throwaway)) == [
                "microphoneUID": "nil",
                "microphoneName": "nil",
                "muteWhileRecording": "true",
                "pauseWhileRecording": "false",
                "audioFeedback": "true",
                "postProcessingEnabled": "true",
                "customWords": "[]",
                "writingStyles": "[]",
                "learnFromCorrections": "true",
                "historyLimit": "0",
                "keepRecordings": String(describing: Updates.isDevBuild),
                "autoUpdate": "true",
                "askBeforeUpdating": "true",
                "launchAtLogin": "true",
                "appearance": "system",
                "cloudColorEnabled": "false",
                "cloudColor": "coral",
                "lastBackdrop": "nil",
                "cloudPosition": "centre",
                "screenContextEnabled": "false",
                "onboardingComplete": "false",
                "speechModelVersion": "nil",
                "copyLastShortcut": "nil",
                "undoneWords": "[]",
                "meetingAsk": "true",
                "meetingPreRoll": "true",
                "mcpEnabled": "false",
                "mcpOffTools": "[]",
                "meetingKeepAudio": "true",
                "meetingLearnVoices": "false",
                "meetingAskBeforeTranscribing": "false",
                "meetingLimit": "0",
                "askClaude": String(describing: Updates.isDevBuild),
                "meetingHooks": "[]",
                "askClaudeSystemPrompt": "",
                "askClaudePermissionMode": "auto",
                "askClaudeFolder": FileManager.default.homeDirectoryForCurrentUser.path,
                "askClaudeModel": "default",
                "askClaudeTools": "[]",
                "recordRoomShortcut": "nil",
                "debugLogs": "false",
            ])
        }
    }

    @Test func everySettingSurvivesARelaunch() {
        withThrowawayDefaults { throwaway, _ in
            let written = Settings(defaults: throwaway)
            let untouched = snapshot(written)
            changeEverySetting(written)
            let reread = snapshot(Settings(defaults: throwaway))
            #expect(reread == snapshot(written))
            let unchanged = reread.filter { untouched[$0.key] == $0.value }.map(\.key)
            #expect(unchanged == ["debugLogs"])
        }
    }

    /// The stored key names: renaming one resets that setting for everyone.
    @Test func everySettingIsStoredUnderItsKey() {
        withThrowawayDefaults { throwaway, suiteName in
            changeEverySetting(Settings(defaults: throwaway))
            let storedKeys = Set(throwaway.persistentDomain(forName: suiteName)?.keys ?? [:].keys)
            #expect(storedKeys == [
                "microphoneUID", "microphoneName", "muteWhileRecording", "pauseWhileRecording", "audioFeedback",
                "postProcessingEnabled", "customWords", "writingStyles", "learnFromCorrections",
                "historyLimit", "keepRecordings", "autoUpdate", "askBeforeUpdating", "launchAtLogin",
                "appearance", "cloudColorEnabled", "cloudColor", "lastBackdrop", "cloudPosition",
                "screenContextEnabled", "onboardingComplete", "speechModelVersion", "copyLastShortcut",
                "undoneWords", "meetingAsk", "meetingPreRoll", "meetingsMCP", "mcpOffTools",
                "meetingKeepAudio", "meetingLearnVoices", "meetingAskBeforeTranscribing", "meetingLimit",
                "askClaude", "meetingHooks", "askClaudeSystemPrompt", "askClaudePermissionMode",
                "askClaudeFolder", "askClaudeModel", "askClaudeTools", "recordRoomShortcut", "debugLogs",
            ])
        }
    }

    /// The values as stored, which a rename of a case or a change of encoding
    /// would also lose. Shortcuts and hooks are JSON, compared decoded.
    @Test func everySettingIsStoredInItsFormat() throws {
        try withThrowawayDefaults { throwaway, suiteName in
            changeEverySetting(Settings(defaults: throwaway))
            var stored = throwaway.persistentDomain(forName: suiteName) ?? [:]
            let copyLast = try JSONDecoder().decode(KeyCombo.self, from: try #require(stored.removeValue(forKey: "copyLastShortcut") as? Data))
            let recordRoom = try JSONDecoder().decode(KeyCombo.self, from: try #require(stored.removeValue(forKey: "recordRoomShortcut") as? Data))
            let hooks = try JSONDecoder().decode([MeetingHook].self, from: try #require(stored.removeValue(forKey: "meetingHooks") as? Data))
            #expect(copyLast == KeyCombo(keyCode: 8, modifiers: [.command, .shift], keyLabel: "C"))
            #expect(recordRoom == KeyCombo(keyCode: 15, modifiers: [.option], keyLabel: "R"))
            #expect(hooks == [MeetingHook(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "summary", prompt: "Summarise it.", on: false)])
            let expected: [String: Any] = [
                "microphoneUID": "BuiltInMicrophoneDevice",
                "microphoneName": "Desk Mic",
                "muteWhileRecording": false,
                "pauseWhileRecording": true,
                "audioFeedback": false,
                "postProcessingEnabled": false,
                "customWords": ["Zanzibar", "Quokka"],
                "writingStyles": ["digits", "lists"],
                "learnFromCorrections": false,
                "historyLimit": 250,
                "keepRecordings": !Updates.isDevBuild,
                "autoUpdate": false,
                "askBeforeUpdating": false,
                "launchAtLogin": false,
                "appearance": "dark",
                "cloudColorEnabled": true,
                "cloudColor": "lavender",
                "lastBackdrop": "dark",
                "cloudPosition": "top",
                "screenContextEnabled": true,
                "onboardingComplete": true,
                "speechModelVersion": "v9",
                "undoneWords": ["teh"],
                "meetingAsk": false,
                "meetingPreRoll": false,
                "meetingsMCP": true,
                "mcpOffTools": ["search_meetings"],
                "meetingKeepAudio": false,
                "meetingLearnVoices": true,
                "meetingAskBeforeTranscribing": true,
                "meetingLimit": 40,
                "askClaude": !Updates.isDevBuild,
                "askClaudeSystemPrompt": "Answer briefly.",
                "askClaudePermissionMode": "plan",
                "askClaudeFolder": "/tmp/project",
                "askClaudeModel": "opus",
                "askClaudeTools": ["Read", "Grep"],
                "debugLogs": false,
            ]
            #expect(NSDictionary(dictionary: stored) == NSDictionary(dictionary: expected))
        }
    }
}
