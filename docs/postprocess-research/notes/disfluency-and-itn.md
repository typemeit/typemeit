# Disfluency removal and inverse text normalisation

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

# Research Findings: Fast Alternatives to LLM-Based Transcript Cleanup

## PART 1 — Disfluency Detection/Removal

### A. Small BERT-based token-classification models trained on Switchboard

- **Rocholl, Zayats, Walker, Murad, Schneider, Liebling — "Disfluency Detection with Unlabeled Data and Small BERT Models," Interspeech 2021.** This is the most directly relevant paper found — Google Research, explicitly targets "small, fast, on-device models." Model sizes and Switchboard F1 (median latency over batches of 8 sentences, GPU):
  - BERT_BASE: 108.9M params, 72ms latency
  - DistilBERT: 66.4M params
  - TinyBERT: 66.4M (6-layer) / 14.3M (4-layer)
  - MobileBERT: 24.6M params
  - Small-vocab BERT variants: 11.7M / 4.6M / 3.1M / 1.2M params, 9–32ms latency
  - PD-BERT: 4.8M / 4.4M params
  - Best F1: BERT_BASE + Reddit-pretrain + self-training = **90.9 F1**; Small-vocab BERT 12×128 + self-training = **89.9 F1**; smallest model (6×96, 8-bit quantized) = **88.4 F1**, reported as small as **1.3 MiB**, and **11ms latency on Android after 8-bit quantization**. Paper claims "99% reduction in model size and 80% latency reduction while maintaining competitive performance."
  - No public code/model release found.
  - URLs: https://arxiv.org/abs/2104.10769 · https://www.isca-archive.org/interspeech_2021/rocholl21_interspeech.pdf

- **Follow-up (same lineage), "Teaching BERT to Wait: Balancing Accuracy and Latency for Streaming Disfluency Detection," arXiv:2205.00620.** Uses "BERT_SV" — a distilled BERT_BASE variant with smaller vocab/hidden dims, **3.1M params** (vs. 108.9M for BERT_BASE). Streaming F1 = **0.83**, final (non-incremental) F1 = **0.88** on Switchboard; baseline non-streaming-trained model incremental F1 = 0.76. Reports runtime "80% lower than BERT_BASE." No explicit code release found. https://arxiv.org/pdf/2205.00620

- **Zayats et al., "Streaming Joint Speech Recognition and Disfluency Detection," arXiv:2211.08726** (joint ASR+disfluency, not pure text classifier — useful as an upper-latency reference point, not comparable 1:1 to a text-only post-processor): model sizes 50.6M (ASR-only / transcript-enriched) to 159M (pipeline ASR+BERT); **p50/p90 token latency 482–1199ms** depending on config; F1 (aligned) 0.69–0.84 depending on architecture. https://arxiv.org/pdf/2211.08726

- **Hugging Face models found:**
  - `hafidev/bert-base-uncased-discourse-markers-disfluency-detection-beta-v1` — bert-base-uncased (110M), token classification, F1 **0.9433**, P 0.9417, R 0.9449, Acc 0.9946. Training corpus undocumented ("more information needed") — **not confirmed to be Switchboard**. https://huggingface.co/hafidev/bert-base-uncased-discourse-markers-disfluency-detection-beta-v1
  - `kapilchauhan/fintuned-bert-disfluency` — bert-base-uncased, trained on Google's **Disfl-QA** dataset (question disfluencies, not Switchboard conversational speech), ~97.95% validation accuracy (not F1). https://huggingface.co/kapilchauhan/fintuned-bert-disfluency
  - `4i-ai/BERT_disfluency_cls` — bert-base-cased (110M), fine-tuned on the **Fisher English Corpus** (conversational telephone speech, Switchboard-adjacent), but does **utterance-level** fluent/disfluent classification, not token-level span detection; no F1 in the card; license cc-by-nc-sa-4.0; references a 2023 ACL Findings paper. https://huggingface.co/4i-ai/BERT_disfluency_cls
  - `DD0101/disfluency-large` — **flagged as not applicable**: fine-tuned from `vinai/phobert-large`, which is Vietnamese BERT; despite ranking in searches for "disfluency huggingface," this is a Vietnamese-language model (F1 0.9681), not relevant to English/Switchboard. https://huggingface.co/DD0101/disfluency-large

