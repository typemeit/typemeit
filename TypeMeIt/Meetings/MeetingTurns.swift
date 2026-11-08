import Foundation

/// Apart from Meeting.swift, which the MCP tool compiles without
/// MeetingSummary, MeetingFolderPick or MeetingFingerprint.
extension Meeting {
    /// Who spoke when, from the paragraphs' times and speakers alone. Nil
    /// for a meeting with no length.
    var fingerprint: MeetingFingerprint? {
        MeetingFingerprint(
            durationMs: durationMs,
            voices: speakers.map {
                MeetingFingerprint.Voice(id: $0.id, isYou: $0.isYou, talkMs: $0.talkMs, name: Speaker.isPlaceholder($0.name) ? nil : $0.name)
            },
            turns: paragraphs.map { MeetingFingerprint.Turn(speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, aside: $0.aside == true) })
    }

    /// The paragraphs under their speakers' names, as the summary reads them.
    var turns: [MeetingSummary.Turn] {
        paragraphs.map { MeetingSummary.Turn(speaker: speakerName($0.speaker), text: $0.text) }
    }

    /// `folders` as `MeetingFolderPick` reads them, with the meetings among
    /// `meetings` in each apart from this one: each folder's meetings newest
    /// first, the folder with the newest meeting first. A folder holding
    /// only this meeting is left out.
    func folderChoices(_ folders: [String], among meetings: [Meeting]) -> [MeetingFolderPick.Folder] {
        let filed = meetings.filter { $0.id != id && $0.folder != nil }.sorted { $0.started > $1.started }
        return folders
            .compactMap { name -> (newest: Date, folder: MeetingFolderPick.Folder)? in
                let members = filed.filter { $0.folder == name }
                guard let newest = members.first?.started else { return nil }
                return (newest, MeetingFolderPick.Folder(name: name, meetings: members.map { MeetingFolderPick.Member(title: $0.title, summary: $0.summary) }))
            }
            .sorted { $0.newest > $1.newest }
            .map(\.folder)
    }
}
