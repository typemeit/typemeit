import Foundation
import FoundationModels

/// A folder to suggest for a meeting in none, from Apple's on-device model:
/// one of the user's folders, or else a new folder's name. The user takes
/// it or leaves it; only the series rule (`Meeting.seriesFolder`) files a
/// meeting by itself. For the existing folder, each folder is graded on its
/// own: the model reads the folder's name and its newest meetings beside
/// the meeting's title and summary, and guided generation holds its answer
/// to a `Fit`. A folder is suggested only when exactly one `belongs`, so it
/// is always one of the user's. Asked instead to choose among all the
/// folders and "none" in one call, the model picks some folder for meetings
/// that fit none. Needs only MeetingSummary and Log from the app, so
/// Scripts/folder-eval compiles it as it ships.
enum MeetingFolderPick {
    /// A meeting already in a folder, as the model reads it. A meeting from
    /// before summaries, or one the model declined, has none.
    struct Member: Decodable, Equatable, Sendable {
        let title: String
        let summary: String?
    }

    /// A folder and its meetings, newest first.
    struct Folder: Decodable, Equatable, Sendable {
        let name: String
        let meetings: [Member]
    }

    /// How the new meeting fits one folder. `loose` takes the meetings that
    /// only share a person or a word with the folder's: with `belongs` and
    /// one other grade, the model calls those `belongs`.
    @Generable
    enum Fit: String, CaseIterable, Sendable {
        case belongs, loose, unrelated
    }

    /// The model's answer for one folder. Asked for a bare `Fit`, the model
    /// grades nearly every folder `loose`; as a field of an answer, it does
    /// not.
    @Generable
    struct Grade: Sendable {
        @Guide(description: "how well the new meeting fits the folder")
        let fit: Fit
    }

    /// What grading the folders found.
    enum Match: Equatable, Sendable {
        /// The one folder the meeting belongs in.
        case folder(String)
        /// No folder: the meeting may want a new one.
        case none
        /// More than one folder: it belongs with existing meetings, but
        /// which is unclear, so neither they nor a new folder are offered.
        case ambiguous
    }

    /// Why a new folder's name is not suggested.
    enum NameRejection: Error, Equatable, Sendable {
        /// The model gave no name: unavailable, declined or failed.
        case noAnswer
        case empty
        case tooLong(words: Int)
        /// The meeting's own title, which names the meeting and not what
        /// a folder of meetings like it holds.
        case meetingTitle
        /// It says no more or no less than these folders (`nearDuplicate`):
        /// "new folder: Acme" beside "Acme account" reads as a second folder
        /// for the same thing.
        case nearDuplicate(of: [String])
    }

    /// The meetings shown for a folder, newest first. Three show what a
    /// folder holds; with summaries cut to `summaryWords`, one folder and
    /// the new meeting come to about 250 words, well inside the
    /// 4,096-token window beside the instructions.
    static let meetingsPerFolder = 3
    /// A summary is cut to this many words. `MeetingSummary` asks for 40,
    /// and summaries from before its two-sentence cut ran longer.
    static let summaryWords = 50
    /// The folders graded, those with the newest meetings first. Each is a
    /// model call, so this bounds how long a pick takes.
    static let maxFolders = 12
    /// The most words a new folder's name may have.
    static let nameWords = 3

    /// A new folder's name, as the model writes it.
    @Generable
    struct FolderName: Sendable {
        @Guide(description: "one to \(MeetingFolderPick.nameWords) words naming the client, project, team, person or ongoing topic")
        let name: String
    }

    private static let instructions = "The user message is one of the user's folders, its name and the meetings already in it, then a new meeting. The name says what the folder holds. Say how well the new meeting fits the folder. \(Fit.belongs.rawValue): the user would keep it with these meetings, because it is about the same project, client, team, person, event or ongoing work. \(Fit.loose.rawValue): it only shares a person, a word or a general theme with them. \(Fit.unrelated.rawValue): anything else."

    /// Says a folder holds the meetings to come: asked only what the one
    /// meeting is about, the model gives back the meeting's title.
    private static let nameInstructions = "You name folders that keep meetings together. A folder holds many meetings over weeks or months. The user message is one meeting's title and summary. Answer with the name a person would give the folder this meeting goes in: the client, project, team, person or ongoing topic it shares with the meetings to come, not what this one meeting was about."

    /// What to suggest for a meeting in no folder: the one folder among
    /// `folders` it belongs in, or a new folder's name when it belongs in
    /// none (`newName`). Nil when it belongs in more than one, or the model
    /// has no name that passes `checkedName`.
    static func suggestion(title: String, summary: String, among folders: [Folder],
                           grade: (_ prompt: String) async -> Fit? = MeetingFolderPick.grade,
                           nameFolder: (_ prompt: String) async -> String? = MeetingFolderPick.nameFolder) async -> String? {
        switch await pick(title: title, summary: summary, among: folders, grade: grade) {
        case .folder(let name): name
        case .ambiguous: nil
        case .none: try? await newName(title: title, summary: summary, among: folders.map(\.name), nameFolder: nameFolder).get()
        }
    }

