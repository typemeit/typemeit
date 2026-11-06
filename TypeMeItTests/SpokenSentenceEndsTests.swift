import Testing
@testable import TypeMeIt

struct SpokenSentenceEndsTests {
    private func cleaned(_ heard: String, styles: Set<WritingStyle> = []) async -> String {
        let words = heard.split(separator: " ").map { CustomWordMatcher.Word(text: String($0), confidence: 1) }
        return await PostProcessor.shared.clean(CustomWordMatcher.apply(words, terms: [String]()), customWords: [], styles: styles).text
    }

    @Test func aDescribedMarkKeepsItsWords() {
        #expect(ModelText.spokenSentenceEnds("Remove the last question mark.") == "Remove the last question mark.")
        #expect(ModelText.spokenSentenceEnds("We came to a complete full stop.") == "We came to a complete full stop.")
    }

    @Test func aFullStopSaidLastIsKept() async {
        #expect(await cleaned("Send it full stop.") == "Send it.")
    }

    @Test func aFullStopTheSpeechModelAddedGoes() async {
        #expect(await cleaned("Send it.") == "Send it")
    }

    @Test func aListKeepsNoFinalFullStop() async {
        #expect(await cleaned("Send it.", styles: [.lists]) == "Send it")
    }

    @Test(arguments: [
        ("Is it ready question mark.", "Is it ready?"),
        ("Is it ready question mark", "Is it ready?"),
        ("Is it ready, question mark.", "Is it ready?"),
        ("Is it ready. Question mark.", "Is it ready?"),
        ("Is it ready question mark?", "Is it ready?"),
        ("Is it ready QUESTION MARK.", "Is it ready?"),
        ("Is it ready question mark. Send it.", "Is it ready? Send it."),
        ("Is it ready question mark. Is it tested question mark.", "Is it ready? Is it tested?"),
        ("Can we ship on the 12 question mark.", "Can we ship on the 12?"),
        ("Who said 'now' question mark.", "Who said 'now'?"),
        ("Is it the blue one (the big one) question mark.", "Is it the blue one (the big one)?"),
        ("First line\nIs it ready question mark.", "First line\nIs it ready?"),
        ("Is it ready  question mark.", "Is it ready?"),
        ("Why does this have a question mark? Pick one.", "Why does this have a question mark? Pick one."),
        ("Move the question mark.", "Move the question mark."),
        ("add question mark icon", "add question mark icon"),
        ("Question mark.", "Question mark."),
        ("Is it just question mark or not", "Is it just question mark or not"),
        ("Add question mark.", "Add question mark."),
        ("This needs a comma and question mark.", "This needs a comma and question mark."),
    ])
    func questionMark(said: String, written: String) {
        #expect(ModelText.spokenSentenceEnds(said) == written)
    }

    @Test(arguments: [
        ("Send it full stop.", "Send it."),
        ("Send it full stop", "Send it."),
        ("Send it, full stop.", "Send it."),
        ("Send it. Full stop.", "Send it."),
        ("Send it full stop!", "Send it."),
        ("Send it FULL STOP.", "Send it."),
        ("Send it full stop. Then wait.", "Send it. Then wait."),
        ("Send it full stop. Then wait full stop.", "Send it. Then wait."),
        ("Call me at 12 full stop.", "Call me at 12."),
        ("They said 'now' full stop.", "They said 'now'."),
        ("Take the blue one (the big one) full stop.", "Take the blue one (the big one)."),
        ("First line\nSend it full stop.", "First line\nSend it."),
        ("Send it  full stop.", "Send it."),
        ("Is it full stop?", "Is it full stop?"),
        ("Use a full stop.", "Use a full stop."),
        ("Try to avoid using full stop at the end.", "Try to avoid using full stop at the end."),
        ("Remove the full stop.", "Remove the full stop."),
        ("Full stop.", "Full stop."),
        ("Add full stop.", "Add full stop."),
        ("We came to a full stop.", "We came to a full stop."),
    ])
    func fullStop(said: String, written: String) {
        #expect(ModelText.spokenSentenceEnds(said) == written)
    }

    @Test(arguments: [
        ("We won exclamation mark.", "We won!"),
        ("We won exclamation mark", "We won!"),
        ("We won, exclamation mark.", "We won!"),
        ("We won. Exclamation mark.", "We won!"),
        ("We won exclamation mark!", "We won!"),
        ("We won EXCLAMATION MARK.", "We won!"),
        ("We won exclamation mark. See you soon.", "We won! See you soon."),
        ("We won exclamation mark. Well done exclamation mark.", "We won! Well done!"),
        ("We scored 12 exclamation mark.", "We scored 12!"),
        ("They said 'wow' exclamation mark.", "They said 'wow'!"),
        ("It was the blue one (the big one) exclamation mark.", "It was the blue one (the big one)!"),
        ("First line\nWe won exclamation mark.", "First line\nWe won!"),
        ("We won  exclamation mark.", "We won!"),
        ("Is it exclamation mark?", "Is it exclamation mark?"),
        ("Use an exclamation mark.", "Use an exclamation mark."),
        ("Try using exclamation mark less often.", "Try using exclamation mark less often."),
        ("Remove the exclamation mark.", "Remove the exclamation mark."),
        ("Exclamation mark.", "Exclamation mark."),
        ("Add exclamation mark.", "Add exclamation mark."),
        ("It ends with an exclamation mark.", "It ends with an exclamation mark."),
    ])
    func exclamationMark(said: String, written: String) {
        #expect(ModelText.spokenSentenceEnds(said) == written)
    }

    @Test(arguments: [
        ("That was great exclamation point.", "That was great!"),
        ("That was great exclamation point", "That was great!"),
        ("That was great, exclamation point.", "That was great!"),
        ("That was great. Exclamation point.", "That was great!"),
        ("That was great exclamation point!", "That was great!"),
        ("That was great EXCLAMATION POINT.", "That was great!"),
        ("That was great exclamation point. See you soon.", "That was great! See you soon."),
        ("That was great exclamation point. Thank you exclamation point.", "That was great! Thank you!"),
        ("It went up by 12 exclamation point.", "It went up by 12!"),
        ("They shouted 'stop' exclamation point.", "They shouted 'stop'!"),
        ("I loved the red one (the small one) exclamation point.", "I loved the red one (the small one)!"),
        ("First line\nThat was great exclamation point.", "First line\nThat was great!"),
        ("That was great  exclamation point.", "That was great!"),
        ("Is that exclamation point?", "Is that exclamation point?"),
        ("Use an exclamation point.", "Use an exclamation point."),
        ("Try using exclamation point sparingly.", "Try using exclamation point sparingly."),
        ("Remove the exclamation point.", "Remove the exclamation point."),
        ("Exclamation point.", "Exclamation point."),
        ("Add exclamation point.", "Add exclamation point."),
        ("It ends with an exclamation point.", "It ends with an exclamation point."),
    ])
    func exclamationPoint(said: String, written: String) {
        #expect(ModelText.spokenSentenceEnds(said) == written)
    }
}
