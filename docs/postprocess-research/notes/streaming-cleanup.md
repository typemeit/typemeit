# Incremental clean-up while the user speaks

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

# Incremental streaming ASR + background LLM cleanup for a hold-to-talk dictation app

## 1. transcribe.cpp streaming API (parakeet-unified-en-0.6b)

Confirmed from `include/transcribe.h` and `docs/models/parakeet-unified-en-0.6b.md` in [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) (checked 2026-09-25). Only `parakeet-unified-en-0.6b` streams; other Parakeet variants are offline-only.

- **Architecture**: buffered/chunked-limited attention (`chunked_limited_with_rc`), not cache-aware. Fixed left context `L=70` encoder frames (5.6s) plus a trained `(chunk, right)` menu at 80ms/frame: `chunk∈{1,2,7,13}`, `right∈{0,1,2,3,4,7,13}`. Six published `(L,C,R)` tuples; lookahead = `chunk+right`: 80ms (WER 5.76%, "accuracy collapses"), 160ms (1.90%), 320ms (1.64%), 480ms (1.55%), 1.12s (1.40%), default 2.08s (1.44%, best). Set via `struct transcribe_parakeet_buffered_stream_ext{left_ms,chunk_ms,right_ms}` on `transcribe_stream_params::family`, or CLI `--stream-buf-{left,chunk,right}-ms`.
- **Lifecycle**: `transcribe_stream_begin()` → repeated `transcribe_stream_feed(session, pcm f32/16kHz, n_samples, &update)` → `transcribe_stream_finalize(session, &update)`. Feed runs a variable-stride loop (step 0 consumes `chunk+right`; steady state consumes `chunk`); finalize flushes the retained right slot and pads `R` frames of silence so trailing tokens get their trained lookahead — a documented, deliberate divergence from the NeMo reference on the final frames.
- **Text/revision model**: `transcribe_stream_get_text()` returns `full_text` (raw, can change anywhere), `committed_text` (append-only, never rewritten once exposed), `tentative_text` (volatile suffix). `transcribe_stream_commit_policy` = `ON_FINALIZE` (nothing committed until the stream ends) or `STABLE_PREFIX` (commit once `stable_prefix_agreement_n` consecutive hypotheses agree, default 3). The header is explicit: committed text is "best-effort, not a correctness guarantee."
- **Offline vs. streaming**: they do differ — full attention offline vs. masked chunked attention streaming, plus the intentional finalize-padding divergence. Streaming-vs-NeMo's-own-streaming-reference is within 0.00–0.02pp for the four longer tuples. I could **not** verify an exact same-audio offline-vs-streaming WER delta: the offline WER (1.60% Q8_0) is measured on the full 2,620-utterance test-clean set, the streaming table on a 512-utterance subset — flagged as unverified.

## 2. Proposed design

Run `stream_feed` continuously while the key is held (feed mic chunks every 100–320ms), at `(70,7,7)` or `(70,2,4)` — near-offline accuracy at 1.12s/480ms lookahead, unlike the noisier 160ms tuple.

**Commit rule**: a sentence is locked for cleanup once (a) `STABLE_PREFIX` `committed_text` passes a sentence-ending punctuation mark the model itself emits, **and** (b) a short wall-clock debounce elapses with no correction-cue words ("no wait," "scratch that," "I mean") in the following tentative text — mirroring FluidAudio's Parakeet-EOU debounce (~1.28s) and the trigger-phrase detectors indie tools ("Quoth", "Dictate") use for spoken self-corrections. This debounce is what stops "send it to John — no wait, Sarah" from committing as two independently-cleaned fragments.

**What runs when**: each commit fires an async, sentence-scoped LLM cleanup call with prior *cleaned* sentences passed as read-only context (for referent/terminology consistency), cached on completion. At key-up: `stream_finalize`, clean only the still-uncommitted tail, concatenate with cached results. A single-sentence dictation (nothing ever committed) degrades gracefully to today's whole-buffer behavior.

## 3. Prior art (mostly unverified internals)

