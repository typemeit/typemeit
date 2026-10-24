# parakeet-unified-en-0.6b and transcribe.cpp

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

# Research: nvidia/parakeet-unified-en-0.6b and transcribe.cpp

## Section 1: The model — `nvidia/parakeet-unified-en-0.6b`

**Identity / release**
- Model exists and is published by NVIDIA at https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- Release date per the model card's own "Release Date" field: **04/07/2026** ("Hugging Face [04/07/2026] via https://huggingface.co/nvidia/parakeet-unified-en-0.6b") — source: raw README, https://huggingface.co/nvidia/parakeet-unified-en-0.6b/raw/main/README.md
- HF repo metadata confirms `createdAt: 2026-04-07T03:32:04.000Z`, `lastModified: 2026-06-09T07:18:04.000Z`, 1,530 downloads / 63 likes at the time of this research (a snapshot, not a stable fact) — source: `https://huggingface.co/api/models/nvidia/parakeet-unified-en-0.6b`
- License: **NVIDIA Open Model License Agreement** (not CC-BY-4.0) — https://huggingface.co/nvidia/parakeet-unified-en-0.6b (README "License/Terms of Use")
- Underlying research paper: Andrusenko, Bataev, Grigoryan, Tadevosyan, Lavrukhin, Ginsburg, "Reducing the Offline-Streaming Gap for Unified ASR Transducer with Consistency Regularization," submitted 2026-04-21 — https://arxiv.org/abs/2604.19079

