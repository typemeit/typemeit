import Foundation
import FoundationModels

/// Runs the made-up folders and meetings in cases.json through
/// MeetingFolderPick as it ships, `runs` times each.
///
/// The pick, for every case with folders, timing each grade the model gives
/// a folder: a run is right when it picks the folder the case expects, or
/// no folder when it expects null; missed when it expects a folder and gets
/// none; wrong when it picks another folder; filed when it expects none and
/// gets a folder. An ambiguous pick, more than one folder belonging, is no
/// folder and is counted besides. A case not right in every run prints its
/// first run's grades.
///
/// The new folder's name, for every run whose pick is `.none` and every
/// case without folders, with no expected names: each is printed beside the
/// meeting's title for a person to judge, or with the reason
/// `MeetingFolderPick.checkedName` rejected it. A name that matches a
/// folder becomes that folder, which must then be the one the case expects.
///
/// Any wrong or filed pick, or name of another folder, fails the eval. A
/// case whose picks or names differ between runs is listed as varied.
struct NewMeeting: Decodable {
    let title: String
    let summary: String
}

struct Case: Decodable {
    let name: String
    let folders: [MeetingFolderPick.Folder]
    let meeting: NewMeeting
    let expect: String?
}

enum Outcome: String, Encodable, CaseIterable {
    case right, missed, wrong, filed

    init(picked: String?, expected: String?) {
        switch (picked, expected) {
        case let (p, e) where p == e: self = .right
        case (nil, _): self = .missed
        case (_, nil): self = .filed
        default: self = .wrong
        }
    }
}

/// One run's new folder name: what the model wrote and what the app made
/// of it.
struct NameRun: Encodable {
    let raw: String?
    let kept: String?
    let rejected: String?
}

struct CaseResult: Encodable {
    let name: String
    let title: String
    let expect: String?
    let picks: [String?]
    let ambiguous: Int
    let outcomes: [Outcome]
    let names: [NameRun]
}

@main
struct Eval {
    /// Each case's runs. The model samples greedily, so runs that disagree
    /// show answers that hang on something other than the prompt.
    static let runs = 3

    static func describe(_ rejection: MeetingFolderPick.NameRejection) -> String {
        switch rejection {
        case .noAnswer: "no answer"
        case .empty: "empty"
        case .tooLong(let words): "\(words) words"
        case .meetingTitle: "the meeting's title"
        case .nearDuplicate(let folders): "near-duplicate of \(folders.joined(separator: ", "))"
        }
    }

