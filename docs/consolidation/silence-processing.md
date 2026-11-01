# Generated-speech silence processing

The shared Rust synthesis sink compacts digital silence before PCM/WAV speech is encoded to MP3. Piper and installed system speech use this sink; the streamed segment and final chapter use the same processed bytes.

## Policy

- Runs of digital zero lasting at least 600 ms retain 300 ms.
- Every nonzero PCM16 sample is preserved, including the quietest possible speech sample. Short pauses and wholly silent responses remain unchanged.
- Cuts occur inside a zero plateau and introduce no new amplitude discontinuity.
- Explicit structural/title pauses are appended after synthesis processing and retain their original duration.
- Processing is bounded to mono PCM16 at 8–96 kHz, at most 120 seconds per segment. Invalid input fails without publishing an output.
- The processing profile is part of segment and chapter cache identities. Old audio cannot be mistaken for compacted output. Existing cancellation/replacement checks run before processing and before cache publication.

## Limits

This is conservative digital-silence compaction, not speech detection or background-noise removal. Preencoded MP3 input remains byte-identical. It does not edit imported recordings, previously downloaded audio or original books.

The historical protected-pauses worktree contains Silero weights and a license but no connected EPUB compaction implementation. The separate course-downloader algorithm combines Silero and WebRTC VAD and is not implemented by this change. No VAD model is loaded or installed here.

See [validation results](validation-results.md) for executed checks and pending app acceptance.