- **Released code with real Switchboard numbers:** `pariajm/joint-disfluency-detector-and-parser` (GitHub, MIT license) — implements Jamshid Lou & Johnson, "Improving Disfluency Detection by Self-Training a Self-Attentive Model" (ACL 2020, arXiv:2004.05323). Self-attentive parser + BERT-base-uncased embeddings; best **EDITED-word F-score = 92.4%** (self-trained on Switchboard gold + Fisher silver trees); four released pretrained models range 87.5–92.4% F1 depending on ELMo-vs-BERT and self-training. This is accurate but **BERT-base-sized (110M)**, not a "small" model — no inference speed numbers given. https://github.com/pariajm/joint-disfluency-detector-and-parser

- **Unverified/inaccessible:** Romana et al., "Enabling Off-the-Shelf Disfluency Detection and Categorization for Pathological Speech" (Interspeech 2022, doi:10.21437/Interspeech.2022-10971) kept surfacing in searches but I could not extract model size or F1 numbers from it (PDF fetch returned empty/binary twice). Flagging as **found but unverified** rather than guessing. https://www.isca-archive.org/interspeech_2022/romana22_interspeech.pdf

### B. Self-correction/repair ("send it to John no wait Sarah") detection — classic and modern

This is a distinct sub-literature from generic um/uh disfluency tagging, built around the **reparandum / interregnum / repair** structure (Shriberg's 1994 annotation scheme, widely cited but I did not independently fetch the thesis):

- **Hindle (1983), "Deterministic Parsing of Syntactic Non-fluencies," ACL** — first computational approach; assumes an explicit edit signal + POS tags + sentence boundaries, then uses deterministic parser rules to delete the reparandum; **97% recall** finding the correct repair. https://aclanthology.org/P83-1019.pdf
- **Bear, Dowding & Shriberg (1992), "Integrating Multiple Knowledge Sources for Detection and Correction of Repairs in Human-Computer Dialog," ACL** — combines pattern matching + syntactic/semantic constraints + acoustic cues (no assumption of an explicit edit signal); evaluated on 607 repair sentences out of 10,718 total. https://www.researchgate.net/publication/2859598_Automatic_Detection_and_Correction_of_Repairs_in_Human-Computer_Dialog
- **Heeman & Allen (1999), "Speech Repairs, Intonational Phrases, and Discourse Markers...," Computational Linguistics 25(4)** — joint statistical LM over POS/discourse-markers/repairs/intonation; **detected & corrected 66% of repairs at 74% precision**; 97% of discourse markers at 96% precision. https://aclanthology.org/J99-4003/ (PDF: https://aclanthology.org/J99-4003.pdf)
- **Charniak & Johnson (2001), "Edit Detection and Parsing for Transcribed Speech," NAACL** — clean two-stage pipeline: an edited-word detector removes edited words first, then a statistical parser parses what remains. Directly analogous architecture to "disfluency-tagger → deleter → cleanup." https://aclanthology.org/N01-1016/ (PDF: https://cs.brown.edu/research/pubs/pdfs/2001/Charniak-2001-EDP.pdf)
- **Johnson & Charniak (2004), "A TAG-based Noisy Channel Model of Speech Repairs," ACL** — models the well-known "rough copy" phenomenon: repairs tend to lexically/syntactically echo the reparandum they replace (relevant heuristic for detecting "no wait" style corrections). https://dl.acm.org/doi/abs/10.3115/1218955.1218960
- **Zwarts & Johnson (2011), "The Impact of Language Models and Loss Functions on Repair Disfluency Detection," ACL-HLT** — https://aclanthology.org/P11-1071/; and **Zwarts, Johnson & Dale (2010), "Detecting Speech Repairs Incrementally Using a Noisy Channel Approach," COLING** — incremental noisy-channel repair detection.
- **Hough & Schlangen, "Strongly Incremental Repair Detection" (STIR), arXiv:1408.6788** — hybrid: four Random Forest classifiers (edit-term occurrence, repair onset, reparandum onset, repair completion/structure) using n-gram-LM information-theoretic features. Trained/tested on Switchboard (Penn Treebank III disfluency annotations, ~100K utterances/600K words train). Results: **utterance-final reparandum-detection F=0.779**, repair-structure F=0.736, 6-word-delayed accuracy F=0.718. Detects repairs **1.0 words after repair onset, 2.6 words after reparandum onset on average** (vs. 4.6/7.5 words for the prior noisy-channel model — i.e., genuinely real-time-capable). No code release found. https://arxiv.org/abs/1408.6788
- **Key practical finding from the literature:** interregnum/editing-term cue phrases ("I mean," "well," "no," "sorry," "or rather," "actually") are repeatedly described as "relatively easy to detect... usually fixed phrases," in contrast to the reparandum span itself, which "is defined by its relationship to surrounding speech rather than fixed lexical cues" (recurring characterization across the Hough & Schlangen and related literature). This suggests a **hybrid design**: a small closed-class lexicon/regex for interregnum cue-phrase triggers (cheap, high precision) combined with a rough-copy/overlap heuristic or small classifier to find the reparandum span — this is synthesis from the cited papers, not a single off-the-shelf tool.

- **Very recent (2026) LLM-vs-small-encoder comparison:** medRxiv preprint "Detecting Self-Repairs from Spontaneous Speech with Prompt Ablation Across LLMs and Fine-Tuned Encoder" — DistilBERT (67M params) fine-tuned for self-repair detection scored **F1 ≈ 0.40** after domain adaptation, vs. **GPT-5 prompted F1 = 0.73** and LLaMA-3.1-8B F1 = 0.47, on the ADReSS (cognitive-impairment speech) dataset. Notably **the small encoder underperformed the LLMs substantially** on this specific task in this study, despite running "one or two orders of magnitude faster" (no exact ms given). Flagging this as a preprint (medRxiv, not peer-reviewed) and a narrow/clinical dataset, so generalization to a general dictation app is uncertain. https://www.medrxiv.org/content/10.64898/2026.08.21.26360471v1.full

- **Real-world signal from a comparable product:** an open GitHub feature request against **TypeWhisper** (a comparable macOS Whisper-based dictation app) for ITN discusses two options — adapting `nemo_text_processing`'s WFST rules, or a lightweight custom regex post-processor for cardinals/decimals/percentages/times. This is an open request, not a shipped/verified solution. https://github.com/TypeWhisper/typewhisper-mac/issues/110

---

## PART 2 — Inverse Text Normalization

### A. NVIDIA NeMo-text-processing

- **What it is:** Python package for TN/ITN for ASR/TTS, built on **Pynini** (Python wrapper around OpenFst) to compile hand-written grammars into WFSTs. Two-stage pipeline: classification (semiotic-token tagging) → verbalization (conversion to written form). Apache 2.0 license. https://github.com/NVIDIA/NeMo-text-processing
- **Paper:** Zhang, Bakhturina, Gorman, Ginsburg, "NeMo Inverse Text Normalization: From Development to Production," Interspeech 2021, arXiv:2104.05055. Confirmed from the text: **"We use Sparrowhawk as the production backend"**; grammars are exported to OpenFST Archive (`.far`) files (`tokenize_and_classify.far`, `verbalize.far`) and run inside a Docker container bundling Thrax + Sparrowhawk. **No latency/throughput numbers are published in this paper** — I checked specifically and confirmed their absence rather than assuming.
- **C++/production deployment confirmed in detail** via NVIDIA's own docs (https://docs.nvidia.com/nemo-framework/user-guide/24.12/nemotoolkit/nlp/text_normalization/wfst/wfst_text_processing_deployment.html): the exported `.far` files are consumed by Sparrowhawk's `normalizer_main` C++ binary — **inference runs entirely in C++ with no Python dependency**. This is the closest thing to a documented path for using NeMo's grammars from a native app.
- **Semiotic classes (base English):** CARDINAL, ORDINAL, DECIMAL, MONEY, TIME, WHITELIST, WORD, PUNCTUATION; other languages add DATE, FRACTION, MEASURE, TELEPHONE, ELECTRONIC, etc.
- **Package size:** `nemo-text-processing` 1.1.0 — sdist 1.7MB, wheel 2.7MB (Python packaging size; **grammar/FAR file size itself was not found published anywhere**, flagged as unverified).
- **Languages:** English, Korean, Portuguese (BR), Japanese, Armenian, Marathi, Telugu, Kinyarwanda, and others — not an exhaustive list from what I found.
- **Swift/mobile port: none found.** No Swift bindings or iOS/macOS packaging exists. The only non-Python path is compiling **Sparrowhawk itself** (C++11, needs OpenFst ≥1.5.4, Thrax ≥1.2.2, re2, protobuf, GNU autotools) plus the exported `.far` grammars into your own binary — technically embeddable via a C++ bridge from Swift, but **Sparrowhawk was archived by Google on Sep 10, 2022** (read-only, unmaintained) — see below.

### B. Google Sparrowhawk

- **What it is:** Google's open-source, stripped-down C++ implementation of the internal **Kestrel** TTS text-normalization system (Ebden & Sproat, "The Kestrel TTS text normalization system," described via ResearchGate: https://www.researchgate.net/publication/277932107_The_Kestrel_TTS_text_normalization_system). Architecture: sentence-boundary detector → tokenizer/classifier (parses tokens into protobuf semiotic structures, e.g. `money { currency: "usd" amount {...} }`) → verbalizer (Thrax-grammar rules render classified tokens as words). https://github.com/google/sparrowhawk/ , docs: https://github.com/google/sparrowhawk/blob/master/documentation/README.md
- **Language:** C++11 (+ some C).
- **License:** Apache 2.0.
- **Maintenance:** **Archived by the owner on Sep 10, 2022 — read-only, no longer maintained.**
- **Build deps:** OpenFst ≥1.5.4, Thrax ≥1.2.2, re2, protobuf; GNU autotools; POSIX/C99/C++11.
- **Standalone C++ usability:** Yes — ships a `normalizer_main` binary taking a config proto + input text; this is exactly the runtime NeMo's own production path uses. Important caveat: **Sparrowhawk ships no grammars of its own** — it's a runtime engine only; you must supply Thrax grammars or NeMo's exported `.far` files.

### C. Kaldi-associated ITN tools

- **No dedicated first-party Kaldi ITN tool was found.** Kaldi's own FST/grammar machinery (`grammar-fst.h`, `make-grammar-fst.cc`, https://kaldi-asr.org/doc/grammar.html) is for **decoding-graph composition** (dynamically stitching HCLG.fst parts for on-the-fly vocabulary/context during ASR decoding), not text normalization.
- Vosk (Kaldi-based toolkit) documentation only mentions its pipeline being "modular" enough for downstream post-processing — implying ITN is left to the integrator, not bundled.
- **This is an absence-of-evidence finding, not a confirmed negative**: in practice, Kaldi-based systems appear to bolt on NeMo-text-processing or Sparrowhawk (both built on the same underlying OpenFst library Kaldi uses) rather than a Kaldi-native ITN tool. Flagging this as inference from what I could and couldn't find, not a verified fact.

### D. text2num and similar lightweight libraries

- **`ghewgill/text2num`** (GitHub) — simple English-only textual-number-to-integer converter. I could not confirm its exact scope (ordinals? decimals?) from the thin README fetch — **flagging as partially unverified**. https://github.com/ghewgill/text2num
- **Allo-Media's `text2num`** (PyPI, a **different, unrelated** more actively maintained project despite the name collision) — v3.1.0, released **Aug 21, 2026**, MIT license. Scope confirmed: cardinals, ordinals, decimals **only** — explicitly does **not** handle currency, percentages, dates, or times. Languages: Danish, Dutch, English, French, German, Italian, Portuguese (BR/EU), Spanish. https://pypi.org/project/text2num/
- **`allo-media/text2num-rs`** (Rust crate, same org) — same scope (cardinals/ordinals/decimals, no currency/dates/times), same languages plus more planned. MIT license. **`#[no_std]` supported**, meaning it's embeddable without a Python runtime — the only genuinely native-embeddable "ITN-adjacent" library I found with a clear license and active maintenance. Claims "very small" latency/resource use but **no published benchmark numbers**. https://github.com/allo-media/text2num-rs
- **For non-number categories (dates/currency/percent) in Swift/C++: nothing purpose-built was found.** Adjacent candidates, all with caveats:
  - **Microsoft Recognizers-Text** — multi-language (10+ languages) recognizer/resolver for numbers, units, date/time, currency. Ships only .NET, JS/TS, and Python packages — **no C++ or Swift target**; would require wrapping. https://github.com/microsoft/Recognizers-Text
  - **Facebook Duckling** (original: Haskell) and its Rust reimplementations **`sonos/rustling`** and a newer **`duckling` Rust crate** (crates.io/docs.rs) — parse numerals, ordinals, time, temperature, distance, volume, quantity, amount-of-money, duration, email, phone, URL, credit-card from text. Caveat: this is **forward parsing into structured data**, not literally spoken-form-text rewriting, so it would need adaptation to act as an ITN rewriter, but the Rust form is a plausible embeddable base with no Python dependency. https://github.com/facebook/duckling, https://github.com/sonos/rustling, https://docs.rs/duckling
  - **`itnpy2`** (PyPI, `barseghyanartur/itnpy`) — standalone rule-based/deterministic Python library, CSV-driven spoken→written token rules, explicitly covers "dates, measurements, money, etc." beyond plain numbers, actively maintained (recent commits/CI), MIT license — but **Python-only**, not usable without a Python runtime in a native macOS app. https://pypi.org/project/itnpy2/0.0.5/
  - **`pl-itn`** (PyPI) — Polish-specific FST-based ITN; found only in passing, not explored further, and not relevant for an English app anyway.

### E. Neural/hybrid on-device ITN (directly relevant even though not classic "rule-based")

- **Microsoft, "Streaming, Fast and Accurate On-Device Inverse Text Normalization for ASR," SLT 2022, arXiv:2211.03721.** Hybrid streaming Transformer tagger + small category-specific WFSTs. Concrete numbers:
  - Model size: proposed **5.5MB total (3.5MB tagger + 2MB FST)** vs. WFST+n-gram baseline 30MB, WFST+n-gram+LSTM 60MB, Seq2Seq-small 6MB, Seq2Seq-large 82.5MB.
  - F1 (text-only eval): proposed **0.82** vs. WFST+n-gram 0.81, WFST+n-gram+LSTM 0.83, Seq2Seq-small 0.76, Seq2Seq-large 0.77.
  - Streaming latency reported only in **token-lookahead units**, not wall-clock ms: chunk-size 11 → 5-token avg latency/F1 0.82; chunk-size 6 → 2.5-token latency/F1 0.81; chunk-size 2 → 0.5-token latency/F1 0.74. **No millisecond or real-time-factor numbers given** — flagged as not found despite being exactly what would be most useful.
  - https://arxiv.org/abs/2211.03721
- **Apple, "Inverse Text Normalization as a Labeling Problem" (Apple Machine Learning Research)** — reformulates ITN as token labeling rather than seq2seq: label spoken-form tokens → apply label-specified edits → FST-based grammar post-processing (FSTs auto-generated from lookup tables). Model: a **bi-directional LSTM** for label prediction. Reported accuracy on Siri utterance samples: **99.46% at 500K training utterances, 99.62% at 1M, 99.85% at 5M**; for heavy-transformation entity types (dates/times/currency), **>90% accuracy at 1M training utterances**. No latency numbers published; no code/model released (Siri-internal). https://machinelearning.apple.com/research/inverse-text-normal
  - This blog post references the earlier **Pusateri, Ambati, Brooks, Platek, McAllaster, Nagesha, "A Mostly Data-Driven Approach to Inverse Text Normalization," Interspeech 2017** (rules + compact bi-LSTM cast as a labeling problem) as the foundational technique, but I was unable to fetch that paper's own PDF/abstract content directly (both the ISCA PDF and the Semantic Scholar page returned empty) — **flagging the exact 2017 paper's own numbers as unconfirmed**; the 99.x% figures above are attributed to the Apple ML blog post specifically, not verified as being from the 2017 paper itself.
  - Also found but not explored in depth: **"Thutmose Tagger: Single-pass neural model for Inverse Text Normalization," arXiv:2208.00064** (NVIDIA) — title/URL only, not fetched for numbers.

### F. Real production data point (comparable product, technique unconfirmed)

- An open-source-adjacent dictation app, **`saurabhav88/EnviousWispr`** (PR #3051), fixed an ITN timeout bug: production telemetry (107,127 takes over 30 days) shows their ITN engine runs at a **steady 13–16 µs per character at the tail** for inputs above ~5,000 characters, with a dynamic timeout of `min(5s, 0.5s + units/40,000)`. This is a genuinely fast, real-world number for a comparable-sized product, but **the underlying ITN technique (WFST, regex, or something else) is not stated** in what I could fetch — flagging this as a real but technique-unattributed data point, useful only as an existence proof that sub-millisecond-per-word ITN is achievable in production, not as evidence for any specific library. https://github.com/saurabhav88/EnviousWispr/pull/3051

---

## Summary of what's unverified/missing (explicitly flagged, not guessed)

- No published wall-clock latency numbers for NeMo-text-processing/Sparrowhawk itself (checked the primary paper directly; absent).
- No FAR/grammar file size numbers for NeMo's English ITN grammar.
- Romana et al. (Interspeech 2022) model/F1 details — PDF unreadable via fetch, abstract only.
- `ghewgill/text2num`'s exact scope (ordinals/decimals) unconfirmed.
- Whether any Kaldi-native (as opposed to bolted-on NeMo/Sparrowhawk) ITN tool exists — likely does not, but this is an absence-of-evidence conclusion, not a sourced negative claim.
- Pusateri et al. 2017's own reported accuracy numbers (as distinct from the Apple ML blog's numbers, which may reflect later/different work) could not be independently confirmed.
- EnviousWispr's underlying ITN technique behind its 13–16 µs/char figure.
