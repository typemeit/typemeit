import Foundation
import Testing
@testable import TypeMeIt

struct MeetingFolderPickTests {
    private typealias Pick = MeetingFolderPick

    private let title = "Offer Decision"
    private let summary = "You and Leah agreed to make the designer an offer."

    private func folder(_ name: String) -> Pick.Folder {
        Pick.Folder(name: name, meetings: [Pick.Member(title: "\(name) catch-up", summary: "You and Leah went over \(name).")])
    }

    @Test func noFoldersIsNoneWithoutAskingTheModel() async {
        var grades = 0
        let match = await Pick.pick(title: title, summary: summary, among: []) { _ in
            grades += 1
            return .belongs
        }
        #expect(match == .none)
        #expect(grades == 0)
    }

    @Test func noGradeIsNoFit() async {
        let match = await Pick.pick(title: title, summary: summary, among: [folder("hiring")]) { _ in nil }
        #expect(match == .none)
    }

    @Test func theOneFolderThatBelongsIsPicked() async {
        let folders = [folder("hiring"), folder("onboarding"), folder("board")]
        let match = await Pick.pick(title: title, summary: summary, among: folders) { prompt in
            prompt == Pick.prompt(folders[1], title: title, summary: summary) ? .belongs : .loose
        }
        #expect(match == .folder("onboarding"))
    }

    @Test func twoFoldersThatBelongAreAmbiguousAndStopTheGrading() async {
        var grades = 0
        let match = await Pick.pick(title: title, summary: summary, among: [folder("hiring"), folder("onboarding"), folder("board")]) { _ in
            grades += 1
            return .belongs
        }
        #expect(match == .ambiguous)
        #expect(grades == 2)
    }

    @Test func onlyTheFirstFoldersAreGraded() async {
        let folders = (1...(Pick.maxFolders + 3)).map { folder("folder \($0)") }
        var grades = 0
        _ = await Pick.pick(title: title, summary: summary, among: folders) { _ in
            grades += 1
            return .loose
        }
        #expect(grades == Pick.maxFolders)
        #expect(Pick.trimmed(folders) == Array(folders.prefix(Pick.maxFolders)))
    }

