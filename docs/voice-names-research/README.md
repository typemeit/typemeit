# Voice names research

The measurements behind docs/meetings.md 8.7, run on 6 October 2026 against
the release app's own meetings. Scripts only: the embeddings they write are
real people's voices and stay out of git (`out/` is ignored).

    uv run --python 3.11 --with numpy --with scikit-learn --with coremltools python extract.py

| Script | What it does |
|---|---|
| `emb.py` | The app's WeSpeaker model (`FBank` + `Embedding` from the installed diarizer) called the way FluidAudio's `embedSpan` calls it: `EMBED=tile` (default, the app since 22 October) or `EMBED=pad` (before) |
| `extract.py` | Labelled clips from every recorded call and every dictation, embedded, to `$OUT/rows.json` and `$OUT/vecs.npy` |
| `naming.py` | Each call named from the other calls; then each voice's person removed to score it as a stranger. scikit-learn, the app's gradient descent and nearest centroid side by side |
| `roster.py` | The same with candidates narrowed to the call's roster (it lets strangers through) |
| `parity.py` | The app's gradient descent against scikit-learn, and the export a Swift copy of `VoiceNames.Model` was checked against |
| `modes.py` | Padded against tiled clips, from `EMBED=pad OUT=out/pad` and `EMBED=tile OUT=out/tile` runs of `extract.py`: how alike the two are by clip length, then the app's gradient descent with strangers and posterior cuts for each, and padded voices asked about tiled clips |
| `suggest.py` | Every suggestion the app would show, from a data folder the dev app learned into (`SUPPORT`) |
