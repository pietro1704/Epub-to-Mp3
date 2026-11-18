# Rust audio runtime

`converter-core::audio` probes and validates audio in process with Symphonia.
The native build enables its supported codecs and containers; it does not
invoke `ffprobe` or `ffmpeg`. This is not a promise to accept every format that
FFmpeg can inspect. Conversion providers deliver MP3 or PCM WAV. Invalid or
unsupported artifacts return an audio validation error before publication.

MP3 frame extents, concatenated stream boundaries and RIFF chunk extents retain
their dedicated validation before decoding. Duration is based on decoded
samples, not a container's rounded bitrate estimate. PCM-to-MP3 encoding uses
the shared `rusty_mp3` path; finalization preserves compressed MPEG payloads.

Cover attachment uses ID3 and preserves existing metadata, unrelated pictures
and audio samples. JPEG, PNG, WebP, BMP and GIF are decoded under the image
limits. TIFF is retained without color conversion: bounded directories,
dimensions, sample budgets and strip/tile extents are validated for every
image, including subsampled YCbCr that the RGB image adapter cannot decode.
This preserves the former TIFF stream-copy capability; it does not claim full
decompression validation of TIFF payloads. Covers are limited to 16 MiB
compressed, 8192 pixels per dimension and a 64 MiB decoded-image budget.
TIFF additionally has a 64-image ceiling and a cumulative sample budget.

Tagging writes to a unique temporary file, validates the resulting audio and
atomically replaces the original only after success. Invalid cover/audio input
leaves the previous file intact. Unsupported cover formats fail explicitly.

`crates/converter-core/tests/in_process_audio.rs` runs with external commands
replaced by a failing sentinel. Retained legacy cover fixtures compare MIME
types and exact attached bytes; MPEG payload, metadata, repeat application and
failure preservation are checked separately. Fixture provenance is recorded in
`crates/converter-core/tests/fixtures/audio-cover-reference.md`.

FFmpeg may still be used as an independent development/test oracle. Neither
the production Rust audio path nor the server runtime image requires it or
libsndfile.