    static func named(_ c: Case) async -> NameRun {
        var raw: String?
        let result = await MeetingFolderPick.newName(title: c.meeting.title, summary: c.meeting.summary, among: c.folders.map(\.name)) { prompt in
            raw = await MeetingFolderPick.nameFolder(prompt)
            return raw
        }
        switch result {
        case .success(let kept): return NameRun(raw: raw, kept: kept, rejected: nil)
        case .failure(let rejection): return NameRun(raw: raw, kept: nil, rejected: describe(rejection))
        }
    }

    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("cases.json")))
        guard case .available = SystemLanguageModel.default.availability else { print("Apple Intelligence is not available on this Mac"); exit(2) }
        var results: [CaseResult] = []
        var pickMs: [Double] = []
        var gradeMs: [Double] = []
        print("folder pick\n")
        for c in cases {
            var picks: [String?] = []
            var ambiguous = 0
            var firstGrades: [String] = []
            var names: [NameRun] = []
            for run in 0..<runs {
                var match = MeetingFolderPick.Match.none
                if !c.folders.isEmpty {
                    var grades: [String] = []
                    let began = ContinuousClock.now
                    match = await MeetingFolderPick.pick(title: c.meeting.title, summary: c.meeting.summary, among: c.folders) { prompt in
                        let gradeBegan = ContinuousClock.now
                        let fit = await MeetingFolderPick.grade(prompt)
                        gradeMs.append((ContinuousClock.now - gradeBegan) / .milliseconds(1))
                        grades.append(fit?.rawValue ?? "nil")
                        return fit
                    }
                    pickMs.append((ContinuousClock.now - began) / .milliseconds(1))
                    if run == 0 { firstGrades = grades }
                    switch match {
                    case .folder(let name): picks.append(name)
                    case .none: picks.append(nil)
                    case .ambiguous:
                        picks.append(nil)
                        ambiguous += 1
                    }
                }
                if match == .none { names.append(await named(c)) }
            }
            let outcomes = picks.map { Outcome(picked: $0, expected: c.expect) }
            if !c.folders.isEmpty {
                let marks = Set(outcomes)
                let mark = marks.count == 1 ? outcomes[0].rawValue.uppercased() : "VARIED"
                let shown = Set(picks.map { $0 ?? "none" }).count == 1 ? (picks[0] ?? "none") : picks.map { $0 ?? "none" }.joined(separator: " | ")
                print("\(mark.padding(toLength: 7, withPad: " ", startingAt: 0)) \(c.name)\n        picked: \(shown)\(ambiguous > 0 ? " (ambiguous)" : "")   expected: \(c.expect ?? "none")")
                if marks != [.right] {
                    let graded = zip(MeetingFolderPick.trimmed(c.folders).map(\.name), firstGrades).map { "\($0)=\($1)" }
                    print("        grades: \(graded.joined(separator: ", "))")
                }
            }
            results.append(CaseResult(name: c.name, title: c.meeting.title, expect: c.expect, picks: picks, ambiguous: ambiguous, outcomes: outcomes, names: names))
        }

        print("\nnew folder names (title → name)\n")
        var otherFolder = 0
        for r in results where !r.names.isEmpty {
            let folders = Set(cases.first { $0.name == r.name }?.folders.map(\.name) ?? [])
            let wrong = r.names.compactMap(\.kept).filter { folders.contains($0) && $0 != r.expect }
            otherFolder += wrong.count
            let shown = r.names.map { $0.kept ?? "rejected: \($0.raw ?? "none") (\($0.rejected ?? ""))" }
            print("\(wrong.isEmpty ? "  " : "✗ ")\(r.title) → \(Set(shown).count == 1 ? shown[0] : shown.joined(separator: " | "))   [\(r.name)]")
            if let folder = wrong.first { print("      names the folder \(folder)") }
        }

        let withFolders = results.filter { !$0.picks.isEmpty }
        let all = withFolders.flatMap(\.outcomes)
        let total = { (o: Outcome) in all.filter { $0 == o }.count }
        let allNames = results.flatMap(\.names)
        let rejected = Dictionary(grouping: allNames.compactMap(\.rejected), by: { $0 }).mapValues(\.count)
        let ambiguousCases = withFolders.filter { $0.ambiguous > 0 }
        print("\npick: \(withFolders.count) cases × \(runs) runs = \(all.count) picks")
        print("right \(total(.right))   missed \(total(.missed))   wrong folder \(total(.wrong))   filed when none was expected \(total(.filed))")
        print("ambiguous \(withFolders.reduce(0) { $0 + $1.ambiguous }) picks in \(counted(ambiguousCases.count, "case")), no folder and no name: \(ambiguousCases.map(\.name).joined(separator: ", "))")
        print("names: \(allNames.count) asked, \(allNames.filter { $0.kept != nil }.count) kept, \(otherFolder) named another folder; rejected \(rejected.isEmpty ? "none" : rejected.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))")
        let variedPicks = withFolders.filter { Set($0.picks.map { $0 ?? "" }).count > 1 }
        let variedNames = results.filter { Set($0.names.map { $0.kept ?? "-" + ($0.raw ?? "") }).count > 1 }
        print(variedPicks.isEmpty ? "no pick varied between runs" : "picks varied: \(variedPicks.map(\.name).joined(separator: ", "))")
        print(variedNames.isEmpty ? "no name varied between runs" : "names varied: \(variedNames.map(\.name).joined(separator: ", "))")
        if !pickMs.isEmpty, !gradeMs.isEmpty {
            print("median pick \(Int(pickMs.sorted()[pickMs.count / 2])) ms, slowest \(Int(pickMs.max() ?? 0)) ms; \(gradeMs.count) grades, mean \(Int(gradeMs.reduce(0, +) / Double(gradeMs.count))) ms each")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(results).write(to: dir.appendingPathComponent("result.json"))
        exit(total(.wrong) + total(.filed) + otherFolder == 0 ? 0 : 1)
    }

    /// "1 case", "2 cases": the app's `counted` is not compiled in here.
    static func counted(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
