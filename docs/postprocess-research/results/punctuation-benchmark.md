# Punctuation benchmark

120 of the author's real dictations that Parakeet had punctuated (8–80 words, no digits, no fillers), with punctuation and case stripped, then restored by each method and scored word-aligned against Parakeet's own punctuation. The reference is the recogniser's punctuation, not a human's. The sentences are private and not stored.

| method | sentence-end F1 (P / R) | comma F1 | question F1 | casing accuracy | words changed | time per sentence |
|---|---|---|---|---|---|---|
| pcs_en (1-800-BAD-CODE) | 0.59 (0.53 / 0.65) | 0.46 | 0.55 | 0.952 | 0.5% | ~69 ms (ONNX CPU, Python) |
| sherpa-onnx CNN-BiLSTM (7 MB) | 0.65 (0.58 / 0.73) | 0.45 | 0.57 | 0.963 | 0.0% | ~12 ms (ONNX CPU, Python) |
| Apple model via current clean-up path | 0.30 (0.52 / 0.21) | 0.35 | 0.25 | 0.924 | 2.3% | ~1116 ms (cold session) |
| none | 0.00 (0.00 / 0.00) | 0.00 | 0.00 | 0.893 | 0.0% | 0 |

On the eval, punctuating first (before the code passes) cost 11–27 cases: the models put commas inside spoken digit runs ("oh, 7, 7, 1…"), between a pronoun and its verb ("I, have booked"), and capitals after commas, which break the code passes. Punctuating last, on the lowercased text, with the heard casing kept mid-sentence and trailing commas dropped, costs nothing on the eval (327/335, same as no punctuation). sherpa needs lowercase input: given capitals it adds a comma after them ("Can, you").
