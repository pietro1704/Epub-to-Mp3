# Plan: fix false/incomplete full-book text validation

## Diagnosis

The reported comparison is not comparing the same text contract:

- `output/The Lord of the Rings/The Lord of the Rings_complete.txt`: 878,078 chars, 29 chapter headers.
- Corresponding `text/*-parsed.txt`: 29 files, 868,139 chars.
- `EbookReader.get_chapter_structure(preserve_all=True)`: 100 chapters and about 3.1M chars because this EPUB contains hierarchical/editorial/alt-text entries.
- The validator reports only 322,530 EPUB chars because `validate_conversion.load_epub_chapters()` uses `ConverterApplication._generate_structure_items()` + `_apply_text_transforms()`, while the converter uses `EbookReader.get_chapter_structure()`, deduplication, and the actual `chapters_for_text` list.

The validator also parses headers from `_complete.txt` and filters the EPUB total by fuzzy title matching. This can silently undercount the expected source. It then reports a size mismatch through the generic “Text was modified during conversion / audio is incomplete” message, conflating source-pipeline mismatch, editorial content, and actual truncation.

The generated parsed text and complete text are close (about 10k chars difference), so this run does not prove missing audio text. It primarily proves validator false-negative risk.

## Implementation steps

1. Extract a shared conversion manifest before TTS:
   - canonical chapter label;
   - canonical title;
   - source text hash/normalized hash;
   - parsed/pre-TTS hashes;
   - included/excluded reason;
   - final audio path.
2. Persist the manifest beside the output text files.
3. Make `validate_conversion.py` load that manifest instead of reconstructing chapters through a second parser/pipeline.
4. Compare:
   - source normalized text → parsed text;
   - parsed/pre-TTS text under an explicit transformation policy;
   - complete file as an ordered concatenation of the manifest chapters.
5. Stop using fuzzy title matching as the primary chapter join key. Use canonical chapter labels from the manifest.
6. Separate validation outcomes:
   - `SOURCE_PIPELINE_MISMATCH`;
   - `CONTENT_TRANSFORMED` (expected/declared formatting changes);
   - `CONTENT_TRUNCATED`;
   - `DUPLICATE_CONTENT`;
   - `AUDIO_MISSING`;
   - `VALID`.
7. Change the CLI message so a size mismatch cannot claim “audio does NOT contain complete text” unless a direct ordered content comparison proves missing source spans.
8. Add regression fixtures for:
   - hierarchical TOC with editorial/alt-text entries;
   - duplicate-looking but legitimate chapters;
   - parser output differing from converter output;
   - expected formatting expansion;
   - true truncation.
9. Re-run the Lord of the Rings conversion validation using the existing output first, then reconvert with a clean cache only if the manifest indicates a real content gap.

## Acceptance criteria

- The validator and converter use the same chapter manifest.
- A complete output with transformed/expanded text is not falsely reported as incomplete.
- A genuinely truncated chapter still fails with the exact chapter and missing span.
- The Lord of the Rings run reports a classified result, not the generic incomplete-audio message.
- `pytest` focused validator/converter tests, full Python tests, and CLI smoke validation pass.
