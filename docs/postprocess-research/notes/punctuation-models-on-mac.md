# Punctuation and truecasing models on the Mac

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

## Punctuation + truecasing model for TypeMeIt — research findings

**Headline finding:** the strongest candidate (1-800-BAD-CODE's `punctuation_fullstop_truecase_english`) exists in three Apple-Silicon-ready packagings of the *same* Apache-2.0 weights — raw ONNX, a CoreML int8 export, and an MLX export — so the real decision is runtime/tokenizer plumbing, not model hunting. The other serious option is sherpa-onnx's English CNN-BiLSTM punctuation model. Nothing newer (2025–2026) beats either on the specific job. None of VoiceInk, Handy, FluidAudio, or OpenWhispr ships a dedicated non-LLM punctuation model — all lean on an LLM (BYOK cloud, local Ollama/llama.cpp, or Apple's on-device model, same as TypeMeIt today); Handy — TypeMeIt's own upstream for `Learning`/`Insights` and `transcribe.cpp` — uses Apple Intelligence identically but ships it **off by default**, pasting raw unpunctuated Parakeet text otherwise. FluidAudio is the one outlier: its "Parakeet Unified 0.6B" bakes punctuation/casing into ASR decoding itself, unlike the raw Parakeet checkpoint TypeMeIt runs through `transcribe.cpp`. So there's no peer benchmark to lean on — this needs empirical eval.

### Comparison

| Model | Size on disk | Swift runtime | Tokenizer | Casing / acronyms | Latency (reported) | License |
|---|---|---|---|---|---|---|
| **1-800-BAD-CODE `punctuation_fullstop_truecase_english`** — ONNX / CoreML-int8 / MLX | 210.1MB / **57.3MB** / 56–105MB | ONNX Runtime (new dep) / **CoreML (free, system framework)** / mlx-swift (new dep) | Raw SentencePiece `.model` only — **no** `tokenizer.json`. `swift-transformers`' `UnigramTokenizer` only parses pre-converted `tokenizer.json` vocab arrays; confirmed from source it cannot load the raw protobuf. Needs `jkrukowski/swift-sentencepiece` (MIT, pure SPM, prebuilt xcframework) | Per-character prediction, explicit `<ACRONYM>` label → correctly handles VAT/API/PDF. **Gap: label set has no "!"** (`post_labels` = `<NULL>,<ACRONYM>,.,,,?`) | CoreML card claims ~6ms/256-token window "on Apple Silicon" (chip unstated, unverified on M4) | Apache-2.0 |
| **sherpa-onnx `sherpa-onnx-online-punct-en-2024-08-06`** (CNN-BiLSTM) | 7.1MB (int8) / 28MB (fp32) + 146KB vocab | sherpa-onnx's official SPM package, bundles ONNX Runtime (~20–34MB extra, new dep) | Built-in BPE vocab handled inside `add_punctuation_with_case()` — zero tokenizer work | Method name confirms case restoration; only sentence-initial capitalization is shown in the maintainer's own example — **acronym/proper-noun behavior undemonstrated** | 13–30ms for one 8-word sentence, hardware unstated | Apache-2.0 |
| sherpa-onnx CT-Transformer zh-en | 72–281MB | same | same | **No casing at all** (punctuation-only) — ruled out | n/a | Apache-2.0 |
| `oliverguhr`/`soloish90` CoreML fp16 | ~1.07GB | CoreML | separate | Punctuation only, no truecasing | ~54ms/256 tok | MIT |
| `ai4bharat/Cadence` (2025) | 1B/270M params, no ONNX/CoreML export | none | n/a | Casing is a rule-based bolt-on | n/a | MIT label, but Gemma-3 base terms may impose pass-through restrictions (unresolved) |

### Top-2 exact artifacts
**1. `soloish90/punct-cap-seg-en-coreml-int8`** (huggingface.co/soloish90/punct-cap-seg-en-coreml-int8): `punctuation.mlmodelc/weights/weight.bin` 59,374,976B, `model.mil` 86,569B, `metadata.json` 3,170B, `coremldata.bin`(×2) 701B, `tokenizer.model` 587,902B → **≈57.3MB total**. I/O confirmed from the model's own `metadata.json`: input `input_ids` Int32 `[1,256]`; outputs `pre_preds`, `post_preds`, `cap_preds [1,256,16]` (per-character, 16-wide), `seg_preds`.

**2. `sherpa-onnx-online-punct-en-2024-08-06`** (github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-online-punct-en-2024-08-06.tar.bz2): `model.int8.onnx` 7.1MB (or `model.onnx` 28MB fp32) + `bpe.vocab` 146KB.

### Python eval snippets (written from source, not executed)

```python
# Candidate 1 — pip install punctuators
from punctuators.models import PunctCapSegModelONNX
model = PunctCapSegModelONNX.from_pretrained("pcs_en")
print(model.infer(["okay so three things for tomorrow first we need to finish the landing page"])[0])
```

```python
# Candidate 2 — pip install sherpa-onnx (verified verbatim against the repo's own example script)
import sherpa_onnx
cfg = sherpa_onnx.OnlinePunctuationConfig(
    model_config=sherpa_onnx.OnlinePunctuationModelConfig(
        cnn_bilstm="./sherpa-onnx-online-punct-en-2024-08-06/model.int8.onnx",
        bpe_vocab="./sherpa-onnx-online-punct-en-2024-08-06/bpe.vocab",
    )
)
punct = sherpa_onnx.OnlinePunctuation(cfg)
print(punct.add_punctuation_with_case("okay so three things for tomorrow first we need to finish the landing page"))
```

### Recommendation
Run both snippets over an expanded eval set (extend `Scripts/cleanup-eval/cases.json`'s 132 cases toward ~350, weighted toward acronyms, proper nouns, and exclamations — TypeMeIt's own trouble spots) before any Swift work. Provisionally, prefer **1-800-BAD-CODE via the CoreML int8 export + `jkrukowski/swift-sentencepiece`**: it's the only candidate that verifiably does proper-noun/acronym truecasing, needs no new inference runtime (CoreML is free), and is smallest on disk. Budget real engineering time to port `punctuators`' sliding-window+overlap chunking (needed since 300 words can exceed the 256-token window) and its 4-tensor output decoding into Swift, and add "!" via a small heuristic since the label set lacks it. Keep sherpa-onnx's model as the low-effort fallback (official SPM package, ~7MB, zero tokenizer work) if CoreML's latency or acronym handling doesn't hold up on real M4 hardware.

### Unverified — flagged explicitly
No M4-specific, 100-word-scale latency exists for either candidate. 1-800-BAD-CODE's 97.2%/99.5% F1 is measured on clean WMT News text, not conversational speech; comparable models score far lower on spontaneous speech (SponSpeech ~75% F1 on podcasts, Cadence 62–63% F1), so expect a real gap on this app's dictation. sherpa-onnx's acronym/proper-noun casing is undemonstrated. iky1e's MLX re-export cards report inconsistent parameter counts between variants (unresolved). Cadence's Gemma-3 license pass-through needs legal review, not just the card's "MIT" label.
