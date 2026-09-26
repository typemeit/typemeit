# Punctuation and truecasing models: survey

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

# Speech Post-Processing Models for Punctuation Restoration & Truecasing — Research Findings

All numbers below are tagged with the exact URL they came from. Where a fetch tool summarized/paraphrased a page rather than me reading raw text, I've noted that explicitly. Anything I could not find is marked **not published**.

---

## 1. NVIDIA NeMo `punctuation_en_distilbert` / `punctuation_en_bert`

**Not on huggingface.co/nvidia.** I queried the HF API for all 943 models under the `nvidia` org and searched for "punct"/"capital" in their IDs — zero matches (checked via `huggingface.co/api/models?author=nvidia`). These models are NGC-only, not mirrored to Hugging Face.

- **`punctuation_en_distilbert`** — https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/punctuation_en_distilbert
  - Architecture: DistilBERT encoder + two token-classification heads (punctuation, capitalization), jointly trained.
  - Size: 233.76 MB (compressed download).
  - Accuracy: "F1 score of 77%" on an **internal, non-public evaluation set** (macro-averaged due to class imbalance).
  - Training data: Tatoeba sentences, Project Gutenberg (via LibriSpeech corpus), Fisher English Training Speech transcripts.
  - Language: English only. Punctuation classes: comma, period, question mark only. Max sequence length 512 tokens.
  - License: NGC Terms of Use.
- **`punctuation_en_bert`** — https://catalog.ngc.nvidia.com/orgs/nvidia/teams/nemo/models/punctuation_en_bert
  - Architecture: BERT-base encoder + same two-head setup.
  - Size: 387.1 MB compressed.
  - Accuracy: also reported as "F1 score of 77%" on the same style of internal eval set. **Flag: both cards report the identical 77% headline figure — I retrieved this via an AI-summarizing fetch of each NGC page, not a verbatim scrape, so treat the exact wording/precision with caution; the coincidence itself is unverified.**
  - Same training data, language, punctuation set, license as above.