**Architecture, and how it differs from v2 / v3**
- Architecture Type: **"Unified-FastConformer-RNNT"** — FastConformer encoder, 24 layers, **RNNT (not TDT) decoder**, 600M parameters per NVIDIA's card (transcribe.cpp's own catalog lists a more precise **618M**, see runtime section) — https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- "Unified" here means **one model does both offline and streaming inference** — not ASR+PnC+LangID+timestamps fused, and not multilingual/code-switching. Quote: "You need to utilize only one unified model for both offline and streaming inference with a minimum latency of 160ms... All the model parameters are shared between offline and streaming modes (encoder, predictor, and joint networks)." Training uses chunked self-attention masks + Dynamic Chunked Convolutions + a novel "mode-consistency regularization loss." — same URL
- **Important disambiguation**: NVIDIA/NGC's Riva product line separately ships models literally named "RIVA Parakeet-CTC-XL-0.6B-Unified ASR Mandarin-English / Spanish-English" (CTC architecture, multilingual code-switching) — https://catalog.ngc.nvidia.com/orgs/nvidia/riva/models/parakeet-ctc-riva-0-6b-unified-zh-cn/-. This is a **different, older, unrelated use of "unified"** (multilingual code-switch, not offline+streaming) and a different product line (Riva/CTC) from the HF model in question. Do not conflate them.
- vs **parakeet-tdt-0.6b-v2**: FastConformer‑**TDT** decoder (not RNNT), 600M params, offline-only (no native streaming), released **05/01/2025**, CC-BY-4.0 — https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/raw/main/README.md. NVIDIA's own comparison table on the unified model's card shows v2's WER collapsing outside offline use (offline 6.04% → 1.12s latency 22.83% → 0.56s 69.55%) because it wasn't trained for streaming — https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- vs **parakeet-tdt-0.6b-v3**: FastConformer‑TDT decoder, 600M params, extends v2 to **25 European languages with auto language-ID**, SentencePiece tokenizer with 8,192 vocab tokens, released HF **08/14/2025** (NVIDIA's own blog dates the announcement 2025-08-15), CC-BY-4.0 — https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/raw/main/README.md and https://blogs.nvidia.com/blog/speech-ai-dataset-models/
- So parakeet-unified-en-0.6b is **not** a successor to v3 — it's a parallel branch off the same v2 base: v3's axis of improvement is language coverage (TDT, multilingual); the unified model's axis is offline/streaming unification (RNNT, English-only). NVIDIA staff (aandrusenko) confirmed in the unified model's HF discussion thread (Apr 2026) they "plan to expand this unified training approach to a multilingual setup" but "can't provide a reliable timeline" — i.e., a multilingual unified model did not exist as of that discussion — https://huggingface.co/nvidia/parakeet-unified-en-0.6b/discussions/2
- I could **not find** a NGC catalog or build.nvidia.com/NIM listing for `parakeet-unified-en-0.6b` specifically (only found the unrelated Riva "Unified" CTC models, and a NIM page for v2). It appears to be Hugging-Face-only at present — flagging as "not found," not confirmed absent.

**Punctuation & Capitalization (PnC)**
- Yes, native/baked-in: "Built-in support for punctuation and capitalization in output text"; output described as transcribing "punctuation and capitalization." — https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- v2 and v3 also natively emit PnC (same family trait) — same READMEs as above.

**Inverse Text Normalization (ITN)**
- The **model itself is not documented as performing ITN**. The only ITN mention on the card is at the pipeline level: NeMo's `PipelineBuilder`/`buffered_rnnt.yaml` config "build[s] end-to-end workflows with punctuation and capitalization (PnC), inverse text normalization (ITN), and translation support" — i.e., ITN is described as a separate NeMo pipeline stage wrapped around the transducer, not a property of the acoustic/decoder model's own output. — https://huggingface.co/nvidia/parakeet-unified-en-0.6b
- Zero mentions of "ITN" or "inverse text normalization" anywhere in the raw v2 or v3 READMEs (verified by direct text search of the fetched raw markdown) — https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2/raw/main/README.md, https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/raw/main/README.md

**Word boosting / context biasing / custom vocabulary**
- Not mentioned anywhere on the parakeet-unified-en-0.6b model card itself.
- NeMo (the framework) has a general-purpose feature for this called **GPU-PB** (GPU-accelerated Phrase-Boosting), documented as supporting **CTC, RNN-T/TDT, and AED (Canary)** models generically, applied at decode time via shallow fusion with no retraining, using a boosting tree built from a user-supplied phrase list — https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/asr_customization/word_boosting.html. That doc names `parakeet-tdt-0.6b-v2` as an example of a model needing capitalized boost-phrase variants, but names **no other Parakeet variant**, and does not mention `parakeet-unified-en-0.6b`.
- Underlying papers: "TurboBias: Universal ASR Context-Biasing powered by GPU-accelerated Phrase-Boosting Tree," https://arxiv.org/abs/2508.07014, and "TurboBias 2.0: Streaming Context-Biasing for Production-Efficient ASR Systems" (submitted 2026-08-21), which explicitly covers "Transducer-based ASR systems" and streaming — https://arxiv.org/abs/2608.21343. Neither abstract names parakeet-unified-en-0.6b.
- Real-world GitHub trail (repo `NVIDIA-NeMo/Speech`, the current location of what was `NVIDIA/NeMo` — old `NVIDIA-NeMo/NeMo` URLs 301-redirect there, confirmed via `api.github.com/repositories/200722670`):
  - Issue **#14500**, "Phrase-boosting feature for Parakeet v2" (opened 2025-08-18, closed 2025-09-26, 12 comments): reporter found boosting "only worked with AED decoding (Canary-1b)" for `parakeet-tdt-0.6b-v2`, with WER regressing as `boosting_tree_alpha` increased (12.06%→22.61% at alpha=2.0). NVIDIA engineer `andrusenkoau` clarified the real cause was capitalization/token mismatch (v2 predicts capitalized tokens, so boost phrases must include capitalized variants) and confirmed the feature works on `parakeet-tdt-1.1b` — https://github.com/NVIDIA-NeMo/Speech/issues/14500
  - Issue **#14943**, "Context biasing for pure transducer models" (opened 2025-10-16, closed 2025-11-19): NVIDIA's `andrusenkoau` confirmed on 2025-10-28, "the Context-biasing method is supported for TDT and Transducer models too," linking the GPU-PB doc — https://github.com/NVIDIA-NeMo/Speech/issues/14943
  - **Net finding**: by late Oct 2025, GPU-PB context biasing is confirmed by NVIDIA to work with TDT/RNNT Parakeet models generally (with capitalization caveats), which predates the April 2026 unified-model release. Since parakeet-unified-en-0.6b uses an RNNT decoder head (same general family), it is plausible this extends to it — **but I found no source that names or tests parakeet-unified-en-0.6b specifically with GPU-PB**. Treat as unverified for this exact model.
  - This is a NeMo/Python framework feature (decode-time, driven from Python), separate from the released model weights — and, per the runtime section below, it does **not** carry into transcribe.cpp.

**Model size / download size**
- Params: 600M (NVIDIA's rounded figure) — https://huggingface.co/nvidia/parakeet-unified-en-0.6b; transcribe.cpp's catalog gives a more precise **618M** — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md
- Official fp32 `.nemo` checkpoint size, measured directly via HTTP HEAD against the HF resolve URL: **2,474,055,680 bytes (≈2.47 GB / 2.30 GiB)** — `https://huggingface.co/nvidia/parakeet-unified-en-0.6b/resolve/main/parakeet-unified-en-0.6b.nemo` (measured by me directly, 2026-09-25)
- Community GGUF conversions (by `handy-computer`, not NVIDIA-official), hosted at https://huggingface.co/handy-computer/parakeet-unified-en-0.6b-gguf: F32 2.47 GB, F16 1.24 GB, Q8_0 731 MB, Q6_K 602 MB, Q5_K_M 541 MB, Q4_K_M 477 MB — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-unified-en-0.6b.md

**Latency / accuracy (WER) numbers**
- NVIDIA's own WER table (HF Open ASR Leaderboard datasets, greedy RNNT, no external LM), from the model card's YAML + body table:
  - Offline **5.91%**; by streaming latency: 2.08s **6.14%**, 1.12s **6.29%**, 0.56s **6.52%**, 0.40s **6.70%**, 0.32s **6.92%**, 0.24s **7.35%**, 0.16s **8.44%**, 0.08s **15.63%** (degenerate — card states "the unified model start[s] to degrade because of the ansence [sic] of enough right context" below 240ms) — https://huggingface.co/nvidia/parakeet-unified-en-0.6b
  - Per-dataset offline WER: AMI 10.14%, Earnings22 11.16%, Gigaspeech 10.05%, LibriSpeech test-clean **1.63%**, LibriSpeech test-other 3.11%, SPGI Speech 2.04%, TEDLIUM 3.39%, VoxPopuli 5.77% — same source
  - Comparison baselines on the same card: `parakeet-tdt-0.6b-v2` (offline 6.04, collapses at streaming latencies) and `nemotron-speech-streaming-en-0.6b` (a separate NVIDIA streaming-only model, better than unified only below 160ms) — same source
- **Test hardware NVIDIA published these numbers on**: NVIDIA V100, A100, A6000, DGX Spark; runtime engine NeMo 2.7.3; supported microarchitectures Ampere/Blackwell/Hopper/Volta; OS: **Linux only**. — https://huggingface.co/nvidia/parakeet-unified-en-0.6b. **NVIDIA publishes no CPU, Apple Silicon, ANE, or Metal numbers for this model anywhere I could find.**
- The only Apple Silicon/Metal numbers that exist come from the independent transcribe.cpp port (see runtime section) — same figures apply to this exact model.
- transcribe.cpp's own accuracy validation of its GGUF port vs. NVIDIA's number: F32 GGUF WER on full LibriSpeech test-clean (2,620 utterances) = **1.59%** vs. NVIDIA's self-reported **1.63%** on the same split; FLEURS-en (Q8_0): 3.99% WER — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-unified-en-0.6b.md
- transcribe.cpp also published a streaming-mode WER parity table (vs. the NeMo reference implementation) across all six supported latency configs on LibriSpeech test-clean-512; 5 of 6 configs land within 0.02 percentage points of NeMo, the 80ms zero-lookahead config is an outlier in both implementations — same source.

## Section 2: The runtime — `transcribe.cpp`

**Identity, maintainer, current state**
- Repository: https://github.com/handy-computer/transcribe.cpp — "ggml speech-to-text inference for 16+ model families." Description: "C/C++ speech-to-text inference library. Runs diverse STT model families via GGUF models on the ggml runtime, with Metal, Vulkan, and CUDA backends for fast GPU inference plus a tinyBLAS-accelerated CPU path." — README, same URL
- Maintained by the GitHub org **`handy-computer`** (type: "Organization"); no individual maintainer named in the README. GGUF weights are published under https://huggingface.co/handy-computer.
- License: **MIT** — confirmed via GitHub API license field and README's License section, https://github.com/handy-computer/transcribe.cpp
- Live stats as of 2026-09-25 (via `api.github.com/repos/handy-computer/transcribe.cpp`): **1,959 stars**, **106 forks**, 35 open issues, 12 subscribers; repo `created_at: 2026-04-07T10:23:34Z`; last push `2026-09-25T09:48:06Z` (same day as this research — actively maintained).
- Note: the repo's creation date (2026-04-07) coincides with parakeet-unified-en-0.6b's HF release date (2026-04-07). I found no source establishing any causal link — flagging as an observed coincidence only, not a confirmed relationship.
- Credited sponsors (per README): Mozilla AI's BiR Program (initial research funding), Hugging Face (model storage), Modal (GPU credits for WER validation), Blacksmith (CI runners).
- Similarly-named but **different, unrelated** projects exist and could cause confusion: `mudler/parakeet.cpp` (+ forks `robertbak/parakeet.cpp`, `happy-prime-inc/parakeet.cpp`) is a separate ggml-based Parakeet C++ implementation with its own C-API for dlopen/FFI/LocalAI; `Frikallo/parakeet.cpp` is another distinct on-device C++ implementation (MPS+Unified Memory via "Axiom"); `skorokithakis/transcribe.cpp-server` is a thin HTTP server wrapper *around* `handy-computer/transcribe.cpp`, not the runtime itself. I did not deep-research these since the task named "transcribe.cpp" specifically, which matches `handy-computer/transcribe.cpp`.

**Does it support parakeet-unified-en-0.6b specifically, or only tdt-v2/v3?**
- **Yes, explicitly supported** — not limited to v2/v3. The main README's "Parakeet" family row lists `parakeet-unified-en-0.6b` alongside `parakeet-ctc-0.6b/1.1b`, `parakeet-primeline`, `parakeet-rnnt-0.6b/1.1b`, `parakeet-tdt-0.6b-v2`, `parakeet-tdt-0.6b-v3`, `parakeet-tdt-1.1b`, `parakeet-tdt_ctc-1.1b/110m` (11 variants total) — https://github.com/handy-computer/transcribe.cpp
- Has its own dedicated doc, pinned to upstream commit `d4ac992` (2026-05-10), validated against the NeMo reference at transcribe.cpp commit `42528dd` on 2026-05-10 — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-unified-en-0.6b.md
- It is in fact the **only** Parakeet variant in transcribe.cpp with streaming support: "Buffered streaming is supported on `parakeet-unified-en-0.6b` across all six published (L, C, R) configurations... Other Parakeet variants run offline only." — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet.md

**Context biasing / hotwords / custom vocabulary**
- **Not exposed anywhere in transcribe.cpp**, for Parakeet or otherwise except one Whisper-only exception. Verified directly against the public C API header (`include/transcribe.h`): the library's only decode-time "biasing" feature is capability flag `TRANSCRIBE_FEATURE_INITIAL_PROMPT` ("The model accepts a free-text or token prompt to bias decoding"), and the header states explicitly: **"Today: whisper only; reached via `transcribe_whisper_run_ext`."** No Parakeet variant exposes this or any other hotword/context-biasing/custom-vocabulary mechanism. — https://github.com/handy-computer/transcribe.cpp/blob/main/include/transcribe.h (lines ~1306–1311 of the fetched raw file)
- Corroborated by absence: neither the per-model doc, the family doc, nor the deep architecture/porting doc (`docs/porting/families/parakeet.md`) mention hotwords, boosting, or custom vocabulary; the only "bias" hits anywhere in the porting doc are neural-network bias *tensors* (linear/conv layer biases), unrelated to word-level biasing — verified by direct grep of all three documents.

**Punctuation on/off toggle, or any control over PnC behavior**
- The C API does define a generic toggle: `transcribe_run_params::pnc` (enum `transcribe_pnc_mode`: DEFAULT/OFF/ON), gated by `transcribe_model_supports(model, TRANSCRIBE_FEATURE_PNC)`.
- But the header **explicitly excludes Parakeet**: "Each family that exposes a runtime PNC toggle reads this field; families that do not (**whisper, parakeet, ...**) ignore it." A non-DEFAULT value against Parakeet triggers a WARN-level log and "proceeds with the model's default behavior" — i.e., **no working punctuation toggle exists for parakeet-unified-en-0.6b or any Parakeet variant; PnC is always emitted, baked into the model.** — https://github.com/handy-computer/transcribe.cpp/blob/main/include/transcribe.h
- Consistent with the family's own smoke-test table, which checks `unified-en-0.6b` output for "English with PnC" as a fixed pass criterion, not a togglable one — https://github.com/handy-computer/transcribe.cpp/blob/main/docs/porting/families/parakeet.md
- The header defines a parallel `itn` toggle / `TRANSCRIBE_FEATURE_ITN` flag ("Same 'can-control vs does-emit' distinction as PNC"), but — unlike PNC — **does not explicitly list which families honor or ignore it**, and no Parakeet doc mentions ITN at all (verified: zero case-insensitive hits for "itn" in either the family doc or the parakeet-unified-en-0.6b doc). I could not determine, from available primary sources, whether the ITN toggle does anything for Parakeet in transcribe.cpp — flagging as unverified rather than assuming either way.

**Latency benchmarks quoted (Apple Silicon/Metal)**
- These live in the per-model doc, not the main README (confirmed by direct read — the README contains no inline benchmark numbers; it describes a `catalog/`-driven generation pipeline instead). For `parakeet-unified-en-0.6b`, on **Apple M4 Max**, backend **Metal** ("compute latency = mel + encode + decode," mean of 3 runs after 1 warmup, profile `asr-publication-v2`):
  - jfk.wav (11.0s): Q8_0 **59 ms (187.72× realtime)**, Q4_K_M 60 ms (183.34×)
  - dots sample (35.3s): Q8_0 **155 ms (228.39×)**, Q4_K_M 161 ms (219.30×)
  - CPU-only path, same machine: jfk Q8_0 285 ms (38.55×); dots Q8_0 979 ms (36.09×)
  - Measured at transcribe.cpp commit `77b0c93` on 2026-09-14; reproducible via `uv run scripts/bench/run.py --profile --models parakeet-unified-en-0.6b`
  - Source: https://github.com/handy-computer/transcribe.cpp/blob/main/docs/models/parakeet-unified-en-0.6b.md
  - (Non-Apple, for context) AMD Ryzen 7 PRO 4750U, Vulkan: jfk 448 ms (24.55×), dots 1.36 s (26.01×) — same source

**Platform/build support relevant to a macOS app**
- "Metal is enabled automatically on Apple Silicon" via plain `cmake -B build && cmake --build build`; also supports Vulkan (Linux/Windows), CUDA, HIP/ROCm (AMD, ROCm ≥6.1), and a CPU path with optional OpenBLAS (~10–15× decode speedup) plus tinyBLAS (`llamafile_sgemm`) on by default — https://github.com/handy-computer/transcribe.cpp
- Official bindings include **Swift/ObjC** (`bindings/swift`), plus Python, TypeScript/JavaScript, and Rust — same source

## Flags / things I could not verify
- No NVIDIA-published latency numbers on CPU, Apple Silicon, ANE, or Metal for parakeet-unified-en-0.6b (or v2/v3) exist in any source I found — only transcribe.cpp's independent community benchmarks cover Apple Silicon.
- No NGC catalog / NIM listing found for `parakeet-unified-en-0.6b` itself.
- Whether NeMo's GPU-PB context-biasing has been specifically tested/confirmed against `parakeet-unified-en-0.6b` (as opposed to `parakeet-tdt-0.6b-v2`/`-1.1b` generically) — not found; treat as untested/unknown, not confirmed either way.
- Whether transcribe.cpp's `itn` runtime toggle does anything for any Parakeet variant — the header is silent on this specific family, unlike its explicit statement for PNC.
- I did not deep-dive `mudler/parakeet.cpp`, `Frikallo/parakeet.cpp`, or `skorokithakis/transcribe.cpp-server` since they are distinct projects from the one the task named; flagging their existence only to prevent conflation in the final report.
