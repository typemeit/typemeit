#!/bin/sh
# Fetches the speech model's Core ML files from the Hugging Face revision
# pinned in the Makefile, with the terms the weights ship under, and packs
# them into one reproducible tar for typeme.it. The app downloads that tar,
# hash-pinned, and never touches Hugging Face itself.
#
#   Scripts/asr-model.sh <revision> <out dir>
#
# Writes <out dir>/parakeet-ultra-<revision prefix>/... and
# <out dir>/parakeet-ultra-<revision prefix>.tar. The folder is what
# `AsrModels.loadLocal(from:version:)` reads: the four compiled models and
# the vocabulary side by side.
set -eu

REVISION="$1"
OUT="$2"
REPO="FluidInference/parakeet-ultra-coreml"
NAME="parakeet-ultra-$(printf '%s' "$REVISION" | cut -c1-8)"
DIR="$OUT/$NAME"
TAR="$OUT/$NAME.tar"

mkdir -p "$DIR"
# ModelNames.ASR.requiredModelsV3 for AsrModelVersion.ultra, the vocabulary,
# and the model card, which carries the licence (CC-BY-4.0).
curl -fsSL "https://huggingface.co/api/models/$REPO/tree/$REVISION?recursive=true" |
python3 -c '
import json, sys
want = ("Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc")
for e in json.load(sys.stdin):
    if e["type"] != "file": continue
    p = e["path"]
    if p.split("/")[0] in want or p in ("parakeet_vocab.json", "README.md"):
        print(p)
' | while read -r path; do
    mkdir -p "$DIR/$(dirname "$path")"
    curl -fsSL "https://huggingface.co/$REPO/resolve/$REVISION/$path" -o "$DIR/$path"
    echo "  $path"
done

# A deterministic tar: sorted entries, no owner, epoch timestamps, so the
# same revision always hashes the same.
python3 - "$OUT" "$TAR" "$NAME" <<'PY'
import os, sys, tarfile
out, tar_path, folder = sys.argv[1:]
def clean(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    return info
with tarfile.open(tar_path, "w", format=tarfile.USTAR_FORMAT) as tar:
    for dirpath, dirnames, filenames in os.walk(os.path.join(out, folder)):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            tar.add(full, arcname=os.path.relpath(full, out), filter=clean)
PY
echo "$TAR"