- **Architecture confirmation (no numbers)**: NeMo Framework docs confirm the "two token-level classifiers on top of a pretrained LM such as BERT" design but publish **no quantitative F1/precision/recall or latency numbers** anywhere in the guide — https://docs.nvidia.com/nemo-framework/user-guide/24.12/nemotoolkit/nlp/punctuation_and_capitalization.html
- **Latency**: not published for either model, anywhere I could find.
- **ONNX export**: NeMo's `nemo2riva` conversion tool supports exporting punctuation/capitalization models to ONNX for Riva deployment (`riva-build ... nemo2riva: {format: onnx}`) — https://docs.nvidia.com/deeplearning/riva/user-guide/docs/nlp/nlp-customizing.html and https://github.com/nvidia-riva/nemo2riva (found via search; not independently re-verified by reading the tool's source).
- **Base-model parameter counts** (not stated by NVIDIA, but well-established public facts about the underlying checkpoints): bert-base-uncased ≈ 110M params (https://huggingface.co/google-bert/bert-base-uncased); distilbert-base-uncased ≈ 67M params (https://huggingface.co/distilbert/distilbert-base-uncased).

---

## 2. `1-800-BAD-CODE/punctuation_fullstop_truecase_english`

https://huggingface.co/1-800-BAD-CODE/punctuation_fullstop_truecase_english

- **Architecture**: 6-layer Transformer encoder, model dimension 512, SentencePiece tokenizer (32k vocab, lowercase-English-only). Three joint heads: punctuation (NULL/ACRONYM/./,/?), sentence-boundary-detection (conditioned on punctuation via embeddings), and per-character true-casing (conditioned on SBD). Internally referenced as `pcs_en` / `punct_cap_seg_en` in code and in a derived repo (same model, different name — see §5).
- **Size on disk** (from the HF file tree API): `punct_cap_seg_en.onnx` = 209,532,928 bytes (~200 MB); `spe_32k_lc_en.model` tokenizer = 587,902 bytes. The model card itself does not state a parameter count — a **"52M-parameter"** figure only appears on a third-party derived CoreML card (§5), not here.
- **ONNX export**: Yes — distributed natively as ONNX, loaded via the `punctuators` PyPI package's `PunctCapSegModelONNX` class.
- **Accuracy** (author's own eval: 3,000 held-out News Crawl examples, each 10 sentences concatenated/lowercased/depunctuated):
  - Punctuation (weighted avg): P 97.25 / R 97.21 / **F1 97.23**. Per class: NULL F1 98.66, ACRONYM F1 83.01, "." F1 91.80, "," F1 78.15, "?" F1 75.56.
  - True-casing (conditioned on predicted punctuation): weighted **F1 99.50** (LOWER 99.74 / UPPER 93.76); conditioned on gold punctuation: weighted F1 99.66.
  - Sentence-boundary detection: weighted F1 99.09 (predicted punctuation) / 99.97 (gold punctuation).
- **Language**: English only; trained on ~10M lines of WMT News Crawl (years 2012 and 2021).
- **License**: Apache 2.0.
- **Latency**: not published on the card.
- Max window: 256 subtokens (the `punctuators` package handles longer input via overlapping segments).

---

## 3. `oliverguhr/fullstop-punctuation-multilang-large`

https://huggingface.co/oliverguhr/fullstop-punctuation-multilang-large

- **Architecture**: XLM-RoBERTa-large (`XLMRobertaForTokenClassification`, confirmed via HF API `config.architectures`).
- **Size**: ~0.6B params per HF's model-size badge (consistent with the well-known ~550–561M param count of xlm-roberta-large); weight files (`model.safetensors`, `pytorch_model.bin`, `tf_model.h5`) are each ≈2.235 GB (fp32), confirmed via the HF file-tree API.
- **Training data**: Europarl dataset from the SEPP-NLG shared task — https://huggingface.co/datasets/wmt/europarl (political speeches; the README warns of domain shift on non-speech text).
- **Punctuation marks restored**: `.` `,` `?` `-` `:`
- **F1 per language/mark** (from the raw README table):

  | Label | EN | DE | FR | IT |
  |---|---|---|---|---|
  | none | .991 | .997 | .992 | .989 |
  | . | .948 | .961 | .945 | .942 |
  | ? | .890 | .893 | .871 | .832 |
  | , | .819 | .945 | .831 | .798 |
  | : | .575 | .652 | .620 | .588 |
  | - | .425 | .435 | .431 | .421 |
  | macro avg | .775 | .814 | .782 | .762 |

- **Languages**: English, German, French, Italian (this "large" checkpoint specifically; a smaller "multilingual-sonar-base" sibling adds Dutch, and community fine-tunes cover Catalan/Welsh/others — all linked from the same README).
- **License**: MIT.
- **Latency**: not published on the card.
- Has an `onnx/` subfolder in the repo, but no documented conversion details/benchmarks; a community discussion thread notes you must manually copy `tokenizer.json` into the root folder to use it — https://huggingface.co/oliverguhr/fullstop-punctuation-multilang-large/discussions/10 (unverified community note, not official docs).
- Citation: Guhr et al., "FullStop: Multilingual Deep Models for Punctuation Prediction," Swiss Text Analytics Conference 2021 (per the README's own BibTeX).

---

## 4. sherpa-onnx CT-Transformer + the "online" English punctuation model

Repo: https://github.com/k2-fsa/sherpa-onnx · Docs: https://k2-fsa.github.io/sherpa/onnx/punctuation/pretrained_models.html

Two distinct model families are shipped here — both ONNX-based:

**(a) Offline CT-Transformer (Chinese+English)** — `sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12`
- fp32 `model.onnx` = 281 MB; int8 `model.int8.onnx` = 72 MB (confirmed via `gh release view punctuation-models --repo k2-fsa/sherpa-onnx`, and the docs page).
- Language: Chinese + English (bilingual).
- Elapsed-time numbers quoted on the docs page for the site's own demo sentences (hardware unspecified there): fp32 ≈0.007s (Chinese) / 0.005s (mixed) / 0.003s (English) per utterance; int8 ≈0.014s / 0.010s / 0.007s.
- **Origin**: "CT-Transformer" = **Controllable Time-delay Transformer**, from Chen, Chen, Li, Wang, "Controllable time-delay Transformer for real-time punctuation prediction and disfluency detection," ICASSP 2020 — this is Alibaba/FunASR's model. The FunASR/ModelScope original is mirrored at https://huggingface.co/funasr/ct-punc (raw PyTorch `model.pt` = 1,125,507,622 bytes ≈1.07 GB — much larger than sherpa's pruned/quantized ONNX export; License: Apache-2.0 per that card's metadata).

**(b) Online/streaming English-only punctuation+casing model** — `sherpa-onnx-online-punct-en-2024-08-06`
- fp32 `model.onnx` = 28 MB; int8 `model.int8.onnx` = 7.1 MB.
- Language: English only.
- Elapsed time on the docs' own demo: ≈0.030s (fp32) / ≈0.013s (int8).
- **Source, per the docs page itself**: "Converted from https://github.com/frankyoujian/Edge-Punct-Casing" — this is a completely different, non-Transformer architecture (see below), and it is directly relevant to your target.

**Edge-Punct-Casing — the actual paper behind that small English model**
Paper: Jian You & Xiangfeng Li (Cisco Systems), "A light-weight and efficient punctuation and word casing prediction model for on-device streaming ASR," arXiv:2407.13142 — https://arxiv.org/abs/2407.13142 (full text extracted from https://arxiv.org/pdf/2407.13142). Code: https://github.com/frankyoujian/Edge-Punct-Casing (Apache 2.0).

- **Architecture**: NOT a Transformer at all — 3× 1D-CNN encoder layers (residual + layernorm, kernel size 3, 100-dim SentencePiece embeddings, 5,000-token vocab) → 2× BiLSTM layers (hidden dim 384) → 1 unidirectional LSTM decoder → two softmax heads: punctuation (O/COMMA/PERIOD/QUESTION) and word casing (O/UPP/CAP/MIX).
- **Training data**: ~300 MB / 55M words — Wikipedia raw text (57.6%), public interview transcripts (25.3%), TED Talk transcripts (17.1%).
- **Accuracy on IWSLT2011 test set** (paper's Table 3, punctuation P/R/F1): COMMA 71.5/54.0/61.5, PERIOD 76.7/82.6/79.5, QUESTION 73.8/70.5/72.1, **overall 74.4/67.9/71.0** — vs. their CT-Transformer baseline's overall 73.7/76.0/74.9 (paper's own framing: "comparable," a few F1 points lower). Casing overall F1 = 88.2% (Table 4; UPP-CASE F1 98.9, CAP-CASE F1 84.9 — note: MIX-CASE cells and one prose claim, "outperforms previous works ... (87.8% versus 82.4%)," did not extract cleanly from the PDF table layout via `pdftotext`; flagging those two specific numbers as lower-confidence pending a cleaner read of the source PDF).
- **The single most directly-relevant published benchmark for your use case** (paper's Table 6, quantized ONNX models, run under the sherpa-onnx framework, **on an Intel Core i5-1035G1 CPU**, timing = cost to process a ~40-word example paragraph):

  | Model | ONNX size | Inference time |
  |---|---|---|
  | CT-Transformer (BERT-style baseline) | 280 MB | 25 ms (×1.0) |
  | **CNN-BiLSTM (this paper)** | **7 MB** | **10 ms (×2.5 faster)** |

  The paper's own "7 MB" quantized-ONNX figure matches sherpa-onnx's shipped int8 file (7.1 MB) almost exactly — strong cross-confirmation that sherpa-onnx's "online" English punctuation model *is* this exact CNN-BiLSTM checkpoint. This is a CPU number on a 2020 low-end laptop chip, not Apple Silicon/ANE, and not a 100-word input — but it's the only rigorously-benchmarked, peer-reviewed-adjacent, apples-to-apples size/latency comparison I found anywhere in this research, and it's an order of magnitude smaller/faster than every BERT-based option above.

---

## 5. CoreML ports of punctuation-restoration / truecasing models

Found via `huggingface.co/models?library=coreml&search=punct` (9 results) — https://huggingface.co/models?library=coreml&search=punct. Searching `search=truecase` on the same filter returned **zero results** — no dedicated CoreML truecasing port exists that I could find (general GitHub/HF search for "CoreML truecase" also turned up nothing beyond generic conversion tooling and an unrelated PyTorch-only Spanish truecasing model, HURIDOCS/spanish-truecasing, with no CoreML version). **Marking dedicated CoreML truecasing port as not published.**

Punctuation CoreML ports that do exist (all small, low-download community uploads — treat all numbers below as **self-reported, unverified**):

- **`soloish90/punct-cap-seg-en-coreml-int8`** — https://huggingface.co/soloish90/punct-cap-seg-en-coreml-int8
  - Direct CoreML conversion of `1-800-BAD-CODE/punct_cap_seg_en` (= §2's model, confirmed same `.onnx` filename). Card describes it as "a 52M-parameter BERT-style token classifier."
  - INT8 weights / FP32 activations (per-block quantization); converted ONNX → PyTorch (`onnx2torch`) → coremltools; validated for end-to-end output parity against the original ONNX model.
  - **Latency claimed: "~6 ms per 256-token window on Apple Silicon (CoreML, all compute units)."**
  - Explicit gotcha documented: "Do not reconvert with FP16 activations" — the model's internal attention-mask constant overflows in half precision and silently degrades output quality (weight-only INT8 is fine; FP16 *activations* are not).
  - License: Apache 2.0 (inherited). Built for something the card calls the "Babble" dictation app, running alongside "NVIDIA Nemotron streaming ASR" — i.e., this looks like a real prior-art precedent of another macOS/iOS dictation app doing exactly what you're evaluating. This claim comes only from the uploader's own README, unverified elsewhere.
- **`soloish90/fullstop-punctuation-coreml-fp16`** — https://huggingface.co/soloish90/fullstop-punctuation-coreml-fp16
  - CoreML conversion of `oliverguhr/fullstop-punctuation-multilang-large` (= §3's model). FP16 weights + activations, **~1.0 GB on disk**.
  - **Latency claimed: "~54 ms per 256-token window on Apple Silicon GPU"**; load time ~0.3–3s (cached after first launch).
  - Card explains INT8 was rejected for this model specifically because "its inline dequantize ops cost ~12s of uncached GPU shader compilation on every process launch" — i.e., a real, specific tradeoff note relevant if you evaluate this path.
  - License: MIT. Also built for "Babble."
- **`beshkenadze/punctuate-all-coreml`** — https://huggingface.co/beshkenadze/punctuate-all-coreml — no model card at all. Repo holds a `model.mlpackage` (~572 MB total repo storage per the HF API) with RoBERTa-style special tokens (`<s>`/`<mask>`), suggesting (not confirmed) a port of the multilingual `kredor/punctuate-all` model mentioned in oliverguhr's README. No performance data — **not published**.
- **`StulkovLD/punctuation-en-coreml`** (+ a parallel `punctuation-ru-coreml`) — https://huggingface.co/StulkovLD/punctuation-en-coreml — no model card. Repo holds `ENPunctBert.mlpackage` (~217.5 MB) plus WordPiece `vocab.txt`/`labels.json`, suggesting a BERT (not RoBERTa) base. Architecture/source/benchmarks — **not published**.

---

## 6. ONNX Runtime for Swift/macOS

- **Official: `microsoft/onnxruntime-swift-package-manager`** — https://github.com/microsoft/onnxruntime-swift-package-manager
  - "A light-weight repository for providing Swift Package Manager (SPM) support for ONNXRuntime" — wraps the prebuilt ORT Objective-C/C xcframework as an SPM binary target.
  - The README frames the package specifically around "mobile iOS" consumption and does not, in the text I could retrieve, explicitly document CoreML execution-provider bundling or macOS support.
  - Activity: 99 stars, 59 forks, 13 open issues, 135 commits; latest tagged release 1.20.0 — https://github.com/microsoft/onnxruntime-swift-package-manager/releases/tag/1.20.0.
  - A community fork, `ntna141/onnxruntime-ios-swift-package` (https://github.com/ntna141/onnxruntime-ios-swift-package), describes itself as removing "macOS variants from xcframeworks" for App Store validation — implying (inference, not directly confirmed by Microsoft's docs) that the official package's xcframework does bundle macOS binaries alongside iOS ones.
- **General ORT CoreML execution-provider docs** (platform-agnostic): https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html
  - Requires iOS ≥13 or macOS ≥10.15; recommends ANE-equipped Apple devices for best performance; explicitly states enabling the CoreML EP "does not guarantee the entire model to be executed using ANE only."
  - Accessible via **C, C++, Objective-C, C#, and Java APIs — no dedicated Swift API is documented**, so Swift code goes through the Objective-C wrapper.
- **Community alternative: `readdle/swift-onnxruntime`** — https://github.com/readdle/swift-onnxruntime — "a basic Swift Package wrapper for ONNX Runtime releases from microsoft/onnxruntime," wrapping the C API directly. Very low maturity: 0 stars, 8 commits, tracks ORT 1.17.3, minimal documentation, no stated execution-provider details.
- **Net read**: the Swift path into ONNX Runtime on macOS is real but goes through an Objective-C-bridged binary framework rather than a native Swift API, is iOS-first in its own docs, and requires manually registering the CoreML EP — workable, not turnkey.

---

## 7. Converting a token-classification BERT model to CoreML via coremltools

- Apple's own official tutorial, "Converting TensorFlow 2 BERT Transformer Models" — https://apple.github.io/coremltools/docs-guides/source/convert-tensorflow-2-bert-transformer-models.html — covers only **masked-language-modeling** (`TFDistilBertForMaskedLM`) and **question-answering** BERT heads. I fetched it directly and confirmed it makes **no mention of token classification or NER** — there is no official Apple walkthrough for this exact task type.
- **`huggingface/exporters`** (https://github.com/huggingface/exporters) — a coremltools-based conversion package integrated with 🤗 Transformers — explicitly lists `token-classification` as a supported `--feature` for export (e.g. `python -m exporters.coreml --model=<model> --feature=token-classification exported/`), per https://github.com/huggingface/exporters/blob/main/README.md (found via search summary; I did not re-fetch and quote this file verbatim, so treat exact CLI syntax as approximate). This is the generic, documented path for exactly your task shape (BERT-family token classification → CoreML), maintained by Hugging Face rather than Apple.
- The `soloish90` CoreML conversions in §5 are a concrete existence proof that this works in practice for punctuation models specifically — their documented pipeline was ONNX → PyTorch (via `onnx2torch`) → coremltools, with a specific, named failure mode (FP16 activations overflowing an internal attention-mask constant) that would be directly relevant if TypeMeIt attempted the same conversion.

---

## 8. MLX / mlx-swift for BERT-style token classification

- `ml-explore/mlx-swift` (https://github.com/ml-explore/mlx-swift) is just the core array framework — no model implementations.
- `ml-explore/mlx-swift-lm` (https://github.com/ml-explore/mlx-swift-lm, formerly mlx-swift-examples) contains `Libraries/MLXEmbedders/Models/Bert.swift` and `NomicBert.swift`. **I fetched this file's source directly** (not a search summary): it defines `BertModel: Module, EmbeddingModel` (hidden states + optional pooled `[CLS]` output, for embeddings/similarity/RAG use cases), and separately `BertRerankerModel` / `BertSequenceClassificationRerankerModel`, which apply a `SequenceClassificationHead`/`Linear` over the pooled `[CLS]` token to emit **one label (or reranker score) per whole sequence** (governed by a `numLabels` config field). There is **no per-token/token-classification head** anywhere in this file — i.e., nothing that outputs a separate label per word/subtoken the way punctuation restoration needs.
- I explicitly ran a GitHub code search for `TokenClassification` scoped to `repo:ml-explore/mlx-swift-lm` and got zero hits (`{"total_count":0}`). This directly contradicts an earlier web-search snippet I encountered claiming "a TokenClassificationModel head was added to the BERT family" — having checked the actual source, **that claim is false or badly stale and should be disregarded.**
- **Conclusion: there is currently no ready-made mlx-swift path for BERT-style per-token classification.** Embeddings and single-label sequence classification/reranking are supported; per-token classification would require writing a custom head on top of `BertModel`'s already-exposed hidden states — architecturally straightforward, but not an out-of-the-box example today.
- Python-side (not Swift) MLX has a plain BERT embeddings example at https://github.com/ml-explore/mlx-examples/tree/main/bert / https://github.com/ml-explore/mlx-examples/blob/main/bert/README.md, with converted weights at https://huggingface.co/mlx-community/bert-base-uncased-mlx — again embeddings only, and Python rather than Swift.

---

## Summary table (all figures traceable to sections above)

| Model | Params / Size | Reported latency | Language | License |
|---|---|---|---|---|
| NeMo `punctuation_en_distilbert` | 233.76 MB compressed | not published | EN | NGC ToU |
| NeMo `punctuation_en_bert` | 387.1 MB compressed | not published | EN | NGC ToU |
| 1-800-BAD-CODE `punctuation_fullstop_truecase_english` | ~209.5 MB ONNX (52M params per a third-party card, unconfirmed on the original) | not published (original); ~6 ms/256 tok on Apple Silicon per unverified CoreML port | EN | Apache 2.0 |
| oliverguhr `fullstop-punctuation-multilang-large` | ~0.6B params, ~2.2 GB fp32 | not published (original); ~54 ms/256 tok on Apple Silicon GPU per unverified CoreML port | EN/DE/FR/IT | MIT |
| sherpa-onnx CT-Transformer (zh+en) | 281 MB fp32 / 72 MB int8 | ~3–14 ms per demo utterance (unspecified HW) | ZH+EN | Apache 2.0 (FunASR origin) |
| sherpa-onnx "online" English (= Edge-Punct-Casing CNN-BiLSTM) | 28 MB fp32 / **7.1 MB int8** | ~13–30 ms per demo utterance (sherpa's own harness); **10 ms on Intel i5-1035G1 CPU per the source paper** | EN only | Apache 2.0 |

The Edge-Punct-Casing/sherpa-onnx pairing (§4) is the only entry here with a rigorous, published, apples-to-apples CPU benchmark against a BERT-style baseline, and it's the smallest/fastest model by a wide margin — but it's CNN-BiLSTM, not BERT, has a coarser 4-class punctuation set (no colon/hyphen) and word-level (not per-character) casing, and its published number is on Intel silicon at ~40 words, not Apple Silicon/ANE at 100 words. The CoreML community ports (§5) are the only Apple-Silicon-specific numbers found for BERT-style models, but they come from low-download, unofficial HF uploads with no independent verification.
