import Foundation

func show(_ label: String, _ got: String, _ want: String) {
    print(got == want ? "ok  " : "BAD ", label, got == want ? "" : "\n      got:  \(got.debugDescription)\n      want: \(want.debugDescription)")
}
// Kept words
show("restore like mid", PostProcessor.restoreKeptWords(transcript: "it was like really cold out there", output: "It was really cold out there."), "It was like really cold out there.")
show("restore like before five", PostProcessor.restoreKeptWords(transcript: "I am actually going to be like five minutes late", output: "I am actually going to be five minutes late."), "I am actually going to be like five minutes late.")
show("restore you know", PostProcessor.restoreKeptWords(transcript: "which is you know either a good sign", output: "which is either a good sign"), "which is you know either a good sign")
show("restore at end", PostProcessor.restoreKeptWords(transcript: "it was fine you know", output: "It was fine."), "It was fine you know.")
show("no restore when replaced", PostProcessor.restoreKeptWords(transcript: "be like five minutes", output: "be 5 minutes"), "be 5 minutes")
show("no restore at start", PostProcessor.restoreKeptWords(transcript: "like I don't even know", output: "I don't even know."), "I don't even know.")
show("no restore of other words", PostProcessor.restoreKeptWords(transcript: "and third my mum", output: "Third, my mum"), "Third, my mum")
show("unchanged", PostProcessor.restoreKeptWords(transcript: "hello there", output: "Hello there."), "Hello there.")
// Opening guard
print(PostProcessor.lostOpening(transcript: "she said ship it", output: "ship it") ? "ok   she said ship it rejected" : "BAD  she said ship it accepted")
print(!PostProcessor.lostOpening(transcript: "their going to the shops later", output: "They're going to the shops later.") ? "ok   their going accepted" : "BAD their going rejected")
print(!PostProcessor.lostOpening(transcript: "were meeting at there house at seven", output: "We're meeting at their house at 7.") ? "ok   were meeting accepted" : "BAD were meeting rejected")
print(!PostProcessor.lostOpening(transcript: "ok so three things", output: "Okay, so three things.") ? "ok   ok so accepted" : "BAD ok so rejected")
print(PostProcessor.lostOpening(transcript: "that will be 25 dollars please", output: "$25 please") ? "ok   that will be rejected" : "BAD that will be accepted")
// Units
show("percent", Digits.unitFigures("we have moved about sixty percent of the customers"), "we have moved about 60% of the customers")
show("per cent", Digits.unitFigures("a hundred per cent yes"), "100% yes")
show("pounds", Digits.unitFigures("it costs one hundred and twenty pounds"), "it costs 120 pounds")
show("no unit", Digits.unitFigures("we need three more people"), "we need three more people")
show("pronoun one", Digits.unitFigures("one of the dollars"), "one of the dollars")
// Years
show("time", Digits.apply("it closes at five thirty"), "it closes at 5:30")
// Fillers
show("like three more", WritingStyle.cutFillers("second we need like three more people"), "Second we need three more people")
show("like five minutes", WritingStyle.cutFillers("it took like five minutes"), "It took five minutes")
show("I'd like two", WritingStyle.cutFillers("I'd like two coffees"), "I'd like two coffees")
show("looks like two", WritingStyle.cutFillers("it looks like two people are coming"), "It looks like two people are coming")
show("like two factor", WritingStyle.cutFillers("things like two factor auth"), "Things like two factor auth")
// Lists
show("list stops", WritingStyle.numberedList("two things first the build is red and second the release notes are missing"), "Two things.\n1. The build is red.\n2. The release notes are missing.")
// Screen names
show("fuse use state", ModelText.fuseTerms("the use state hook", terms: ["useState"]), "the useState hook")
show("fuse onedrive", ModelText.fuseTerms("open one drive now", terms: ["OneDrive"]), "open OneDrive now")
show("no fuse", ModelText.fuseTerms("I have one four you", terms: ["LOT-1482"]), "I have one four you")
show("and-join two numbers", Digits.unitFigures("two thousand and two thousand two hundred pounds"), "two thousand and 2200 pounds")
show("digits two numbers", Digits.apply("between two thousand and two thousand two hundred"), "between 2000 and 2200")
show("hundred and twenty", Digits.apply("one hundred and twenty pounds"), "120 pounds")
show("two hundred fifty thousand", Digits.apply("two hundred and fifty thousand people"), "250000 people")
show("three million two hundred thousand", Digits.apply("three million two hundred thousand"), "3200000")
show("a thousand and one", Digits.apply("a thousand and one nights"), "1001 nights")
show("two hundred three hundred", Digits.apply("two hundred three hundred"), "200 300")
show("one hundred thousand", Digits.apply("one hundred thousand"), "100000")
show("pronoun i", LocalCleanup.run("so i think i'm right, i said"), "so I think I'm right, I said")
show("i.e. kept", LocalCleanup.run("use i.e. and item i"), "use i.e. and item I")