    /// The folder among `folders` the meeting belongs in: `.none` without
    /// asking when there are none, and grading stops at the second that
    /// belongs. `grade` is the model, given one folder's prompt; no answer
    /// counts as no fit.
    static func pick(title: String, summary: String, among folders: [Folder],
                     grade: (_ prompt: String) async -> Fit? = MeetingFolderPick.grade) async -> Match {
        let summary = cut(summary)
        var belonging: [String] = []
        for folder in trimmed(folders) {
            guard belonging.count < 2 else { break }
            if await grade(prompt(folder, title: title, summary: summary)) == .belongs { belonging.append(folder.name) }
        }
        switch belonging.count {
        case 0: return .none
        case 1: return .folder(belonging[0])
        default: return .ambiguous
        }
    }

    /// A name for a new folder to keep the meeting in, from its title and
    /// summary, through `checkedName`. `nameFolder` is the model, given the
    /// prompt.
    static func newName(title: String, summary: String, among folders: [String],
                        nameFolder: (_ prompt: String) async -> String? = MeetingFolderPick.nameFolder) async -> Result<String, NameRejection> {
        guard let raw = await nameFolder("Title: \(title)\nSummary: \(cut(summary))") else { return .failure(.noAnswer) }
        return checkedName(raw, title: title, among: folders)
    }

    /// `raw` as a folder name: trimmed of spaces and punctuation at its
    /// ends, underscores read as spaces (the model can write
    /// `data_team_lead`), its words one space apart, and spelled as the
    /// folder it names (`existing`). Pure.
    static func checkedName(_ raw: String, title: String, among folders: [String]) -> Result<String, NameRejection> {
        let words = raw.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).split(whereSeparator: \.isWhitespace)
        let name = words.joined(separator: " ")
        if words.isEmpty { return .failure(.empty) }
        if words.count > nameWords { return .failure(.tooLong(words: words.count)) }
        if name.caseInsensitiveCompare(title.split(whereSeparator: \.isWhitespace).joined(separator: " ")) == .orderedSame { return .failure(.meetingTitle) }
        if let folder = existing(name, among: folders) { return .success(folder) }
        let close = folders.filter { nearDuplicate(name, of: $0) }
        return close.isEmpty ? .success(name) : .failure(.nearDuplicate(of: close))
    }

    /// The folder among `folders` that `name` names, ignoring case, in the
    /// folder's own spelling. A typed name and the model's both go through
    /// it, so neither makes a second folder that differs only in case. Pure.
    static func existing(_ name: String, among folders: [String]) -> String? {
        folders.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Whether `name` says no more or no less than `folder`: one's words
    /// hold all of the other's, as "Acme" and "Acme account" do, ignoring
    /// case, punctuation and a plural "s". Pure.
    static func nearDuplicate(_ name: String, of folder: String) -> Bool {
        func stems(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map { word in
                word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : String(word)
            })
        }
        let a = stems(name), b = stems(folder)
        return !a.isEmpty && !b.isEmpty && (a.isSubset(of: b) || b.isSubset(of: a))
    }

    /// The folders as they are graded: the first `maxFolders`, each with
    /// its `meetingsPerFolder` newest meetings and their summaries cut to
    /// `summaryWords`. Pure.
    static func trimmed(_ folders: [Folder]) -> [Folder] {
        folders.prefix(maxFolders).map { folder in
            Folder(name: folder.name, meetings: folder.meetings.prefix(meetingsPerFolder).map { Member(title: $0.title, summary: $0.summary.map(cut)) })
        }
    }

    /// The first `summaryWords` words of `summary`. Pure.
    static func cut(_ summary: String) -> String {
        summary.split(whereSeparator: \.isWhitespace).prefix(summaryWords).joined(separator: " ")
    }

    /// The user message for one folder: its name and a line per meeting in
    /// it, then the new meeting. Pure.
    static func prompt(_ folder: Folder, title: String, summary: String) -> String {
        let meetings = folder.meetings.map { member in member.summary.map { "- \(member.title): \($0)" } ?? "- \(member.title)" }
        return (["Folder name: \(folder.name)", "Meetings in it:"] + meetings).joined(separator: "\n")
            + "\n\nNew meeting:\nTitle: \(title)\nSummary: \(summary)"
    }

    /// The model's `Fit` for one folder's prompt. Nil when Apple
    /// Intelligence is unavailable or the model declines.
    static func grade(_ prompt: String) async -> Fit? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            return try await MeetingSummary.guided(Grade.self, instructions, to: prompt).fit
        } catch {
            Log.meetings.notice("No folder grade: \(error.localizedDescription)")
            return nil
        }
    }

    /// The model's name for a new folder, from a meeting's prompt. Nil when
    /// Apple Intelligence is unavailable or the model declines.
    static func nameFolder(_ prompt: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            return try await MeetingSummary.guided(FolderName.self, nameInstructions, to: prompt).name
        } catch {
            Log.meetings.notice("No folder name: \(error.localizedDescription)")
            return nil
        }
    }
}
