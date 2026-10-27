# Piper punctuation and sentence boundaries

Piper consumes punctuation as phoneme tokens. eSpeak's ordinary
`espeak_TextToPhonemes` returns IPA without those tokens; clause punctuation is
separate metadata. Searching the IPA string for punctuation silently loses
sentence boundaries and joins neighboring clause words.

The embedded wrapper uses a small terminator-aware C bridge and restores
period, question mark, exclamation mark, comma, colon and semicolon using the
same mapping as [upstream Piper phonemization](https://github.com/rhasspy/piper-phonemize/blob/master/src/phonemize.cpp).
Subclauses include a separating space. Sentence metadata closes each output
sentence; punctuation is not guessed by splitting the source text. Decimal
commas, language-specific parsing and UTF-8 remain eSpeak's responsibility.
EOF and paragraph terminators close a sentence without inventing a period.
Piper joins these sentence outputs before inference, preserving punctuation.

The Rust wrapper serializes voice selection, clause decoding and copying the
global C buffer so concurrent callers retain their requested voice and text.
Translation failures return an error instead of retrying a non-advancing clause.
This does not change providers, model artifacts, noise/length scales or chunk
size. Faber remains the default. It does not establish that another model is
necessary or that 800 characters is an optimal Piper input size.

Run `mise run piper:phonemes:test` for the model-free runtime regressions.
The crate is an explicit workspace member, so the required Rust CI workspace
test step executes them. Tests exercise real eSpeak with Portuguese sentences,
subclauses, accents, decimal commas, EOF, invalid requests and concurrent voices.
English separators, language-marker removal and Arabic output remain covered;
Arabic assertions avoid depending on a specific installed dictionary revision.
The eSpeak build provides phoneme data on the host; CI supplies packaged data
through `PIPER_ESPEAKNG_DATA_DIRECTORY`.

Existing generated audio is preserved; this correction applies to new synthesis.
These tests establish punctuation reaching Piper's input, not audible quality.
Acceptance still requires listening to the same Portuguese prose/dialogue on
the native app, checking pauses, expression and chunk continuity. Device and
audible acceptance are deferred to the final iPhone validation campaign.
