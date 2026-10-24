# Cheap triggers for mishearings

The aggressive gate skips the model unless the transcript shows a reason to call
it. A mishearing ("where" for "were") shows none, so the question was whether a
cheap signal could flag the transcripts that need the model's word edits.

## What the model changes in real use

On the 135 real recordings (transcribe.cpp, the app's recogniser), the Apple model's
output was compared with the code-only output of the same transcript. The model
changed words beyond the code passes in 16 of 135: about 4 were real fixes (a
misheard verb, a truncated word, two compounds joined), 7 cut "like" or "right"
with the filler style off, and 5 were wrong or unwanted (deleted profanity, a word
swapped for an unrelated custom word). So the target is small: ~3% of dictations
carry a mishearing the model fixes.

## Word confidence from the recogniser

transcribe.cpp reports a confidence per word (`Scripts/postprocess-lab/tcpp`).
Across the 135 recordings: p5 0.89, p10 0.90, p25 0.95, median 0.99.

| flag a dictation when a word is below | dictations flagged | model word changes caught |
|---|---|---|
| 0.4–0.7 | 0/135 | 0/16 |
| 0.8 | 17/135 | 4/16 |

No word in 135 recordings scored under 0.7. At 0.8 the trigger calls the model on
13% of dictations and catches 4 of the 16 changes, 2 of them filler cuts. Not a
usable trigger.

## macOS grammar checker

`NSSpellChecker` grammar checking (`Scripts/postprocess-lab/grammar/`) on each
transcript: 0 flags on 172 punctuated eval inputs and 0 on 150 real transcripts,
including the one where the model later fixed "where" to "were". Not a trigger.

## Conclusion

Neither signal separates misheard transcripts from clean ones. The recogniser is
confident about its homophone errors, which is why they reach clean-up at all.
