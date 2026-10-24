# Speech recognition

Recogniser time only (audio already decoded to 16 kHz). Same machine and conditions as the other runs; FluidAudio v0.17.4 (CoreML, int8 encoder unless noted) vs the app's transcribe.cpp (parakeet-unified-en-0.6b Q8_0, Metal). Both run the same underlying model.

## Eval clips (121 synthesised with `say -v Daniel`, 2–30 s)

| recogniser | p50 ms | p95 ms | mean ms |
|---|---|---|---|
| transcribe.cpp (current) | 53 | 104 | 70 |
| FluidAudio int8 | 45 | 58 | 50 |
| FluidAudio int8 + vocabulary boosting | 151 | 209 | 167 |

Vocabulary boosting on the 23 clips that carry custom words or screen terms fixed Wispr, Maxxo, Bluebird, Kavuu, Zentryx, LottieHQ, useState, MAX_RETRIES, parse_config, LOT-1482 and typeme.it in the recogniser, and misfired three times: "withheld" → Mitchell (a screen term), "Check" → Ack (custom word "ack"), "in a whisper" → wispr. Threshold sweeps (`fluid/score_vocab.py`): turning the acoustic rescue pass off removes the "ack" misfire; only a similarity floor of 0.65 removes "Mitchell", and it also loses 2 real fixes; "whisper" → wispr survives every setting.

## Real recordings (135 of the 150 sampled dictations whose audio is kept)

| recogniser | p50 ms | p95 ms | mean ms | word differences vs transcribe.cpp | 20+ word transcripts with no sentence end | transcripts the gate would send for punctuation |
|---|---|---|---|---|---|---|
| transcribe.cpp (current) | 123 | 1478 | 456 | 0.0% | 14/40 | 32/135 |
| transcribe.cpp (current), re-run in the same period as the window runs | 210 | 4238 | 971 | — | 14/40 | 32/135 |
| transcribe.cpp, 15 s windows split at quiet points | 262 | 2200 | 620 | 2.5% | 7/40 | 22/135 |
| transcribe.cpp, 30 s windows | 301 | 2885 | 661 | 1.9% | 8/40 | 26/135 |
| FluidAudio int8 | 68 | 579 | 160 | 3.6% | 5/40 | 19/135 |
| FluidAudio int8 + boosting (6 custom words) | 278 | 1631 | 533 | 4.3% | 5/40 | 20/135 |

Boosting with the 6 custom words changed 19 spans across the 135 recordings, nearly all wrong: stuff → notifi; notifies → notifi; notify → notifi; notify → notifi; notification → notifi; find → kinda; lineage → kinda; kind → kinda; something → notifi; side → kinda; side → kinda; grant → granola; user flows → wisprflow; not to → notifi; find → kinda; find → kinda; inside → kinda; cognitive → notifi; kind → kinda.

Timing noise: the first transcribe.cpp and FluidAudio rows were measured together; the window rows and the transcribe.cpp re-run were measured later in a noisier period (the same full-buffer run took p50 210 ms instead of 123 ms), so compare the window rows with that re-run, not with the first row.

## int8 vs fp16, and streaming (135 real recordings, one later period)

Measured back to back on 2026-09-26 while another session's debug app used
60–116% CPU; compare these rows with each other, not with the tables above.
`fluid/Sources/fluidstream` feeds each recording in 100 ms buffers, processing
whatever complete chunks exist after each one as a live dictation would, and
times `finish()` after the last buffer: the wait after the user lets go.
Aggregates in `asr/fluidaudio-int8-fp16-streaming.json`.

| recogniser | wait after release: p50 ms | p95 ms | mean ms | word differences vs FluidAudio batch int8, clips under 15 s (110) | clips of 15 s and over (25) |
|---|---|---|---|---|---|
| transcribe.cpp (current), batch | 112 | 1664 | 517 | 1.6% | 4.9% |
| FluidAudio int8, batch | 52 | 358 | 104 | — | — |
| FluidAudio fp16, batch | 78 | 549 | 151 | 0.26% of all words | |
| FluidAudio int8, streaming [70,13,13] (2.08 s look-ahead) | 24 | 40 | 26 | 2.9% | 6.7% |
| FluidAudio int8, streaming [70,7,7] (1.12 s) | 21 | 37 | 24 | 4.2% | 8.1% |

- int8 is 1.45× faster than fp16 and differs from it in 8 of 3,103 words. Model
  load: 16 s int8, 59 s fp16 (first load compiles the CoreML model).
- Batch int8 is 5× faster than transcribe.cpp on the mean and 4.6× at p95, and
  on short clips the two agree on all but 1.6% of words. Repeat runs of each are
  word-for-word identical.
- Streaming keeps pace easily (processing took at most 3.9% of the audio's
  duration; the worst single step was 116 ms) and cuts the wait after release to
  ~25 ms at any length. It is less stable than batch: on short clips,
  transcribe.cpp sided with batch in 18 of the 21 clips where streaming differed.
  Streaming drops "um"/"uh" (harmless before clean-up) but also changed real words
  ("like" → "light", "can you" → "new") and added five words to one 5 s clip.
  On long recordings it dropped words mid-stream (40 in one 394 s recording).
- The smaller look-ahead tier is no faster at release and less stable.

Batch int8 is the change to make: the gain is large and the output matches
today's. For long dictations, transcribing completed 15 s windows while the user
is still speaking would keep batch accuracy and leave only the last window for
after release; not built.
