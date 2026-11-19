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

## Retained source scope

The vendored runtime omits upstream `tests/` (previously disabled by the Rust
build) and `src/windows/` (standalone Visual Studio/COM projects, unused by the
CMake library build). The retired test option and CTest wiring are removed too.
Windows CMake support, including `src/compat/getopt.c`, remains intact.
The CMake install still uses `vim/`, so it is retained together with all language,
dictionary and phoneme data. Runtime phonemization coverage lives in the
`espeak-rs` workspace crate, including punctuation and concurrent voice identity.

## Compatibility shims and MSVC

`src/include/compat/{getopt,unistd,endian}.h` select the system header with
`__has_include_next`. MSVC does not define that macro, and toolset 19.52 and later
reject the unknown macro inside `#if` (C7780, then C1017) where older toolsets read
it as 0. The shims therefore test `defined(__has_include_next)` first and nest the
real test, so an undefined macro falls through to the shim's own declarations or
its `_WIN32` branch, as it always did. With GCC and Clang the preprocessed output
is unchanged. `scripts/test_espeak_msvc_headers.rb` reproduces the MSVC case with
a real preprocessor.
