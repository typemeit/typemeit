#!/bin/sh
# Fetches the offline diarizer's model files from the Hugging Face revision
# FluidAudio pins, with the NOTICE and LICENSE the weights ship under, and
# packs them into one reproducible tar for a GitHub release (docs/meetings.md
# 8.2). The app downloads that tar, hash-pinned, and never touches Hugging
# Face itself.
#
#   Scripts/diarizer-model.sh <revision> <out dir>
#
# Writes <out dir>/speaker-diarization/... and
# <out dir>/speaker-diarization-<revision prefix>.tar.
set -eu

REVISION="$1"
OUT="$2"
REPO="FluidInference/speaker-diarization-coreml"
# The folder name FluidAudio's `Repo.diarizer.folderName` resolves to.
FOLDER="speaker-diarization"
DIR="$OUT/$FOLDER"
TAR="$OUT/$FOLDER-$(printf '%s' "$REVISION" | cut -c1-8).tar"

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

# A deterministic tar: sorted entries, no owner, epoch timestamps, so the
# same revision always hashes the same.
python3 - "$OUT" "$FOLDER" "$TAR" <<'EOF'
import os, sys, tarfile
out, folder, tar_path = sys.argv[1:]
def clean(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    return info
with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
    root = os.path.join(out, folder)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            tar.add(full, arcname=os.path.relpath(full, out), filter=clean)
EOF
echo "$TAR"
