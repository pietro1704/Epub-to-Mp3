//! Usage text for the native CLI.

pub(super) const HELP: &str = "EBook to Audiobook Converter

Usage: convert [INPUT ...] [OPTIONS]
       clear-cache [BOOK]

Inputs accept EPUB and text PDF files, directories, loose multiword names, and fuzzy matches.

Preferences: preferences show | preferences set JSON
Models: models list | models install MODEL_ID | models remove MODEL_ID --yes

Voice options:
  --tts-preferences-json JSON   per-job snapshot; exclusive of other TTS options
  --engine {edge,piper,system}  --fallback-engine {none,edge,piper,system}
  --allow-online-fallback | --no-online-fallback
  --voice VOICE  --model MODEL
  --fallback-voice VOICE        requires --fallback-engine
  --fallback-model MODEL        requires --fallback-engine and a model for that engine

Chapter selection (CHAPTER is a chapter index such as 3 or 1.2, or position:N, zero-based):
  --chapter CHAPTER             repeatable
  --from-chapter-to-end CHAPTER convert from CHAPTER to the last chapter
  --from-chapter-to-chapter A..B
                                convert the inclusive range; exclusive of --from-chapter-to-end.
                                Bounds also accept title snippets; A:B and A,B remain accepted.
                                With --chapter, only matching chapters inside the range convert.
                                An unknown or reversed range fails before anything is written.

Conversion:
  --force-reprocess             ignore cached audio and synthesize the selected chapters again
  --retry-failed N              after a failed conversion, retry the job up to N rounds, reusing
                                completed chapters (default 0: no retry round)
  --retry-failed-manual         one more retry pass after the --retry-failed rounds
  --verify                      check the output of this conversion
  --output-dir DIR  --no-parallel  --clean-cache  --batch PATH  --batch-file FILE  --yes

Existing output (no new conversion; exit status 1 when issues remain):
  --verify-only                 audit the newest existing output of each book against the book
  --fix                         audit, then reconvert only the chapters that failed the audit;
                                accepts --retry-failed and --retry-failed-manual
                                Source bytes must match the recorded identity; legacy outputs
                                without that identity are left untouched and reported unverified.

Other: --show-structure  --help";

pub(super) fn print_help() {
    println!("{HELP}");
}