    @Test func eachFolderShowsItsNewestMeetingsWithSummariesCut() {
        let words = (1...(Pick.summaryWords * 2)).map { "word\($0)" }
        let members = (1...(Pick.meetingsPerFolder + 2)).map { Pick.Member(title: "Meeting \($0)", summary: words.joined(separator: " ")) }
        let cut = words.prefix(Pick.summaryWords).joined(separator: " ")
        #expect(Pick.trimmed([Pick.Folder(name: "hiring", meetings: members)])
            == [Pick.Folder(name: "hiring", meetings: members.prefix(Pick.meetingsPerFolder).map { Pick.Member(title: $0.title, summary: cut) })])
    }

    @Test func theNewMeetingsSummaryIsCutToo() async {
        let words = (1...(Pick.summaryWords * 2)).map { "word\($0)" }
        let only = folder("hiring")
        var prompts: [String] = []
        _ = await Pick.pick(title: title, summary: words.joined(separator: " "), among: [only]) { prompt in
            prompts.append(prompt)
            return nil
        }
        #expect(prompts == [Pick.prompt(only, title: title, summary: words.prefix(Pick.summaryWords).joined(separator: " "))])
    }

    @Test func aMeetingWithoutASummaryIsListedByItsTitle() {
        let hiring = Pick.Folder(name: "hiring", meetings: [Pick.Member(title: "Debrief", summary: "You and Leah met."), Pick.Member(title: "Loop Planning", summary: nil)])
        #expect(Pick.prompt(hiring, title: "Offer", summary: "You made an offer.")
            == "Folder name: hiring\nMeetings in it:\n- Debrief: You and Leah met.\n- Loop Planning\n\nNew meeting:\nTitle: Offer\nSummary: You made an offer.")
    }

    @Test func aNameIsTrimmedAndSpacedLikeAFolderName() {
        #expect(Pick.checkedName("  \u{201C}Bluebird   Bakery.\u{201D} ", title: title, among: []) == .success("Bluebird Bakery"))
        #expect(Pick.checkedName("data_team_lead", title: title, among: []) == .success("data team lead"))
    }

    @Test func anEmptyNameIsRejected() {
        #expect(Pick.checkedName(" . ", title: title, among: []) == .failure(.empty))
    }

    @Test func aNameOverTheWordLimitIsRejected() {
        let words = (0...Pick.nameWords).map { "word\($0)" }
        #expect(Pick.checkedName(words.joined(separator: " "), title: title, among: []) == .failure(.tooLong(words: words.count)))
        #expect(Pick.checkedName(words.dropLast().joined(separator: " "), title: title, among: []) == .success(words.dropLast().joined(separator: " ")))
    }

    @Test func theMeetingsOwnTitleIsRejected() {
        #expect(Pick.checkedName("offer  decision", title: title, among: []) == .failure(.meetingTitle))
    }

    @Test func aNameMatchingAFolderIgnoringCaseIsThatFolder() {
        #expect(Pick.existing("acme ACCOUNT", among: ["hiring", "Acme account"]) == "Acme account")
        #expect(Pick.existing("Globex", among: ["hiring", "Acme account"]) == nil)
        #expect(Pick.checkedName("acme ACCOUNT", title: title, among: ["hiring", "Acme account"]) == .success("Acme account"))
    }

    @Test func aNearDuplicateOfAFolderIsRejected() {
        #expect(Pick.checkedName("Acme", title: title, among: ["Acme account", "hiring"]) == .failure(.nearDuplicate(of: ["Acme account"])))
        #expect(Pick.checkedName("Podcasts", title: title, among: ["podcast"]) == .failure(.nearDuplicate(of: ["podcast"])))
        #expect(Pick.checkedName("Acme account renewal", title: title, among: ["Acme account"]) == .failure(.nearDuplicate(of: ["Acme account"])))
    }

    @Test func aNewNameIsKept() {
        #expect(Pick.checkedName("Globex", title: title, among: ["Acme account", "hiring"]) == .success("Globex"))
    }

    @Test func noNameFromTheModelIsNoAnswer() async {
        let named = await Pick.newName(title: title, summary: summary, among: []) { _ in nil }
        #expect(named == .failure(.noAnswer))
    }

    @Test func aFolderThatBelongsIsSuggestedWithoutAName() async {
        var named = 0
        let suggested = await Pick.suggestion(title: title, summary: summary, among: [folder("hiring")],
                                              grade: { _ in .belongs },
                                              nameFolder: { _ in
                                                  named += 1
                                                  return "Globex"
                                              })
        #expect(suggested == "hiring")
        #expect(named == 0)
    }

    @Test func anAmbiguousPickSuggestsNothing() async {
        var named = 0
        let suggested = await Pick.suggestion(title: title, summary: summary, among: [folder("hiring"), folder("onboarding")],
                                              grade: { _ in .belongs },
                                              nameFolder: { _ in
                                                  named += 1
                                                  return "Globex"
                                              })
        #expect(suggested == nil)
        #expect(named == 0)
    }

    @Test func withNoFoldersANewNameIsSuggestedFromTheTitleAndSummary() async {
        var prompts: [String] = []
        var grades = 0
        let suggested = await Pick.suggestion(title: title, summary: summary, among: [],
                                              grade: { _ in
                                                  grades += 1
                                                  return nil
                                              },
                                              nameFolder: { prompt in
                                                  prompts.append(prompt)
                                                  return "Design Hiring"
                                              })
        #expect(suggested == "Design Hiring")
        #expect(grades == 0)
        #expect(prompts == ["Title: \(title)\nSummary: \(summary)"])
    }

    @Test func whenNoFolderFitsTheNameIsSuggested() async {
        let suggested = await Pick.suggestion(title: title, summary: summary, among: [folder("board")],
                                              grade: { _ in .loose }, nameFolder: { _ in "Globex" })
        #expect(suggested == "Globex")
    }

    @Test func aRejectedNameSuggestsNothing() async {
        let suggested = await Pick.suggestion(title: title, summary: summary, among: [folder("board")],
                                              grade: { _ in .loose }, nameFolder: { _ in "Board Meetings" })
        #expect(suggested == nil)
    }

    @Test func foldersAreListedByTheirNewestMeetingWithoutTheMeetingItself() {
        let new = MeetingFixtures.meeting("Offer", folder: "hiring")
        let earlier = [MeetingFixtures.meeting("Lunch", hoursAgo: 12), MeetingFixtures.meeting("Board Prep", hoursAgo: 24, summary: "About board prep.", folder: "board"),
                       MeetingFixtures.meeting("Debrief", hoursAgo: 48, summary: "About the debrief.", folder: "hiring"),
                       MeetingFixtures.meeting("Loop", hoursAgo: 72, folder: "hiring")]
        #expect(new.folderChoices(["board", "hiring"], among: [new] + earlier) == [
            Pick.Folder(name: "board", meetings: [Pick.Member(title: "Board Prep", summary: "About board prep.")]),
            Pick.Folder(name: "hiring", meetings: [Pick.Member(title: "Debrief", summary: "About the debrief."), Pick.Member(title: "Loop", summary: nil)]),
        ])
    }

    @Test func aFolderHoldingOnlyTheMeetingItselfIsLeftOut() {
        let new = MeetingFixtures.meeting("Offer", folder: "offers")
        #expect(new.folderChoices(["offers"], among: [new]) == [])
    }
}
