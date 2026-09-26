# FluidAudio: parakeet-unified on CoreML and vocabulary boosting

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

## FluidAudio Research Report: Parakeet Unified + Custom Vocabulary

**Sources**: FluidAudio v0.17.4 (github.com/FluidInference/FluidAudio, Apache-2.0, latest as of 2026-09-25), its `Documentation/`, source under `Sources/FluidAudio/ASR/`, HuggingFace API (`?blobs=true`) for exact file sizes, and closed GitHub issues #851, #828, #702, #724, #961.

### 1. Models — yes, parakeet-unified-en-0.6b is supported

Two separate families exist. `AsrModelVersion` (`Sources/FluidAudio/ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift`) covers pure-TDT batch models: `.v2`, `.v3`, `.redux`, `.ultra`, `.tdtCtc110m`, `.tdtJa`. Separately, **`UnifiedAsrManager`/`StreamingUnifiedAsrManager`** (`Sources/FluidAudio/ASR/Parakeet/Unified/`) load exactly your current model: HF repo **`FluidInference/parakeet-unified-en-0.6b-coreml`** (base model `nvidia/parakeet-unified-en-0.6b`, license `cc-by-4.0`), selected via `UnifiedEncoderPrecision`: `.int8` (default) or `.fp16`.

Sizes (HF API, weight.bin only): offline int8 encoder `parakeet_unified_encoder_int8.mlmodelc` **595.05 MB** (fp16: 1186.70 MB); decoder **14.43 MB**; joint-decision **3.45 MB**; vocab.json 20 KB → ≈613 MB total for a batch int8 integration. Streaming ships one int8 encoder per latency tier (320/640/1120/2080 ms, files suffixed `70_2_2`/`70_7_1`/`70_7_7`/`70_13_13`), each **589–591 MB** — only the tier you select downloads.

Compute units: `UnifiedAsrManager.loadModels` forces the int8 encoder to `.cpuAndNeuralEngine` (never `.all`, because CoreML routes quantized ops to MPSGraph which aborts its MLIR pass); decoder/joint always run CPU-only. **Unverified**: no published first-compile-time number for this int8 encoder — only Redux's 2-bit ternary encoder is documented with "several-minute first ANE compile" (`Documentation/ASR/ParakeetRedux.md`).

### 2. Vocabulary boosting

Confirmed working on the Unified path via issue #851 (a user asked this exact question; fixed by PR #898, commit `07c8903b`). It's CTC keyword-spotting + rescoring (NeMo arXiv:2406.07096), not decoder biasing: a separate CTC model runs alongside Unified and overwrites Unified's words when acoustic evidence favors a vocabulary term. Default variant `.ctc110m` → HF `FluidInference/parakeet-ctc-110m-coreml`, **~101 MB** (AudioEncoder 100.78 MB + MelSpectrogram 0.57 MB + tokenizer). A `.ctc06b` variant exists (~597 MB int8) but its HF README license field is blank (`[More Information Needed]`) — avoid until confirmed.

```swift
// Once at startup
let unified = UnifiedAsrManager()                    // .int8 by default
try await unified.loadModels()
let ctcModels = try await CtcModels.downloadAndLoad() // .ctc110m, ~101 MB

// Per dictation — cheap: only re-tokenizes text, no CoreML recompile
let vocabulary = CustomVocabularyContext(terms: [
    CustomVocabularyTerm(text: "wisprflow"),
    CustomVocabularyTerm(text: "Zentryx", aliases: ["Zen Tricks"]),
    CustomVocabularyTerm(text: "kubectl"),
])
try await unified.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctcModels)

let text = try await unified.transcribe(samples)      // [Float], 16 kHz mono
```

Types (`CustomVocabularyContext.swift`): `CustomVocabularyTerm(text:weight:aliases:tokenIds:ctcTokenIds:minSimilarity:)`. Aliases are alternate spellings/phonetics matched by string similarity; the canonical `text` is what gets emitted. No hard max-terms cap in code; docs recommend 1–50 "excellent," tested to 230 (`Documentation/ASR/CustomVocabulary.md`). Until PR #898, plain `CustomVocabularyTerm(text:)` silently no-op'd on **every** engine — confirm you're past that fix (0.17.4 is). Short terms like your screen-scraped acronyms risk false-positive replacement of ordinary words (issues #702, #724); opt-in `spotterRescueMinSimilarity`/`shortTermCbwTaperPivot`/`spotterRescueEnabled=false` mitigate this, off by default. The only accuracy figure published is 99.4% "Dict Recall" on an internal DP-algorithm benchmark, not a public earnings-call table.

### 3. ITN

Bundled via `TextNormalizer` (Rust `text-processing-rs`), opt-out only at **build time** via SPM trait (needs Swift 6.2/Xcode 26+) — not per-call. For v2/v3/Ultra/Redux/TDT-CTC-110M (spoken-form output), per-call control is free: just choose whether to call `TextNormalizer.shared.normalize(result:)`. **Unified is different and important for you**: source comments (`VocabularyBoostingSession.swift`) state Unified's decoder itself already emits written-form numbers ("11.4 billion", "35.3%") as trained behavior, separate from `TextNormalizer`. **Unverified/flag**: I found no documented toggle to force pure spoken-form output from Unified — test this directly before assuming users can choose digits-vs-words with this model.

### 4. Punctuation/casing

Yes, natively. HF card: "Punctuation & capitalization: yes"; `Documentation/Models.md` comparison table shows TDT v3 = "no" vs Unified = "yes" — this is the main reason to switch off transcribe.cpp/TDT.

### 5. Latency (M-series, `Documentation/Benchmarks.md`, LibriSpeech test-clean 2620 files, int8)

Batch: 130.0× median / 143.6× overall RTFx. Streaming (2080 ms default): 66.2×/65.9×. Streaming tiers (150-file sweep): 320 ms→10×, 640 ms→27×, 1120 ms→33×, 2080 ms→54×. No peak-memory figure published for Unified specifically.

### 6. License / OS / issues

SDK Apache-2.0; Unified/v3/CTC-110M models CC-BY-4.0; CTC-0.6B license unstated. Min macOS 14/iOS 17 (`Package.swift`); no higher floor documented for Unified. Known issues: **#828** — int8 Unified streaming encoder fails to load on *any* compute unit on A16 iPhones (fp16 fixes it); explicitly does not reproduce on M-series per that report, so low risk for a Mac app. **#961** — a crash in candidate evaluation above ~1700-word transcripts, now fixed.

### 7. Other apps

VoiceInk (`Beingpax/VoiceInk`) integrates FluidAudio broadly, including `FluidAudioUnifiedStreamingProvider.swift`, but a GitHub code search found no `CustomVocabularyContext`/`configureVocabularyBoosting` references there — no evidence it uses FluidAudio's native boosting. Hex's public variants appear Rust-based, not FluidAudio. Spokenly has no public source. The clearest real integration is a research project, `moona3k/macparakeet` (`Sources/MacParakeetCore/STT/CustomVocabularyBoosting.swift`), tuning `minSimilarity: 0.65` (kept OOV recall ~74% at +0.1pt WER) and `termWeight: 10.0` against this exact API.
