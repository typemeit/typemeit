# Foundation Models adapters and latency levers

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

## Foundation Models for Dictation Cleanup — Research Report

### Critical caveat first

Apple's adapter path is currently **closed to new shipping use**. The only full toolkit release, **v26.0.0**, targets macOS/iOS/iPadOS/visionOS 26 and is explicitly not compatible with 27+ ([developer.apple.com/apple-intelligence/foundation-models-adapter](https://developer.apple.com/apple-intelligence/foundation-models-adapter)). Separately, the Foundation Models Framework Adapter Entitlement request page now reads "We are no longer accepting entitlement requests" — reported first-hand by a competing Mac dictation app (EnviousWispr) that built a working adapter and then couldn't get the entitlement to ship it ([enviouswispr.com/blog/fine-tuning-apple-on-device-model-self-corrections](https://enviouswispr.com/blog/fine-tuning-apple-on-device-model-self-corrections/)). Since macOS 27 "Golden Gate" (new base model **AFM 3 Core**) shipped Sept 14 2026, there is currently no supported way to train or ship an adapter against the current OS — App Store or Developer ID.

### 1. Adapter toolkit (v26.0.0, the only supported version)
- **Hardware**: Apple-silicon Mac with 32GB+ RAM, or a Linux GPU box, Python 3.11+. A 24GB M4 doesn't meet Apple's stated Mac minimum; one developer trained successfully on an RTX 4090 (24GB VRAM) under Linux.
- **Data format**: JSONL, `{"role":"user"|"assistant","content":"..."}` per line; ~80/20 train/valid split typical.
- **Dataset size**: 100–1,000 examples for simple tasks, 5,000+ for complex ones ("quality over quantity"); a real cleanup adapter used ~2,000 pairs (85/15 split).
- **Adapter size**: ~160MB (rank-32 LoRA, ~67M trainable params over the 3.2B base). Training time is undocumented by Apple and not found elsewhere.
- **Distribution**: one adapter per exact base-model version (retrain-per-OS-version rule, confirmed); ship via **Background Assets**, not bundled.
- **Draft model**: toolkit has an optional `train_draft_model` step for speculative decoding. A 2–4x speedup/no-quality-loss figure exists only from independent reverse-engineering of Apple's model ([fguzman82/apple-foundation-model-analysis](https://github.com/fguzman82/apple-foundation-model-analysis)) — not Apple-published, unverified for third-party-trained draft models.
- Swift loads it via `SystemLanguageModel.Adapter` ([doc page](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models)); I could not retrieve the verbatim code sample.
- No Apple text distinguishes Developer ID from App Store apps for this entitlement; the EnviousWispr case suggests the gate applies regardless of channel.

### 2. Adapter quality on an analogous editing task
Best evidence is a direct analog: a rank-32 LoRA trained to fix spoken self-corrections in dictation, graded by an ensemble of 12 LLM judges: self-correction resolution **13%→86%**, general polish **66%→83%**, multi-behavior paragraphs **63%→84%** (held-out self-correction set was only 15 cases — small-N). Latency cost of the adapter itself scaled with input: **+13%/+31%/+52%** short/medium/long, **+35%** overall (846ms→1,140ms) — a real quality win but a latency *cost*, absent an effective draft model. No official Apple quality numbers for a rewriting/editing adapter were found.

### 3. Latency levers on the stock model
- `prewarm()`/`prewarm(promptPrefix:)` caches per session instance; a fresh `LanguageModelSession` repeats that cost. Sessions already support multi-turn transcripts, so **reusing one long-lived session across dictations** (rotating periodically for context budget) should avoid reprocessing instructions every call — targets your ~400ms fixed overhead directly.
- Context window grew **4,096 (macOS 26) → 8,192 tokens (macOS 27/AFM 3)**; new `contextSize`/`tokenCount(for:)` APIs (back-deployed to 26.4) replace hardcoded limits.
- `includeSchemaInPrompt` defaults **true**, injecting your `@Generable` schema into every prompt; for a stable one-field struct, setting it **false** and describing the shape once in cached instructions should cut per-request tokens.
- `maximumResponseTokens`: one report (HuggingFace [AnyLanguageModel PR #206](https://github.com/huggingface/AnyLanguageModel/pull/206)) says this was silently ignored on earlier OS builds — verify it's honored on your deployment target before relying on it.
- `SystemLanguageModel(guardrails: .permissiveContentTransformations)` (macOS 26+) cuts false-refusal retries on transform tasks like cleanup.
- **Private Cloud Compute** is now open to third parties (`PrivateCloudComputeLanguageModel`, its own `com.apple.developer.private-cloud-compute` entitlement, free under the Small Business Program) but needs network, has no published latency numbers, and is a poor fit for an offline, fast feature.
- AFM 3 Core runs ~30 tok/s on iPhone-class silicon — "same ballpark" as the prior 3B model despite higher quality (secondary source, [laurencemoroney.com](https://laurencemoroney.com/2026/06/18/unpacking-afm-3.html)); no Mac throughput number was published — don't assume it transfers.

### 4. Writing Tools / proofread
WWDC25 [session 265](https://developer.apple.com/videos/play/wwdc2025/265/) confirms Proofread renders as underlines over an `NSAttributedString` via `NSWritingToolsCoordinator` delegate callbacks — built to animate corrections inside a real, visible text view (standard `NSTextView`/`UITextView`/SwiftUI text gets it for free; the coordinator is only for custom text views). **No headless "just give me corrected text" path was found** — Writing Tools requires real UI and isn't usable for a silent background pipeline. A secondary source claims Proofread runs on the same on-device FoundationModels stack, but Apple hasn't confirmed this or published its prompt.

### Ranked levers, by effort
1. **Reuse one long-lived `LanguageModelSession`** across dictations instead of a fresh prewarmed one each time. *Low.*
2. **`includeSchemaInPrompt: false`**, move the output shape into cached instructions. *Low.*
3. **Cap `maximumResponseTokens`** via `tokenCount(for:)`/`contextSize` (confirm honored on-target first). *Low.*
4. **Trim and eval-harness the instruction prompt**, explicitly countering the "under-editing" tendency a same-task AFM 3 eval documented (934/1,462 outputs returned verbatim). *Medium.*
5. **Prototype (don't ship) a LoRA + draft-model adapter** — largest quality jump found anywhere (13%→86%), but new entitlements are refused and the toolkit doesn't support macOS 27/AFM 3 yet. *High, currently blocked for shipping.*

### Flagged unverified
The "~40% latency cut" / "150ms on A18" prewarm figures (no clear primary source); the 2–4x speculative-decoding number (reverse-engineered, not Apple's claim); verbatim `SystemLanguageModel.Adapter` Swift sample; Developer-ID-vs-App-Store treatment for either entitlement; Proofread's exact model/prompt.

---

**Key sources**: [Foundation Models adapter training](https://developer.apple.com/apple-intelligence/foundation-models-adapter) · [Adapter entitlement doc](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.foundation-model-adapter) · [Loading a custom adapter](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models) · [EnviousWispr adapter case study](https://enviouswispr.com/blog/fine-tuning-apple-on-device-model-self-corrections/) · [EnviousWispr AFM3 prompt-eval issue](https://github.com/saurabhav88/EnviousWispr/issues/2795) · [Apple ML Research: Third-gen Foundation Models](https://machinelearning.apple.com/research/introducing-third-generation-of-apple-foundation-models) · [9to5Mac: macOS 27 Golden Gate](https://9to5mac.com/2026/09/14/macos-27-golden-gate-now-available-here-is-everything-new/) · [9to5Mac: AFM3 explained](https://9to5mac.com/2026/06/11/apples-new-foundation-models-explained-on-device-ai-cloud-ai-and-everything-in-between/) · [WWDC26: What's new in Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/) · [WWDC25: Dive deeper into Writing Tools](https://developer.apple.com/videos/play/wwdc2025/265/) · [NSWritingToolsCoordinator docs](https://developer.apple.com/documentation/appkit/nswritingtoolscoordinator) · [AnyLanguageModel PR #206 (maximumResponseTokens)](https://github.com/huggingface/AnyLanguageModel/pull/206) · [afm-summarize issue #1](https://github.com/pszypowicz/afm-summarize/issues/1) · [3Nsofts: FM entitlements in iOS 27](https://3nsofts.com/guides/foundation-models/foundation-models-api-ios-27-entitlements) · [Reverse-engineered AFM analysis](https://github.com/fguzman82/apple-foundation-model-analysis) · [Unpacking AFM 3](https://laurencemoroney.com/2026/06/18/unpacking-afm-3.html) · [On-device vs PCC guidance](https://www.theswift.dev/posts/choose-between-on-device-foundation-models-and-private-cloud-compute/)

---

**Summary for the caller**: Report delivered above (866 words in the body, verified via `wc -w`), fully sourced, ranked-lever list included, uncertain claims flagged explicitly. The single most important finding — Apple has stopped accepting new Foundation Models adapter entitlement requests and the adapter toolkit doesn't yet support macOS 27/AFM 3 — was corroborated across Apple's own adapter-training page and an independent developer's first-hand account, and should reorder any roadmap that assumed adapter training was a near-term option.
