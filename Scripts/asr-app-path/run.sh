#!/bin/sh
# Builds appasr, the app's own Transcriber behind a command line, and runs it.
#
#   Scripts/asr-app-path/run.sh <dictation|meeting> <items.json> <out.json> [--terms terms.json] [--boost] [--matcher] [--repeat N]
#
# The app's sources are copied into build/asr-app-path as they are, with only the few
# types they reach stubbed (the model folder, the audio format, constants taken from
# the app's own sources), so the constants cannot drift. A system for Scripts/asr-eval
# is one subprocess call to this, the way systems/fluid_ultra.py calls fluidasr.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRATCH="$ROOT/build/asr-app-path"

python3 - "$ROOT" "$HERE" "$SCRATCH" <<'PY'
import pathlib, re, shutil, sys
root, here, scratch = (pathlib.Path(a) for a in sys.argv[1:4])
app = root / "TypeMeIt"
sources = scratch / "Sources/appasr"
sources.mkdir(parents=True, exist_ok=True)
for name in ["Transcriber.swift", "Log.swift", "DebugLog.swift", "CustomWordMatcher.swift", "EnglishWord.swift", "LocalCleanup.swift", "ModelText.swift",
             "Plural.swift", "ClockTime.swift", "Digits.swift", "WritingStyle.swift", "Meetings/ChunkStitch.swift", "Meetings/ChunkCutter.swift", "Meetings/QuietSpeech.swift"]:
    shutil.copy(app / name, sources / pathlib.Path(name).name)
shutil.copy(here / "Sources/appasr/main.swift", sources / "main.swift")
shutil.copy(here / "Sources/appasr/Boost.swift", sources / "Boost.swift")
shutil.copy(here / "Package.swift", scratch / "Package.swift")

# Vocabulary boosting hook: Boost.session is nil unless main.swift sets it (--boost), so the
# app path is unchanged by default. Only the scratch copy of Transcriber.swift is edited.
transcriber = sources / "Transcriber.swift"
text = transcriber.read_text()
old = "        return Transcript(words: Transcriber.words(from: timings.map { Token(text: $0.token, confidence: $0.confidence, start: $0.startTime, end: $0.endTime) }))"
new = """        let heard = Transcriber.words(from: timings.map { Token(text: $0.token, confidence: $0.confidence, start: $0.startTime, end: $0.endTime) })
        guard Boost.session != nil else { return Transcript(words: heard) }
        return await Boost.rescored(heard: heard, text: result.text, timings: timings, pcm: pcm)"""
assert old in text
transcriber.write_text(text.replace(old, new))

# Threshold sweeps: the scratch copy of CustomWordMatcher reads TUNE_CONFIDENT, so `appasr rematch`
# can try a setting without rebuilding. Unset, the value is the app's own.
matcher_path = sources / "CustomWordMatcher.swift"
matcher = matcher_path.read_text()
old = "static let confidentAbove: Float = 0.9"
assert old in matcher
matcher_path.write_text(matcher.replace(old, 'static let confidentAbove: Float = Float(ProcessInfo.processInfo.environment["TUNE_CONFIDENT"] ?? "") ?? 0.9'))

def block(source, header):
    start = source.index(header)
    depth = 0
    for i in range(source.index("{", start), len(source)):
        depth += source[i] == "{"
        depth -= source[i] == "}"
        if depth == 0:
            return source[start:i + 1]

settings = (app / "Settings.swift").read_text()
store = (app / "ModelStore.swift").read_text()
envelope = re.search(r"static let peakEnvelopeMs = (\d+)", (app / "Meetings/MeetingTranscriber.swift").read_text()).group(1)
version = re.search(r'static let version = "([^"]+)"', store).group(1)
(sources / "Stubs.swift").write_text(f"""import AVFoundation
import Foundation

final class ModelStoreStub {{ func modelLoaded() {{}} }}
enum ModelStore {{
    static let shared = ModelStoreStub()
    static let version = "{version}"
    static let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TYPEMEIT_ASR_DIR"]
        ?? NSHomeDirectory() + "/Library/Application Support/TypeMeIt/models/asr/\\(version)")
}}
enum AudioCapture {{
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
{block((app / "AudioCapture.swift").read_text(), "    static func peak")}
}}
enum MeetingTranscriber {{ static let peakEnvelopeMs = {envelope} }}
{block(settings, "enum AppVersion")}
{block(settings, "enum Fixed")}
{block((app / "Output.swift").read_text(), "extension Duration")}
""")
PY

swift build -c release --package-path "$SCRATCH" >&2
BIN="$(swift build -c release --package-path "$SCRATCH" --show-bin-path)/appasr"
exec "$BIN" "$@"
