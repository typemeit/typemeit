#!/bin/sh
# Builds diar, the app's Nemotron turn pipeline and FluidAudio's LS-EEND behind a command line, and runs it.
#
#   Scripts/asr-eval/diar/run.sh <nemotron|nemotron-app|lseend-ami|lseend-callhome|lseend-dihard3> <audio.wav>
#   Scripts/asr-eval/diar/run.sh nemotron-app-window <audio.wav> <meeting.json>
#
# SpeakerFrames.swift, SpeakerMerge.swift and SpeakerCount.swift are copied in as they are; the
# few types they reach and the constants are taken from the app's sources, so the Nemotron
# baseline cannot drift from the app.
# FLUIDAUDIO_VERSION builds against another FluidAudio tag (default: the one project.yml pins).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
PINNED="$(awk '/FluidAudio:/ { found = 1 } found && /exactVersion:/ { gsub(/"/, "", $2); print $2; exit }' "$ROOT/project.yml")"
VERSION="${FLUIDAUDIO_VERSION:-$PINNED}"
SCRATCH="$ROOT/build/asr-eval-diar-$VERSION"
mkdir -p "$SCRATCH/Sources/diar"
cp "$ROOT/TypeMeIt/Meetings/SpeakerFrames.swift" "$ROOT/TypeMeIt/Meetings/SpeakerMerge.swift" "$ROOT/TypeMeIt/Meetings/SpeakerCount.swift" \
   "$HERE/Sources/diar/main.swift" "$SCRATCH/Sources/diar/"
sed "s/exact: \"[0-9.]*\"/exact: \"$VERSION\"/" "$HERE/Package.swift" > "$SCRATCH/Package.swift"

python3 - "$ROOT" "$SCRATCH" <<'PY'
import pathlib, re, sys
root, scratch = (pathlib.Path(a) for a in sys.argv[1:3])
settings = (root / "TypeMeIt/Settings.swift").read_text()
constants = {name: re.search(rf"static let {name}(?:: \w+)? = ([\d.]+)\n", settings).group(1) for name in [
    "meetingTurnThreshold", "meetingTurnMinimumMs", "meetingEmbeddingClipSeconds", "meetingMinimumSpeakerSeconds",
    "meetingDiarizerStepRatio", "meetingDiarizerMinOnSeconds", "meetingDiarizerMinOffSeconds",
    "meetingUILagMs", "meetingVoiceClipSeconds", "meetingVoiceClips", "meetingDistinctVoiceDistance"]}
types = {"meetingTurnThreshold": ": Float", "meetingDiarizerStepRatio": ": Double", "meetingDistinctVoiceDistance": ": Float",
         "meetingDiarizerMinOnSeconds": ": Double", "meetingDiarizerMinOffSeconds": ": Double"}
lines = "\n".join(f"    static let {name}{types.get(name, '')} = {value}" for name, value in constants.items())

def block(source, header):
    """The declaration starting at `header`, through its closing brace."""
    start = source.index(header)
    depth = 0
    for i in range(source.index("{", start), len(source)):
        depth += source[i] == "{"
        depth -= source[i] == "}"
        if depth == 0:
            return source[start:i + 1]

app = root / "TypeMeIt"
word = block((app / "Transcriber.swift").read_text(), "struct Word: Sendable, Equatable, Codable {")
is_user = block((app / "Meetings/SpeakerNaming.swift").read_text(), "static func isUser(")
assign_is_user = block((app / "Meetings/SpeakerAssign.swift").read_text(), "static func isUser(_ name: String, userName: String)")
milliseconds = block((app / "Output.swift").read_text(), "extension Duration {")
(scratch / "Sources/diar/Stubs.swift").write_text(f"""struct SpeakerSegment: Codable, Equatable, Sendable {{
    let speaker: String
    let startMs: Int
    let endMs: Int
}}
struct MeetingNames {{
    struct Span: Decodable {{ let name: String; let startMs: Int; let endMs: Int }}
    let roster: [String]
    let spans: [Span]
}}
enum Transcriber {{
{word}
}}
enum SpeakerNaming {{
{is_user}
}}
enum SpeakerAssign {{
{assign_is_user}
}}
{milliseconds}
enum Fixed {{
{lines}
}}
""")
PY

swift build -c release --package-path "$SCRATCH" >&2
BIN="$(swift build -c release --package-path "$SCRATCH" --show-bin-path)/diar"
exec "$BIN" "$@"
