You are judging differences between speech-recognition transcripts. You cannot hear the audio; judge the text only.

Input: {in}
Each line is one disputed span from a recorded meeting or dictation: `before` and `after` are the surrounding words (lower-case, no punctuation), and `readings` are the competing versions of the disputed stretch, each with the systems that wrote it ("assemblyai" is the reference transcript; an empty `text` means that system wrote nothing there).

For every span, decide whether choosing between the readings changes what the speaker meant, and what kind of difference it is. Write one JSON line per span, in input order, to:
{out}

Each output line: {"judgeKey": "<the span's judgeKey, copied exactly>", "matters": true|false, "kind": "<kind>", "note": "<at most 12 words>"}

`matters` is true when a reader of the transcript would understand something different depending on which reading is right: a different content word, added or missing content, a negation, a different name or number value, a different subject or tense that changes the claim. It is false when every reading says the same thing.

`kind` is exactly one of:
- "filler": um, uh, erm, er, ah, hmm, mm, and filler uses of like / you know / i mean / sort of
- "repeat": a word or phrase said twice in a row ("i i think", "we we should")
- "false_start": an abandoned start or self-correction ("we should- let's go")
- "function_word": a, the, and, so, just, but, that, of, to and similar words whose presence does not change the meaning
- "form": the same words written differently: spelling, contraction, number written as digits vs words, hyphenation, a compound split or joined, plural/singular with no change of meaning
- "content": anything that changes meaning (use this whenever matters is true, unless "name" or "negation" fits better)
- "name": a person, product or place name differs
- "negation": one reading negates the other

When a span mixes several differences, judge by the most important one: if any reading changes the meaning, matters is true. Rules: judge every span, one output line per input line, in order; do not skip. Do not guess which reading is correct; only whether the choice matters and what kind it is. Never quote more than 12 words of transcript in a note. Do not write any other file. When done, reply with only: lines written, matters true, and the count per kind.
