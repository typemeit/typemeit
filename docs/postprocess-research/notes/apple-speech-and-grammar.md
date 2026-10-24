# Apple SpeechAnalyzer and NSSpellChecker grammar

Research agent report, 2026-09-25 (web sources as cited; claims marked unverified are as the agent flagged them).

All three research threads are back with primary-source citations (Apple's live DocC JSON, WWDC25 session 277, Apple Developer Forums DTS replies, AppKit/Foundation headers, and real shipped GitHub code). Here's the synthesized report.

---

# Speech framework (macOS 26/27) + NSSpellChecker grammar — sourced report

## A — SpeechAnalyzer / SpeechTranscriber / DictationTranscriber

**DictationTranscriber is a real, separate `final class`**, not a preset of `SpeechTranscriber` — confirmed on its own doc page (developer.apple.com/documentation/speech/dictationtranscriber). Apple's WWDC25 rationale: SpeechTranscriber is the new flagship on-device model but isn't available on every platform/locale; DictationTranscriber runs the same model/devices as the old on-device `SFSpeechRecognizer` path, without needing the user to enable Dictation in Settings (developer.apple.com/videos/play/wwdc2025/277/). It has no tvOS support, unlike SpeechTranscriber.

**Caveat that will break copy-pasted WWDC code:** the WWDC25 video's own asset API (`AssetInventory.allocatedLocales` / `.deallocate(locale:)`) and preset name (`.offlineTranscription`) were both renamed before shipping. Current SDK uses `reservedLocales` / `reserve(locale:)` / `release(reservedLocale:)`, and the preset is `.transcription`. Confirmed via current docs plus two independent developers who hit the same compile error (github.com/fal3/claude-skills-collection/issues/2; theswift.dev/posts/transcribe-audio-with-speechanalyzer-in-swift).

**DictationTranscriber + contextualStrings, feeding a buffer** — assembled from independently-verified pieces (no single Apple example wires a raw buffer end-to-end, so flagging the whole assembly as unverified even though each line is confirmed individually):

```swift
// Construction — verbatim, github.com/PureFuncInc/PhemeMurmur/pull/16
let transcriber = DictationTranscriber(
    locale: locale,
    contentHints: [.shortForm],       // vs. the .shortDictation/.phrase presets
    transcriptionOptions: [],         // punctuation is opt-in here — see below
    reportingOptions: [],
    attributeOptions: []
)

// Contextual vocabulary — verbatim, developer.apple.com/forums/thread/811083
// (an Apple engineer confirmed this exact syntax on the same thread)
let context = AnalysisContext()
context.contextualStrings = [
    AnalysisContext.ContextualStringsTag("commands"): [
        "set speed level", "set jump level", "increase speed", "decrease speed",
    ],
    AnalysisContext.ContextualStringsTag("vocabulary"): ["speed", "jump"],
]

// Feeding a finished AVAudioPCMBuffer — AnalyzerInput(buffer:) is a confirmed
// real initializer (developer.apple.com/documentation/speech/analyzerinput).
// UNVERIFIED as a whole: Apple's own finished-input examples all use AVAudioFile.
let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
continuation.yield(AnalyzerInput(buffer: pcmBuffer))
continuation.finish()
let analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], analysisContext: context)
try await analyzer.finalizeAndFinishThroughEndOfInput()
for try await result in transcriber.results { print(String(result.text.characters)) }
```

If a WAV file is an option instead, Apple has a fully-verbatim, confirmed one-function pattern using `SpeechTranscriber(locale:preset: .transcription)` + `analyzer.analyzeSequence(from: audioFile)` + `finalizeAndFinish(through:)` (developer.apple.com/videos/play/wwdc2025/277/, preset name corrected to match current SDK) — no manual buffer/format handling needed.

**contextualStrings specifics:** the type is `[ContextualStringsTag: [String]]`, not a flat array. **DictationTranscriber only** — an Apple engineer stated on the forum thread above that SpeechTranscriber "does not currently take contextual strings into account." No documented count/length cap for the new API (the old `SFSpeechRecognitionRequest.contextualStrings` capped at 100 phrases — developer.apple.com/documentation/speech/sfspeechrecognitionrequest/contextualstrings). `setContext(_:)` fully replaces the prior context each call (confirmed in its doc), so resetting per dictation is free. Evidence it helps is thin: one forum poster couldn't get a proper noun recognized even combined with a trained `SFSpeechLanguageModel`; another gave up and does fuzzy command-matching in post-processing instead (developer.apple.com/forums/thread/811083, /738529) — both anecdotal.

**Formatting:** `SpeechTranscriber.TranscriptionOption` has exactly one case, `.etiquetteReplacements` ("certain words and phrases with a redacted form") — no punctuation/ITN toggle exists at all for it. `DictationTranscriber.TranscriptionOption` adds `.emoji` and `.punctuation` ("Automatically punctuates the transcription"). Since these are opt-in `Set`s, punctuation only happens automatically if you use a preset that bundles it — Apple singles out only `.phrase` as "without punctuation," implying the other five dictation presets include it, but no page lists each preset's exact option contents (unverified inference). No named inverse-text-normalization (digits) option exists anywhere in either type. `.offlineTranscription` and a unified `Options` struct don't exist; `.progressiveTranscription` is real but is a *preset*, not an option.

**Performance:** independent benchmarks disagree. Argmax (M4, earnings-call audio, argmaxinc.com/blog/apple-and-argmax — a vendor selling a competing SDK) put SpeechAnalyzer at 14.0% WER/70x realtime, behind Whisper small.en (12.8%) and Parakeet-v2 (11.7%/359x). Lyonesse (M2 Pro, LibriSpeech, lyonesse.app/blog/apple-speech-api-benchmark.html) instead found SpeechAnalyzer clearly ahead of Whisper Small (2.12% vs 3.74% WER, ~3x faster). No source gives a model download size in MB.

**macOS 27:** confirmed additions are audio-input plumbing only — `AssetInputSequenceProvider`, `CaptureInputSequenceProvider`, `AnalyzerInputConverter` (developer.apple.com/documentation/Updates/Speech). No new formatting/ITN API surface found. Apple's September 2026 newsroom material describes a much-improved on-device Siri dictation model, gated to M3+/12GB+ hardware — nothing in the API docs or forum coverage indicates it's exposed to third-party apps (apple.com/newsroom/2026/09, 9to5mac.com/2026/06/12/ai-advanced-dictation-preview-ios-27-beta).

## B — NSSpellChecker grammar checking

Confirmed signatures (developer.apple.com/documentation/appkit/nsspellchecker): `check(_:range:types:options:inSpellDocumentWithTag:orthography:wordCount:) -> [NSTextCheckingResult]` and `checkGrammar(of:startingAt:language:wrap:inSpellDocumentWithTag:details:) -> NSRange`. `NSGrammarRange`, `NSGrammarUserDescription`, `NSGrammarCorrections` are real constants from `NSSpellServer.h`, unchanged since macOS 10.5; `NSGrammarCorrections` holds `[String]` candidate replacements, and Apple's docs state one of it or `NSGrammarUserDescription` must be present for anything to reach the user.

**No real end-to-end Swift example exists anywhere** applying an `NSGrammarCorrections` suggestion back into text — constructed here from the verified pieces above:

```swift
let checker = NSSpellChecker.shared
let tag = NSSpellChecker.uniqueSpellDocumentTag()
var detailsRef: NSArray?
let sentenceRange = checker.checkGrammar(of: text, startingAt: 0, language: "en",
                                          wrap: false, inSpellDocumentWithTag: tag, details: &detailsRef)
var result = text as NSString
for entry in (detailsRef as? [[String: Any]]) ?? [] {
    guard let rel = (entry[NSGrammarRange] as? NSValue)?.rangeValue,
          let fix = (entry[NSGrammarCorrections] as? [String])?.first else { continue }
    let abs = NSRange(location: sentenceRange.location + rel.location, length: rel.length)
    result = result.replacingCharacters(in: abs, with: fix) as NSString
}
```

**Real-world catch rate is weak.** A Swift Forums tester ran `checkGrammar` against three broken sentences: it flagged a fragment ("The is anyone.") but missed "Can I has pie?" and "This will be happened," while TextEdit's own visible checking — apparently a separate, non-public path — caught all three (forums.swift.org/t/how-does-nstextview-invoke-grammar-checking-internally/84832). No test of "their/there/you're"-style homophone errors against this API was found anywhere — not confirmed either way. Grammar checking is **English and Spanish only** (support.apple.com/en-euro/guide/mac-help/mchlp2299). Apple's Thread Safety Summary never mentions NSSpellChecker; its async variant fires completion "in an arbitrary context" (not guaranteed main-thread), but a GitHub issue reports a deadlock when `.shared` is first touched off the main thread (github.com/can1357/oh-my-pi/issues/12084) — touch it on main first. No speed benchmarks exist anywhere.

**No known use for ASR post-processing specifically.** The one real dictation app found using NSSpellChecker (vocamac, github.com/VocaHQ/vocamac/pull/290) uses it only for spelling/word-validity checks, not grammar; every project doing grammar/style cleanup on dictated text reaches for LanguageTool, Harper, or an LLM instead.
