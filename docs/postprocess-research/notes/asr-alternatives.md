# Speech recognition alternatives to Parakeet

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

## Speech-to-text options for on-device dictation with clean-up (research, Sept 2026)

### 1. Apple SpeechAnalyzer / SpeechTranscriber / DictationTranscriber (macOS 26+)
Verified live against developer.apple.com today.

- Two modules with **different models**: `SpeechTranscriber` (new model, general/long-form) vs `DictationTranscriber`, which the WWDC25 transcript states verbatim "supports the same languages, speech-to-text model, and devices as iOS 10's on-device SFSpeechRecognizer" — i.e. the *old* model. [SpeechTranscriber](https://developer.apple.com/documentation/speech/speechtranscriber) · [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber) · [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/)
- **Custom vocabulary exists only on `DictationTranscriber`** (the older model): `AnalysisContext.contextualStrings` — soft bias, ~100 short phrases across tags, `setContext` replaces rather than merges — or the heavier `SFSpeechLanguageModel` (offline-compiled custom LM, not suited to per-utterance dynamic terms). `SpeechTranscriber`'s doc page has no "Improve accuracy" section at all. Argmax (WhisperKit's maker) confirms independently: "Apple's new SpeechAnalyzer (iOS 26) API lacks the Custom Vocabulary feature." [source](https://www.argmaxinc.com/blog/apple-and-argmax)
- WER: 2.12% on LibriSpeech-clean vs. Whisper Small 3.74% ([Developers Digest, Jul 2026](https://www.developersdigest.tech/blog/apple-speechanalyzer-vs-whisper-benchmark), blog-level source). On harder Earnings22 audio: SpeechTranscriber 14.0% vs. WhisperKit small.en 12.8% — Whisper wins on jargon ([Argmax, Jun 2025 beta](https://www.argmaxinc.com/blog/apple-and-argmax)). A 13k-sample multi-language test found even Apple's best case needed a manual "Apple Intelligence Proofread" pass to roughly halve technical-jargon error (~20%→~10%) — an LLM cleanup step was still needed ([Dictato, Apr 2026](https://dicta.to/blog/speech-to-text-engine-comparison-mac-2026/)).
- Speed: ~70–90x realtime on M4 Mac mini ([forum](https://developer.apple.com/forums/thread/819555)); "~2x faster than Whisper large-v3-turbo" (repeated across blogs, methodology undisclosed).
- Ships via `AssetInventory`, zero app-bundle impact; exact download size **UNVERIFIED** (not published). ~34–40 locale variants depending on source/date. `.progressiveTranscription` preset gives low-latency streaming partials.
- ITN: **UNVERIFIED** for `SpeechTranscriber` — `TranscriptionOption` has only `.etiquetteReplacements`, nothing for numbers. `DictationTranscriber` inherits system dictation's old fixed rule (spell <10, digits ≥10, not adjustable) per [Apple Community](https://discussions.apple.com/thread/253471039). No distinct WWDC26 Speech session found; live docs serve macOS 27-beta with the same API surface.

### 2–4. On-device models: biasing, ITN, streaming
- **Whisper (whisper.cpp/WhisperKit)**: `initial_prompt` is real but weak/misaligned — it expects prior transcript text, not a keyword list. A true hotword feature request was **closed "not planned."** [GitHub #1979](https://github.com/ggml-org/whisper.cpp/issues/1979). large-v3-turbo: 6–22x realtime on M-series depending on quant/backend ([benchmark](https://justvoice.ai/blog/whisper-benchmark-apple-silicon-m3-m4)). No native ITN. MIT license.
- **NVIDIA Canary-1b-flash**: 1.48% WER LibriSpeech-clean, CC-BY-4.0 ([HF](https://huggingface.co/nvidia/canary-1b-flash)) — no confirmed Mac/CoreML port. **Canary-Qwen-2.5B** (SALM, Qwen3 decoder) tops OpenASR leaderboard at 5.63% WER ([HF](https://huggingface.co/nvidia/canary-qwen-2.5b)) but is LLM-decoder-based; on-device Mac feasibility **UNVERIFIED**.
- **Parakeet boosting outside NeMo/Python is real.** `sherpa-onnx` supports hotwords for NeMo transducer/TDT models via `modified_beam_search` + Aho-Corasick list ([docs](https://k2-fsa.github.io/sherpa/onnx/hotwords/index.html), [PR #3895](https://github.com/k2-fsa/sherpa-onnx/pull/3895)) — C++/Python-first, no idiomatic Swift wrapper. **FluidAudio** (Swift/CoreML, Apache-2.0) is the strongest fit: it benchmarks **parakeet-unified-en** — this app's own model — at 2.15% WER/123x RTFx batch and 2.21% WER/29x RTFx streaming on LibriSpeech-clean, M5 Pro ([Benchmarks.md](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)), plus a genuine `CustomVocabularyTerm` boosting struct (decode-time TDT token bias + CTC keyword spotting, weight/alias/similarity fields) and a bundled NeMo-derived ITN engine, opt-out via SPM trait ([repo](https://github.com/FluidInference/FluidAudio)). Exact boosting call-site confirmed only at field-name level, not verbatim code — **flag for verification**.
- **Moonshine**: not competitive — tiny/base WER 12.66%/10.07% ([HF](https://huggingface.co/UsefulSensors/moonshine-streaming-tiny)); no biasing found.
- **Kyutai STT**: 2.6B model, 6.40% WER, streaming, CC-BY-4.0 ([kyutai.org](https://kyutai.org/stt/)) — worse than Parakeet/Canary; no confirmed Mac port.
- **This app's own stack already streams**: transcribe.cpp confirms buffered streaming on parakeet-unified-en-0.6b via `--stream-buf-left/chunk/right-ms`, 6 published (L,C,R) configs from 160ms lookahead (70,1,1) up to today's 2.08s default (70,13,13) ([parakeet.md](https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md)) — lower latency is a config change away, no model switch needed.

### 5. Cloud (reference only — all need a network round-trip)
- **AssemblyAI Dictation API**: STT+LLM cleanup in one call, p50 134ms, `keyterms_prompt` (100 terms streaming/1,000 pre-recorded), vendor-measured 21% WER cut with context. [product](https://www.assemblyai.com/products/dictation-api)
- **Deepgram Nova-3**: keyterm prompting (100 terms mono/500 tokens multilingual), streaming WER median 6.84%, sub-300ms, `smart_format` does punctuation+ITN together. [docs](https://developers.deepgram.com/docs/keyterm)
- **ElevenLabs Scribe v2**: confirmed shipped (Jan 2026), Realtime <150ms, keyterm prompting (1,000 terms batch/50 realtime); ITN on transcripts **UNVERIFIED**. [launch](https://elevenlabs.io/blog/introducing-scribe-v2)
- **OpenAI gpt-4o-transcribe**: `prompt` param for jargon, but an independent preregistered ablation found **no significant WER improvement** (+0.6pp, p=0.55) ([arXiv Aug 2026](https://arxiv.org/abs/2608.28875)); batch-only, 637ms median/965ms p95 ([benchmark](https://github.com/pipecat-ai/stt-benchmark)); ITN UNVERIFIED.

### Ranked shortlist for a local A/B test
1. **FluidAudio running parakeet-unified-en (Swift/CoreML, on-device)** — same model family as today, so no quality-regression risk; only option combining real vocabulary boosting, native ITN, and streaming, all in Swift. Moderate integration (new dependency, replaces the transcribe.cpp backend).
2. **Apple `SpeechTranscriber`** — best-documented accuracy/speed ceiling, zero integration cost (already in the OS). Zero biasing, so the LLM step for vocabulary stays; worth testing whether its (unverified) ITN shrinks that step.
3. **Apple `DictationTranscriber` + `AnalysisContext.contextualStrings`** — free to try in the same framework; tests whether Apple's own soft, ~100-term biasing helps enough before investing in FluidAudio.

### Minimal Swift for the top pick (FluidAudio)
Verbatim from the repo README ([FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio), SPM `.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")`):

```swift
import FluidAudio

let models = try await AsrModels.downloadAndLoad(version: .ultra)  // select the parakeet-unified-en variant; exact enum case not verified here
let asrManager = AsrManager(config: .default)
try await asrManager.loadModels(models)

let result = try await asrManager.transcribe(samples)  // samples: 16kHz PCM
print(result.text)
```
Vocabulary boosting uses a `CustomVocabularyTerm(text:weight:aliases:tokenIds:ctcTokenIds:minSimilarity:)`-shaped struct — confirm its exact initializer and wiring into `AsrManager`/`config` against `Documentation/ASR/PostProcessing.md` before shipping; that call shape wasn't independently verified here.

---

**Note on process**: one of two research sub-agents I dispatched (covering the on-device model landscape) stalled and returned a non-answer after spawning its own sub-agents; I recovered by redoing that research directly myself with primary sources, which is reflected above. The cloud-API sub-agent completed normally and its sourced findings are included as-is.
