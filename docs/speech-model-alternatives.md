# Alternatives to Parakeet for transcription, and why WER barely separates them

Type Me It transcribes with `parakeet-unified-en-0.6b-Q8_0` through transcribe.cpp
(`Transcriber.swift`, `ModelStore.swift`): English only, 697 MB, downloaded during
onboarding. This note records what else could do that job, local or paid, and why
the word error rates quoted for all of them are a weaker argument than they look.
Written September 2026.

## Why WER differences are not the deciding number

Word error rate is the share of words a model gets wrong against a reference
transcript, averaged over a benchmark suite. Four things make small differences in
it close to meaningless for this app.

**The published numbers are not measured on the same audio.** The Open ASR
Leaderboard average comes from eight fixed datasets. [Open ASR Leaderboard][oasr]
Paid providers quote their own corpora, so ElevenLabs' 2.2% and Parakeet's 5.91%
are not a 3.7-point gap; they are two numbers from different exams. Only the
leaderboard column compares models to each other.

**The benchmarks average over audio we do not have.** Leaderboard suites are
weighted towards meetings, telephony, broadcast and multi-speaker recordings.
Dictation is one speaker, close mic, in a quiet room, for ten seconds. That is the
easy end of every one of those datasets, and at the easy end the models converge:
Parakeet is around 1.9% on clean LibriSpeech against a 6.34% leaderboard average
for the same weights. The spread between models lives in the hard audio the
average is mostly made of, not in ours.

**On genuinely hard audio nothing wins.** Real multi-speaker audio with background
noise puts every local model and every cloud service in the 8–12% band regardless
of leaderboard placing. [Northflank][northflank] There is no model to buy our way
to that is robust to a noisy room.

**Our remaining errors are not the acoustic model's.** What users actually correct
is proper nouns, product names, jargon and spelling of things no general model has
seen. That is what `CustomWordMatcher.swift` and the learning path exist for, and
no WER point moves it. A model swap does nothing for the errors we get complaints
about.

So the honest ranking criteria are size, load and run time, licence, language
coverage, and whether audio leaves the machine. WER is a floor check — is this
model in the right class at all — not a tiebreaker.

## Local English models

| Model | WER | Size | Notes |
|---|---|---|---|
| Parakeet Unified EN 0.6B | 5.91% | 631 MB INT8 | What we ship. Best English number in this class. [OpenWhispr][openwhispr] |
| Parakeet TDT 0.6B v3 | 6.80% English | same class | Same weights class, 25 languages. English is worse than what we ship. [model card][v3] |
| Nemotron Speech Streaming EN 0.6B | 6.93% | 632 MB INT8 | Built for streaming, 80 ms–1.12 s latency settings. [OpenWhispr][openwhispr] |
| Whisper large-v3-turbo | ~7.8% English | 1.55B params | 99 languages, MIT, better on accents and noise. Bigger and slower. |
| Moonshine | well behind | tiny | Variable-length input, no 30 s padding. A low-end-hardware tier. |

Parakeet is a transducer and runs single-pass, which is why it is fast on CPU and
why the CoreML path can sit on the Neural Engine rather than contending with
anything using the GPU. [Soniqo][soniqo]

The leaderboard's top open models — IBM Granite Speech 4.1 2B at 5.33%, Cohere
Transcribe at 5.42%, NVIDIA Canary-Qwen 2.5B at 5.63% — are all 2B and up and
assume an NVIDIA GPU. [MarkTechPost][mtp] Half a WER point is not worth three times
the download and a dependency we cannot ship.

**v3 is a downgrade for us.** It is the obvious-looking upgrade and it is not one:
same size, same runtime shape, roughly 0.9 points worse on English. It is only
worth taking if multilingual dictation becomes a goal, and supporting 25 languages
one at a time is a different feature from handling two in one sentence, which is
what providers mean by code-switching.

## Paid APIs

| Provider | WER (self-quoted) | Price | Latency |
|---|---|---|---|
| ElevenLabs Scribe v2 | 2.2% | $0.22/hr batch | ~150 ms first partial |
| OpenAI gpt-4o-transcribe | 4.0% | $0.006/min | — |
| Deepgram Nova-3 | 5.2% | $0.0043/min batch, $0.0077 streaming | lowest end-of-speech detection |
| AssemblyAI Universal-3 Pro | within 1–2 points | ~$0.37/hr | ~760 ms time-to-final |
| Microsoft MAI-Transcribe-1 | within 1–2 points | — | — |

The top five sit inside one to two points of each other; accuracy has plateaued and
the competition has moved to streaming latency, end-of-turn detection and
code-switching. [Coval][coval], [Future AGI][futureagi]

Cost is real but not the obstacle: at $0.006/min a user dictating an hour a day
costs $6–11 a month, most of a subscription. The obstacles are a network round trip
on an utterance that currently never leaves the process, a hard dependency on
connectivity for the app's only function, and the first line of the README.
"Nothing leaves the computer" is the product, not a footnote.

## Recommendation

Keep Parakeet Unified EN. It is the most accurate English model in its size class,
it runs on the Neural Engine, and the models that beat it on paper are either
multiples of its size or off the machine entirely. Do not take v3 unless we want
other languages, and if we ever take a cloud path, it belongs behind an explicit
opt-in for users who know their audio is hard — never a default, never silent.

The accuracy worth chasing is in cleanup and custom vocabulary, which is where our
errors actually are.

[oasr]: https://huggingface.co/spaces/hf-audio/open_asr_leaderboard
[openwhispr]: https://openwhispr.com/blog/parakeet-vs-whisper-vs-nemotron
[v3]: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
[northflank]: https://northflank.com/blog/best-open-source-speech-to-text-stt-model-in-2026-benchmarks
[soniqo]: https://soniqo.audio/guides/parakeet
[mtp]: https://www.marktechpost.com/2026/07/23/best-open-speech-recognition-asr-models-in-2026-wer-languages-latency-and-license-compared/
[coval]: https://www.coval.ai/blog/best-speech-to-text-providers-in-2026-independent-benchmarks-and-how-to-choose/
[futureagi]: https://futureagi.com/blog/speech-to-text-apis-in-2026-benchmarks-pricing-developer-s-decision-guide/
