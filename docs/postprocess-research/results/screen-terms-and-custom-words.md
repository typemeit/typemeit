# Screen terms and custom words

The author has screen context on (`screenContextEnabled`), so real dictations are
cleaned up with up to 40 terms read off the frontmost window. `history.json` does
not keep those terms, so the real-dictation replays in `real-dictations.md` ran
without screen terms, and their model-call rates leave out every call the
screen-term gate would make, and they ran without the author's learned aliases.
This file measures both gaps and the fixes.

Harness: `Scripts/postprocess-lab/screen/` (`run.sh rules|gate|replace|spell`).
Real dictations are the author's 1,200 in `history.json`; only counts are stored.

## 1. The spell checker hides foreign names

`ScreenContext.terms` keeps a screen word when the dictionary does not know it.
`NSSpellChecker` identifies each word's language by default, so it accepts
"tomasz" and "wieczorek" as Polish and "kavu" as another language's word, and none
of them becomes a term (`run.sh spell`):

| word | known, automatic language | known, English only |
|---|---|---|
| tomasz, wieczorek, kavu | 20/20 | 0/20 |
| kavuu, zentryx, raghunathan, priya, maxxo | 0/20 | 0/20 |

This is why the Tomasz wish fails, and the likely cause of it passing on some
earlier runs and not others: the identification can differ between processes.
Checking against English only, the language the recogniser writes, makes Tomasz
and Wieczorek terms. Lowercased dictionary words then fail English's capitalisation
("friday"), so a word counts as known in the form it is written or capitalised.

## 2. The screen-term gate fires on unrelated screens

The gate (variant G) calls the model when a run of 1–3 words sounds like a screen
term at 0.7 similarity. Every real dictation was paired with every eval screen,
screens the dictation has nothing to do with, so any match is false (`run.sh rules`,
`run.sh gate`):

| rule | eval screens as they are (≤13 terms) | 4 screens merged (21–26 terms, app-sized) |
|---|---|---|
| G: sound ≥ 0.7, length ratio ≥ 0.6 | 12.4% of pairs; 442/1200 dictations | 25.1% of pairs; 411/1200 dictations |
| G3: sound ≥ 0.85, length ratio ≥ 0.7 | 1.6%; 89/1200 | 3.4%; 67/1200 |
| G4: G3 + the run holds a word the dictionary does not know | 0.04%; 2/1200 | 0.1%; 2/1200 |

With G's rule and an app-sized screen, the screen rule alone calls the model on a
quarter of real dictations, on top of the 7% the aggressive gate calls it for
without screens. The false matches at 0.85 are runs of real words that sound like
a term ("read" and READY, "use the" and useState, "times" and Tomasz). The recogniser writes a
non-word when it could not place a name, so G4 asks for one.

On the eval, G3 and G4 lose "cube control" → kubectl (the sounds are 0.71 alike),
which the model fixed on lowercase input but not on the Parakeet-heard input.

## 3. The model leaves capitalised names alone

On the Parakeet-heard inputs, the model was asked about "Tomash" and "Cavu"
(screen: Tomasz, Kavuu), "Centrix" (Zentryx) and "Maxo" (custom word Maxxo), and
returned each as heard. On lowercase input it fixed them. Parakeet capitalises
names, so in real use the model keeps them.

G5 settles these in code. A custom-word hint (a confident word that sounds like a
custom word) whose words include one the dictionary does not know is written
directly; a run with such a word that spells or sounds like a screen term (the
custom-word matcher's thresholds, the screen's term count) is replaced. A real
word that sounds like a term ("whisper", wispr) is still the model's call.

On real dictations (`run.sh replace`):

- Custom words: 4 hints settled in code across 1,200 dictations, all correct
  (a misheard "wispr flow" three times, a misheard lottie.org once).
- Screen terms, unrelated app-sized screens: 1 dictation changed, "Prisma" written
  as the screen's lowercase "prisma".

## 4. A live bug in the filler-word style

`WritingStyle.capitaliseSentences` runs on every output when the filler-word
style is on, and treated any ".", "?" or "!" as a sentence end, including the dot
inside a word. On `main`: "claude.md" → "claude.Md", "lottie.org" → "lottie.Org",
"history.json" → "history.Json", "e.g. the" → "e.G. The". G5 ends a sentence only
where a space follows the mark. Replayed through the code path, this changed 15 of
1,177 real dictations, each one a file name, domain or "e.g." put back. The word
after "e.g. " is still capitalised, as on `main`.

## 5. Learned aliases

The app keeps "aliases" for custom words: spellings the user corrected to the word,
which the matcher treats as a full sound match. The replays above ran without
them. With the author's 5 aliases on the 1,177 real dictations (code path only,
`screen/hints.swift`):

| variant | dictations with a custom-word hint | dictations the gate sends to the model |
|---|---|---|
| G5, no aliases | 34 | 79 (6.7%) |
| G5, the author's aliases | 116 | 150 (12.7%) |
| G6 = G5 + aliases as sound targets | 168 | 199 (16.9%) |
| G7 = G5 + real-word aliases need the term's sound | 34 | 79 (6.7%) |

Two of the aliases are real words: "really" (for kinda) and "Claude" (for
granola), each learned from one correction. Every confident "really" and "Claude"
became a hint, so a model call, and with the model free to swap it. G6 made it
worse: "clawed", "cloudy" and "child" also sounded like the granola alias. G7
drops a hint when its words are all in the dictionary and do not sound like the
term itself; code-path outputs are unchanged and both evals score as G5.

In `main` the same alias also replaces words outright: a run spelling an alias
counts as a full sound match, and a word scored under 0.9 is replaced without the
model. In the 135 recordings, one "Claude" scored 0.87; with today's aliases it
would be typed as "granola". G7 guards only the hint path; the outright
replacement happens in `CustomWordMatcher` before clean-up, so the fix belongs
where the terms are built (`Store.terms(for:)`): leave out an alias that is a
dictionary word and does not sound like its term.

G6 also fixed "Titamir" → typeme.it on the Parakeet-heard set (272/335), the only
case it changed. Rejected for the extra hints.

## Results

| variant | eval | wishes | model applied | mean ms | Parakeet-heard eval | wishes | model applied | mean ms |
|---|---|---|---|---|---|---|---|---|
| main | 335 | 0/14 | 345 | 946 | 270 | 4/14 | 343 | 888 |
| G, aggressive gate | 327 | 5/14 | 10 | 25 | 269 | 7/14 | 11 | 28 |
| G3, aggressive | 326 | 6/14 | 6 | 18 | 269 | 7/14 | 7 | 18 |
| G4, aggressive | 326 | 6/14 | 6 | 19 | 269 | 7/14 | 7 | 20 |
| G5, aggressive | 326 | 6/14 | 3 | 12 | 271 | 8/14 | 3 | 10 |
| G6, aggressive | 326 | 6/14 | 3 | 11 | 272 | 8/14 | 3 | 10 |
| G7, aggressive | 326 | 6/14 | 3 | 18 | 271 | 8/14 | 3 | 11 |

The Parakeet-heard column uses the recogniser's own word confidences
(`sets/cases-parakeet-audio-conf.json`), so a misheard custom word the recogniser
was unsure of ("Blebbered", 0.76) is replaced by the matcher as in the app.