- **Wispr Flow**: publishes a <700ms post-speech target (<200ms ASR + <200ms fine-tuned-Llama formatting + <200ms network) and per-user personalization learned from accepted edits, but no public detail on whether cleanup itself runs incrementally mid-utterance ([wisprflow.ai](https://wisprflow.ai/post/technical-challenges)) — unverified for this design.
- **Aqua Voice** markets a "Streaming Mode" (max context, cleans as you talk) vs. "Instant Mode" (lowest latency) but publishes no commit-point mechanics ([aquavoice.com](https://aquavoice.com/)) — unverified.
- **Superwhisper** ships on-device realtime Parakeet streaming for live feedback, no published cleanup architecture ([superwhisper.com](https://superwhisper.com/docs/common-issues/realtime)) — unverified.
- **Apple Dictation / Gboard**: no engineering write-ups found on sentence-commit logic. Gboard's on-device recognizer is a single 85MB end-to-end net; Google hasn't published segmentation details.
- **Self-correction handling**: AssemblyAI's Dictation API and indie tools resolve to what the speaker landed on, dropping the replaced span, biased toward "do nothing over wrong deletions." Qwen-Audio-3.0-ASR instead folds correction/filler-removal into the *same decode pass* as recognition rather than a second LLM stage — a different architecture, not directly portable here.

## 4. Segmentation/EOU research

NVIDIA's `parakeet_realtime_eou_120m-v1` (wrapped by [FluidAudio](https://github.com/FluidInference/FluidAudio)) emits a literal `<EOU>` token rather than using a separate head; latency on synthetic (TTS+silence) audio is p50 160ms/p90 280ms/p95 320ms. Important distinction: it detects end of a whole conversational *turn* for voice-agent handoff, not sentence boundaries inside continuous dictation — wrong tool to call directly, though its debounce approach is reusable. Streaming punctuation-restoration work (arXiv 2606.05179) hits 0.937 macro-F1 with only K=2 subword-tokens of lookahead, beating a full-context fine-tuned ELECTRA baseline (0.913) — sentence-ending punctuation doesn't need much future context, supporting committing soon after a period appears. "Toward Interactive Dictation" (arXiv 2307.04008, TERTiUS) shows a stark accuracy/latency curve for classifying speech-as-command vs. dictation (~30% at 1.3s vs. ~55% at 7s) — a caution that a cheap correction-detector will miss real corrections.

## 5. Latency estimate

Using the given 0.5s + 14ms/token (~1.3 tokens/word, ~2.5 words/s speech): a **p50** 5s/~12-word dictation is almost certainly one sentence with no early commit point — **no benefit**, same ~0.7s as today. A **p95** 35s/~88-word, ~6-sentence dictation today pays cleanup on the whole transcript (2–6s per the prompt's own numbers); incrementally only the last sentence (~20 tokens) needs cleanup at key-up: 0.5+0.014×20 ≈ **0.78s**, independent of total length — a 3–8x cut for long dictations, turning length-scaling tail latency into a near-constant ~0.7–0.9s. Note ASR compute itself is not the bottleneck: transcribe.cpp's own Metal benchmarks decode a 35s clip offline in 155ms (200x+ realtime), so streaming ASR's value here is producing early sentence boundaries, not speeding up transcription.

## 6. Risks

Corrections without a recognizable cue phrase won't be caught by debounce+trigger-word detection. `committed_text` is explicitly best-effort in transcribe.cpp, not guaranteed stable, so an irreversible cleanup commit inherits that risk. Running LLM cleanup concurrently with live streaming-ASR compute on the same accelerator is a real contention risk the library doesn't arbitrate (it only serializes concurrent *ASR* runs per model). N sentences means N separate 0.5s fixed LLM overheads instead of one; fine if hidden in speaking time, but rapid short-fragment speech could make the cleanup queue fall behind key-up and should degrade to the final flush rather than block.

Sources:
- [transcribe.cpp README](https://github.com/handy-computer/transcribe.cpp/blob/main/README.md)
- [docs/models/parakeet-unified-en-0.6b.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-unified-en-0.6b.md)
- [docs/models/parakeet.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md)
- [include/transcribe.h](https://github.com/handy-computer/transcribe.cpp/blob/main/include/transcribe.h)
- [PR #145 — buffered-stream tail-loss fix](https://github.com/handy-computer/transcribe.cpp/pull/145)
- [Wispr Flow — technical challenges](https://wisprflow.ai/post/technical-challenges)
- [Aqua Voice](https://aquavoice.com/) / [llms.txt](https://aquavoice.com/llms.txt)
- [Superwhisper realtime docs](https://superwhisper.com/docs/common-issues/realtime)
- [FluidAudio](https://github.com/FluidInference/FluidAudio) / [Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [nvidia/parakeet_realtime_eou_120m-v1 (Hugging Face)](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1)
- [Efficient Punctuation Restoration via Weighted Lookahead Scoring (arXiv 2606.05179)](https://arxiv.org/abs/2606.05179)
- [Light-weight punctuation/casing for on-device streaming ASR (arXiv 2407.13142)](https://arxiv.org/abs/2407.13142)
- [Toward Interactive Dictation / TERTiUS (arXiv 2307.04008)](https://arxiv.org/pdf/2307.04008)
- [AssemblyAI Dictation API](https://www.assemblyai.com/blog/dictation-api)
- [Quoth — self-correction parser issue](https://github.com/ryan-stoffel/quoth/issues/26)
