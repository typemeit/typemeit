# type me it

## English only

The app transcribes and cleans up English only; the speech model is English
(docs/app-store.md). Don't build features or write eval cases for other
languages. The clean-up prompt's keep-the-language rule stays anyway: removing
it made the model contract and drop words in English transcripts (18 eval
failures).

## Running a build locally

Debug builds are a separate app, `type me it dev` (bundle id `it.typeme.typemeit.dev`),
signed with the Developer ID certificate. Run it straight from DerivedData; never copy
a build over `/Applications/type me it.app`, which is the user's release install.

```sh
DEVELOPMENT_TEAM=Z28DW76Y3W xcodegen generate
xcodebuild -project TypeMeIt.xcodeproj -scheme TypeMeIt -configuration Debug -derivedDataPath /tmp/typemeit-dd build
open "/tmp/typemeit-dd/Build/Products/Debug/type me it dev.app"
```

`/tmp/typemeit-dd` is shared by every worktree, and is not a tidiness choice: a
`-derivedDataPath` inside the worktree gives each one its own full copy of the build,
which reached 24.6 GB across nine worktrees. Sharing it also means a second worktree
rebuilds only what its own diff changed instead of starting cold. Two worktrees must
not build at once, which the one-dev-instance rule below already requires.

Only one dev instance may run at a time. Other worktrees build the same app, so
check for and stop any running copy before launching yours:

```sh
pgrep -fil "type me it dev.app/Contents/MacOS"
pkill -fi "type me it dev.app/Contents/MacOS"
```

Because the signature is stable, macOS keeps the dev app's Microphone and Accessibility
grants across rebuilds. They are granted once through the dev app's
own onboarding. The dev app has its own UserDefaults, so settings and onboarding state
do not carry over from the release app.

The settings window opens from the menu bar puff → "type me it"; the app menu has no
settings item. Opening the build path again on a running instance also reopens it.
Avoid `open -a "type me it dev"`: with several worktree builds registered, Launch
Services may start another worktree's copy.

## Copy: less is more

Every string the user sees — group titles, row labels, captions, empty states,
menu items — is written short. Cut hedging and cut throat-clearing before you
cut information; a one-word title beats a three-word one whenever the row it
sits over already tells the reader what the numbers are. When you find yourself
writing an explainer inside a label, the label is wrong. This rule holds even
when a longer version scans fine on its own: on a page of short strings a long
one snags, and the page reads as noisier than it is.

## Settings rows: help vs caption

`SquareSettingsRow` takes two strings under its label, and each has one job:

- `help:` (the ? popup) says what the setting does: explanations, examples,
  consequences, warnings.
- `caption:` (sub text) shows a value, never an explanation: a file path, or
  why the row is blocked right now.

Write both the same way: no full stops, parts joined with " · ", never a
newline. The off state reads "off: …". A blocked row says "needs …" or names
the state ("apple intelligence is off"); the button beside it gives the fix,
so the caption doesn't repeat it.

## Eval variants are observed, never predicted

An `alsoAccepted` entry in `Scripts/cleanup-eval/cases.json` records an output
the model actually produced in a run and that was judged fine. Do not add one
because the model might plausibly do something; run `make eval`, read the
output, then add it with a `why` that says what was seen. Behaviour that is
pure code (digits, lists, quotes, the safe contractions) is tested in
`TypeMeItTests`, not with eval cases.

## Granted wishes join the eval

A case with a `wish` field is one the pipeline does not pass yet. When a change
makes a wish pass, delete its `wish` field in the same change, so the case
guards that behaviour from then on and `make eval` fails if it regresses. A wish
passed only by a model output that varies between runs stays a wish until it
passes on repeated runs.

## Counts agree with their noun

A string that shows a count next to a noun goes through `counted(n, "word")`
(TypeMeIt/Plural.swift), so it reads "1 word" and "2 words". Never write
"\(n) words" or "word(s)" in anything the user sees.

## New models join the model scout

When a change adds a model, or swaps one, for any feature, add it to the
model list in `.claude/skills/model-scout/SKILL.md` in the same change: its
role, the model and version, and where it is configured. The daily scout only
looks for alternatives to models on that list.

## The user's ear settles disputed transcripts

When transcripts or models disagree and the scores can't say who is right, when
asked to review transcription output, or when told a transcript was bad, use
the `listen-review` skill: build a short listening set and let the user judge.
