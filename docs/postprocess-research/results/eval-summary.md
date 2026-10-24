# Eval runs

G3–G5 are described in `screen-terms-and-custom-words.md`, the local LLMs in
`local-llms.md`.

Each row is one run of the 335 eval cases plus 14 wishes (`Scripts/cleanup-eval/cases.json`), cold sessions, back to back, one run at a time on an M4 (24 GB) with other apps running. "Words only" re-scores every run ignoring case, punctuation and line breaks. Per-case outputs are in `eval/`.

| run | eval | words only | wishes | wishes, words only | p50 ms | p95 ms | mean ms | model applied |
|---|---|---|---|---|---|---|---|---|
| main | 335/335 | 335/335 | 0/14 | 2/14 | 787 | 2256 | 946 | 345/349 |
| code-only | 305/335 | 307/335 | 2/14 | 5/14 | 1 | 6 | 2 | 0/349 |
| A-code-only | 327/335 | 329/335 | 4/14 | 6/14 | 0 | 2 | 1 | 0/349 |
| A2-code-only | 324/335 | 326/335 | 4/14 | 6/14 | 0 | 2 | 1 | 0/349 |
| A | 335/335 | 335/335 | 7/14 | 8/14 | 695 | 2344 | 952 | 344/349 |
| A2 | 335/335 | 335/335 | 5/14 | 6/14 | 773 | 2068 | 923 | 344/349 |
| A2-gate-conservative | 335/335 | 335/335 | 6/14 | 7/14 | 734 | 2001 | 863 | 338/349 |
| A2-gate-aggressive | 327/335 | 329/335 | 4/14 | 6/14 | 0 | 2 | 25 | 10/349 |
| A2-schema-out-of-prompt | 333/335 | 334/335 | 5/14 | 5/14 | 737 | 1770 | 852 | 344/349 |
| A2-edits-only | 293/335 | 294/335 | 5/14 | 6/14 | 1178 | 4004 | 1867 | 343/349 |
| A2-s1-mini | 270/335 | 285/335 | 4/14 | 7/14 | 118 | 799 | 204 | 345/349 |
| F-gate-conservative | 335/335 | 335/335 | 5/14 | 6/14 | 730 | 2136 | 880 | 338/349 |
| F-gate-aggressive | 327/335 | 329/335 | 5/14 | 6/14 | 0 | 2 | 26 | 10/349 |
| G-gate-conservative | 335/335 | 335/335 | 5/14 | 6/14 | 718 | 2084 | 863 | 338/349 |
| G-gate-aggressive | 327/335 | 329/335 | 5/14 | 6/14 | 0 | 2 | 25 | 10/349 |
| G-punct-first-pcs | 324/335 | 325/335 | 4/14 | 6/14 | 1 | 5 | 29 | 3/349 |
| G-punct-first-sherpa | 308/335 | 309/335 | 5/14 | 6/14 | 0 | 2 | 37 | 3/349 |
| G-punct-last-sherpa-v1 | 325/335 | 327/335 | 4/14 | 6/14 | 2 | 6 | 20 | 3/349 |
| G-punct-last-sherpa-v2 | 327/335 | 329/335 | 5/14 | 6/14 | 3 | 7 | 54 | 10/349 |
| H-punct-last-sherpa | 327/335 | 329/335 | 4/14 | 6/14 | 2 | 4 | 27 | 10/349 |
| G3-gate-aggressive | 326/335 | 328/335 | 6/14 | 7/14 | 0 | 2 | 18 | 6/349 |
| G4-gate-aggressive | 326/335 | 328/335 | 6/14 | 7/14 | 1 | 2 | 19 | 6/349 |
| G5-gate-aggressive | 326/335 | 328/335 | 6/14 | 7/14 | 1 | 2 | 12 | 3/349 |
| local-llm-lfm2.5-1.2b (G, conservative gate) | 271/335 | 273/335 | 4/14 | 4/14 | 677 | 2270 | 770 | 332/349 |
| local-llm-qwen3-4b-2507 (G, conservative gate) | 240/335 | 242/335 | 6/14 | 6/14 | 629 | 3855 | 1000 | 337/349 |

## Inputs as Parakeet hears them

The eval's inputs are typed, mostly lowercase and unpunctuated. Parakeet's output
is punctuated and cased in ~77% of real dictations, so a second set replaces each
input with what the app's recogniser (transcribe.cpp, parakeet-unified) heard when
the input was spoken by `say -v Daniel`: `Scripts/postprocess-lab/sets/cases-parakeet-audio.json`,
built by `parakeet-audio-cases.py`. 23 of 132 inputs came back unpunctuated.
Expected outputs are unchanged. The first three rows count every word as
confident (the eval default), so a sound-alike custom word is a hint for the
model; the rows "with confidences" use the recogniser's word scores
(`cases-parakeet-audio-conf.json`), as the app does.

| run | eval | words only | wishes | wishes, words only | p50 ms | p90 ms | p95 ms | mean ms | model applied |
|---|---|---|---|---|---|---|---|---|---|
| main | 270/335 | 271/335 | 4/14 | 4/14 | 729 | 1612 | 1784 | 858 | 343/349 |
| G + conservative gate | 269/335 | 270/335 | 7/14 | 7/14 | 1 | 1553 | 1704 | 300 | 93/349 |
| G + aggressive gate | 269/335 | 270/335 | 7/14 | 8/14 | 0 | 2 | 2 | 28 | 11/349 |
| main, with the recogniser's confidences | 270/335 | 271/335 | 4/14 | 4/14 | 752 | 1626 | 1826 | 888 | 343/349 |
| G + aggressive gate, with confidences | 269/335 | 270/335 | 7/14 | 8/14 | 0 | 2 | 2 | 27 | 11/349 |
| G5 + aggressive gate, with confidences | 271/335 | 272/335 | 8/14 | 9/14 | 1 | 2 | 2 | 10 | 3/349 |

On these inputs the aggressive gate calls the model on 3% of runs and scores the
same as the conservative gate. Against `main` it loses 4 runs and gains 3 plus 3
wishes. Lost: "set time up" → "set a timer" (a mishearing the model fixed),
"sort of" cut with the filler style, Parakeet's "2,000" left with its comma under
the digits style, and a missing comma. Gained: a list the model had broken, a
filler-style run the model had over-cut, a quote, and three wishes where the
model had cut "like" or quoted wrongly.

The 62 runs both `main` and the aggressive gate fail are mostly not clean-up
problems:

- 48 are numbers: Parakeet writes "42", "8" and "7" as digits, and the eval expects
  words when the digits style is off. One is Parakeet hearing "five thirty" as "53".
- 8 are names and terms nothing fixed: custom words heard as "Maxo", "Blebbered",
  "Titamir" and "Whisper" (the model was asked and kept them), screen terms heard
  as "Tomash", "Cavu" and "cube control", and "Appi", "proasangs", "uship".
- 6 are the recogniser hearing something else: "notifier" for "notify", "We were"
  for "were", "I'm" for "um", "as" for "is", "re-renders" hyphenated, and French
  with `<unk>` tokens left in the text.

Per-case outputs: `eval/parakeet-audio-*.json`.
