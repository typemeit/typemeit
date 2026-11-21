import Foundation
import XCTest
@testable import TypeMeIt

/// The word check's pure parts: what a run sends, which of Claude's answers
/// are kept, how they group, and the fix applied to a dictation.
final class WordCheckTests: XCTestCase {
    private func entry(_ text: String) -> HistoryEntry {
        HistoryEntry(timestamp: Date(), transcript: text, postProcessRequested: false, typed: text, dictionaryFixes: 0)
    }

    func testABatchStopsBeforeTheWordsRunOut() {
        let entries = [entry("one two three"), entry("four five"), entry("six")]
        XCTAssertEqual(WordCheck.batch(entries, words: 5).map(\.id), entries.prefix(2).map(\.id))
    }

    func testABatchAlwaysTakesTheFirstDictation() {
        let entries = [entry("one two three"), entry("four")]
        XCTAssertEqual(WordCheck.batch(entries, words: 1).map(\.id), [entries[0].id])
    }

    func testTheInputNumbersEachDictationFromOne() {
        let input = WordCheck.input([entry("push it to get hub"), entry("ask the\nteam")], dictionary: ["Sentry"],
                                    dismissed: [WordCheck.Pair(heard: "jason", meant: "JSON")])
        XCTAssertEqual(input, """
            The user's dictionary, spelled as they want:
            Sentry

            Changes the user already turned down; don't suggest them:
            jason → JSON

            Dictations:
            [1] push it to get hub
            [2] ask the team

            """)
    }

    func testSuggestionsKeepOnlyWordsTheDictationHolds() throws {
        let batch = [entry("push it to get hub"), entry("ship the widget")]
        let answer = """
            {"suggestions":[
              {"dictation":1,"heard":"get hub","meant":"GitHub","why":"a brand","term":true},
              {"dictation":2,"heard":"get hub","meant":"GitHub","why":"not in it","term":true},
              {"dictation":3,"heard":"ship","meant":"Ship","why":"no such dictation","term":false},
              {"dictation":2,"heard":"widget","meant":"widget","why":"no change","term":false},
              {"dictation":2,"heard":"wid","meant":"with","why":"part of a word","term":false}
            ]}
            """
        let found = try XCTUnwrap(WordCheck.suggestions(from: answer, batch: batch))
        XCTAssertEqual(found.map(\.dictation), [batch[0].id])
        XCTAssertEqual(found.map(\.meant), ["GitHub"])
        XCTAssertEqual(found.map(\.term), [true])
    }

    func testAChangeIsCutToTheWordsThatDiffer() {
        let trailing = WordCheck.narrowed(heard: "cooper netties cluster", meant: "Kubernetes Cluster")
        XCTAssertEqual(trailing?.heard, "cooper netties")
        XCTAssertEqual(trailing?.meant, "Kubernetes")
        let leading = WordCheck.narrowed(heard: "we run cooper netties", meant: "we run Kubernetes")
        XCTAssertEqual(leading?.heard, "cooper netties")
        XCTAssertEqual(leading?.meant, "Kubernetes")
    }

    func testAChangeThatOnlyShiftsCaseInSharedWordsIsKept() {
        let narrowed = WordCheck.narrowed(heard: "get hub", meant: "GitHub")
        XCTAssertEqual(narrowed?.heard, "get hub")
        XCTAssertEqual(narrowed?.meant, "GitHub")
    }

    func testAChangeWithNothingDifferentIsNil() {
        XCTAssertNil(WordCheck.narrowed(heard: "widget", meant: "widget"))
    }

    func testAnAnswerThatIsNotTheSchemaIsNil() {
        XCTAssertNil(WordCheck.suggestions(from: "I found nothing.", batch: [entry("hi")]))
    }

    func testGroupsJoinTheSameChangeAcrossDictations() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let suggestions = [
            WordCheck.Suggestion(dictation: a, heard: "get hub", meant: "GitHub", why: "a brand", term: true),
            WordCheck.Suggestion(dictation: b, heard: "Get hub", meant: "GitHub", why: "again", term: false),
            WordCheck.Suggestion(dictation: c, heard: "get hub", meant: "GitHub", why: "fixed since", term: true),
        ]
        let groups = WordCheck.groups(suggestions, texts: [a: "push to get hub", b: "Get hub is down", c: "push to GitHub"])
        XCTAssertEqual(groups, [WordCheck.Group(meant: "GitHub", why: "a brand", term: true,
                                                changes: [WordCheck.Change(dictation: a, heard: "get hub"), WordCheck.Change(dictation: b, heard: "Get hub")])])
    }

    func testGroupsJoinEverySpellingOfOneWordCutToWhatDiffers() {
        let (a, b) = (UUID(), UUID())
        let suggestions = [
            WordCheck.Suggestion(dictation: a, heard: "cooper netties cluster", meant: "Kubernetes cluster", why: "a product", term: true),
            WordCheck.Suggestion(dictation: b, heard: "cube nets", meant: "kubernetes", why: "a product", term: true),
        ]
        let groups = WordCheck.groups(suggestions, texts: [a: "scale the cooper netties cluster", b: "deploy it on cube nets"])
        XCTAssertEqual(groups.map(\.heard), [["cooper netties", "cube nets"]])
        XCTAssertEqual(groups.map(\.meant), ["Kubernetes"])
    }

    func testAClipCentresOnWhereTheWordsFallInTheText() {
        XCTAssertEqual(WordCheck.clip(of: "hub", in: "0123456789 hub", seconds: 14), 9...14)
        XCTAssertEqual(WordCheck.clip(of: "hub", in: "hub", seconds: 1), 0...1)
        XCTAssertNil(WordCheck.clip(of: "hub", in: "nothing", seconds: 1))
    }

    func testAFixReplacesEveryWholeWordOnly() {
        XCTAssertEqual(WordCheck.replacing("get hub", with: "GitHub", in: "get hub, then get hubs and get hub."),
                       "GitHub, then get hubs and GitHub.")
    }

    func testAFixLeavesTemplateCharactersAlone() {
        XCTAssertEqual(WordCheck.replacing("dollar one", with: "$1", in: "costs dollar one"), "costs $1")
    }

    func testAFixOnTextWithoutTheWordIsNil() {
        XCTAssertNil(WordCheck.replacing("get hub", with: "GitHub", in: "push to GitHub"))
    }

    func testTheExcerptCutsAroundTheWord() throws {
        let text = "a long opening that goes on past the cut, then get hub, and a long ending that goes on past it"
        let parts = try XCTUnwrap(WordCheck.excerpt(of: text, around: "get hub", context: 10))
        XCTAssertEqual(parts.before, "…cut, then ")
        XCTAssertEqual(parts.after, ", and a lo…")
    }
}
