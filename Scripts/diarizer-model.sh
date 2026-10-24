#!/bin/sh
# Fetches the speaker models' files from the Hugging Face revisions pinned in
# the Makefile, with the terms the weights ship under, and packs them into one
# reproducible tar for typeme.it (docs/meetings.md 8.2). The app downloads
# that tar, hash-pinned, and never touches Hugging Face itself.
#
#   Scripts/diarizer-model.sh <pyannote revision> <nemotron revision> <out dir>
#
# Writes <out dir>/speaker-diarization/... (the offline pipeline FluidAudio
# pins), <out dir>/nemotron-3-diarization/... (Nemotron 3 Diarization's
# offline preset) and <out dir>/speaker-models-<revision prefixes>.tar.
set -eu

REVISION="$1"
NEMOTRON_REVISION="$2"
OUT="$3"
REPO="FluidInference/speaker-diarization-coreml"
NEMOTRON_REPO="FluidInference/nemotron-3-diarization-coreml"
# Where DiarizerModelStore.nemotronFolder looks.
NEMOTRON_FOLDER="nemotron-3-diarization"
# The folder name FluidAudio's `Repo.diarizer.folderName` resolves to.
FOLDER="speaker-diarization"
DIR="$OUT/$FOLDER"
TAR="$OUT/speaker-models-$(printf '%s' "$REVISION" | cut -c1-8)-$(printf '%s' "$NEMOTRON_REVISION" | cut -c1-8).tar"

mkdir -p "$DIR"
# Everything the offline pipeline loads (ModelNames.OfflineDiarizer.requiredModels), plus the terms.
curl -fsSL "https://huggingface.co/api/models/$REPO/tree/$REVISION?recursive=true" |
python3 -c '
import json, sys
want = ("Segmentation.mlmodelc", "FBank.mlmodelc", "Embedding.mlmodelc", "PldaRho.mlmodelc")
for e in json.load(sys.stdin):
    if e["type"] != "file": continue
    p = e["path"]
    if p.split("/")[0] in want or p in ("plda-parameters.json", "NOTICE.md", "LICENSE"):
        print(p)
' | while read -r path; do
    mkdir -p "$DIR/$(dirname "$path")"
    curl -fsSL "https://huggingface.co/$REPO/resolve/$REVISION/$path" -o "$DIR/$path"
    echo "  $path"
done

# FluidAudio only trusts files under a pinned revision when the folder
# carries this marker with that revision (ModelCache.matchesRevision).
printf '%s\n' "$REVISION" > "$DIR/.fluidaudio-revision"

# Nemotron's offline preset, flattened to what Nemotron3Models.load(config:directory:)
# reads: the compiled bundle and the silence embedding side by side. The
# README carries the weights' licence (OpenMDW 1.1).
NEMOTRON_DIR="$OUT/$NEMOTRON_FOLDER"
mkdir -p "$NEMOTRON_DIR"
curl -fsSL "https://huggingface.co/api/models/$NEMOTRON_REPO/tree/$NEMOTRON_REVISION?recursive=true" |
python3 -c '
import json, sys
for e in json.load(sys.stdin):
    if e["type"] != "file": continue
    p = e["path"]
    if p.startswith("monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/") or p in ("learnable_sil_emb.bin", "README.md"):
        print(p)
' | while read -r path; do
    local_path="${path#monolithic/v2/}"
    mkdir -p "$NEMOTRON_DIR/$(dirname "$local_path")"
    curl -fsSL "https://huggingface.co/$NEMOTRON_REPO/resolve/$NEMOTRON_REVISION/$path" -o "$NEMOTRON_DIR/$local_path"
    echo "  $local_path"
done

# A deterministic tar: sorted entries, no owner, epoch timestamps, so the
# same revision always hashes the same.
python3 - "$OUT" "$TAR" "$FOLDER" "$NEMOTRON_FOLDER" <<'EOF'
import os, sys, tarfile
out, tar_path, *folders = sys.argv[1:]
def clean(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    return info
with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
    for folder in folders:
        for dirpath, dirnames, filenames in os.walk(os.path.join(out, folder)):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                tar.add(full, arcname=os.path.relpath(full, out), filter=clean)
EOF
echo "$TAR"
