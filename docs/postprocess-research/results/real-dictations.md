# Real dictations

150 of the author's own dictations from `history.json`, drawn with a fixed seed, replayed through each variant's clean-up path with the writing styles then in use (digits, filler words, lists, quotes) and 6 custom words. Prewarm mode: `prepare()` is called and 1.5 s pass before each clean-up, as while the user speaks. Latency is the clean-up call only. Aggregates only: the dictations themselves are private and are not stored in the repo.

| run | model called | p50 ms | p90 ms | p95 ms | mean ms | outputs differing from main |
|---|---|---|---|---|---|---|
| main | 146/150 | 599 | 1594 | 2702 | 900 | 0 |
| main (repeat, later) | 146/150 | 542 | 1151 | 1530 | 716 | 0 |
| F + conservative gate | 48/150 | 3 | 1556 | 1742 | 407 | 13 |
| F + aggressive gate | 15/150 | 2 | 646 | 1667 | 203 | 22 |
| G + conservative gate | 43/150 | 3 | 1343 | 1614 | 355 | 16 |
| G + conservative gate (repeat) | 43/150 | 3 | 1319 | 1714 | 362 | 16 |
| G + aggressive gate | 10/150 | 3 | 7 | 1608 | 164 | 25 |
| H: context → model, unpunctuated → sherpa last | 10/150 | 2 | 12 | 1890 | 191 | 38 |
| G5 + aggressive gate (under another session's Xcode build) | 10/150 | 2 | 33 | 1613 | 181 | 25 |

Gate reasons per run (why the model was called):

- F + conservative gate: code only 103, unpunctuated 27, custom word hint 13, long unpunctuated run 7, repeated word 1
- F + aggressive gate: code only 136, custom word hint 13, stranded letter 1, repeated word 1
- G + conservative gate: code only 108, unpunctuated 28, long unpunctuated run 8, custom word hint 6, repeated word 1
- G + conservative gate (repeat): code only 108, unpunctuated 28, long unpunctuated run 8, custom word hint 6, repeated word 1
- G + aggressive gate: code only 141, custom word hint 6, stranded letter 3, repeated word 1
- G5 + aggressive gate: code only 141, custom word hint 6, stranded letter 3, repeated word 1 (the 6 hints are real words, which G5 leaves to the model)

The two `main` runs produced identical outputs; their latency differs by ~20% because background load changed between them (a Photos analysis daemon at ~200% CPU during the first). The two conservative-gate runs differ by ~2%.

G5 against G, both aggressive: 1 of 150 outputs differs, a dictation both sent
to the model, where G's output has "i" twice and G5's has "I". Its code-only runs match G's at p50 (1.9 vs 2.5 ms) and p90
(5.4 vs 5.3 ms); 9 of them took 16–103 ms under the other session's build, none of
which run G5's dictionary check (it runs only with hints or screen terms).

These replays carry no screen terms: `history.json` does not keep them, and the
author has screen context on. `screen-terms-and-custom-words.md` measures what the
screen-term rule would add.
