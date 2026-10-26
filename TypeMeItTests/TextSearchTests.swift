import Foundation
import Testing
@testable import TypeMeIt

struct TextSearchTests {
    private func found(_ query: String, in text: String) -> [String] {
        TextSearch.ranges(of: query, in: text).map { String(text[$0]) }
    }

    @Test func rangesIgnoreCase() {
        #expect(found("price", in: "Price first, then the price page.") == ["Price", "price"])
    }

    @Test func rangesIgnoreAccents() {
        #expect(found("cafe", in: "Café first, then the CAFÉ menu.") == ["Café", "CAFÉ"])
    }

    @Test func rangesDoNotOverlap() {
        #expect(found("aa", in: "aaaa") == ["aa", "aa"])
    }

    @Test func anEmptyQueryFindsNothing() {
        #expect(found("", in: "anything").isEmpty)
        #expect(!TextSearch.matches("anything", ""))
        #expect(!TextSearch.Folded("anything").contains(TextSearch.Folded("")))
    }

    /// A list row matches exactly when the highlighter has a range to mark,
    /// whichever way the list searched it.
    @Test(arguments: [
        ("Café au lait", "cafe", true),
        ("cafe au lait", "CAFÉ", true),
        ("Zoë said yes", "zoe", true),
        ("Straße", "strasse", true),
        ("naïve résumé", "NAIVE RESUME", true),
        ("e\u{301}te\u{301}", "ete", true),
        ("Ship it Friday", "ship it", true),
        ("Ship it Friday", "ship  it", false),
        ("Ship it Friday", "monday", false),
    ])
    func everySearchAgrees(text: String, query: String, expected: Bool) {
        #expect(TextSearch.matches(text, query) == expected)
        #expect(TextSearch.Folded(text).contains(TextSearch.Folded(query)) == expected)
        #expect(!TextSearch.ranges(of: query, in: text).isEmpty == expected)
    }

    @Test func historySearchFindsAnAccentedDictationFromAPlainQuery() {
        let entry = HistoryEntry(timestamp: Date(timeIntervalSince1970: 0), transcript: "draft the cafe menu", postProcessRequested: false,
                                 typed: "Draft the café menu for Zoë.", dictionaryFixes: 0)
        let searched = TextSearch.Folded(HistoryTab.searchedText(of: entry))
        #expect(searched.contains(TextSearch.Folded("zoe")))
        #expect(searched.contains(TextSearch.Folded("CAFÉ MENU")))
    }

    @Test func meetingsSearchFindsAccentedWordsWhereThePageHighlightsThem() {
        var meeting = MeetingFixtures.example
        meeting.title = "Café plans"
        meeting.speakers[1].name = "Zoë"
        meeting.paragraphs[1].text = "Sure, the résumé is up."
        #expect(MeetingsTab.matches(meeting, "cafe"))
        #expect(MeetingsTab.matches(meeting, "zoe"))
        #expect(MeetingsTab.matches(meeting, "resume"))
        #expect(!MeetingsTab.matches(meeting, "pelican"))
        #expect(TranscriptFind.hits(of: "resume", in: meeting.paragraphs.map(\.text)).map(\.paragraph) == [1])
    }
}
