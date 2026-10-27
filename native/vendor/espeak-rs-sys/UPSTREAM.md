# Vendored eSpeak clause bridge

The local `piper_phonemes.c`/`piper_phonemes.h` compatibility bridge exposes
`espeak_TextToPhonemesWithTerminator` for this vendored eSpeak snapshot.
It delegates decoding and IPA generation to the existing public function, then
copies `translator->clause_terminator`, which `TranslateClause` already records.
The original API and phoneme data are unchanged. CMake builds the bridge into
the same library; bindgen reads its declaration through `wrapper.h`.

This is a local adapter, not a wholesale upstream source update. Its eSpeak
integration is GPL-3.0-or-later like the surrounding C implementation.
The wrapper's caller must serialize voice selection, translation and copying
the returned global buffer. The Rust wrapper owns that transaction.

Punctuation mapping follows `rhasspy/piper-phonemize/src/phonemize.cpp`,
blob `c920a9541609aa59b921b2548158ebcf2a809a31`:
https://github.com/rhasspy/piper-phonemize/blob/master/src/phonemize.cpp
The blob identifier records the reviewed file contents; the URL tracks upstream.
The six clause values and sentence flag come from this snapshot's `translate.h`.
