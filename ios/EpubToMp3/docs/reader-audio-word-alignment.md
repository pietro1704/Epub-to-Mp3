# Measured reader word alignment

The reader must use a word boundary measured by the synthesizer, together with
the media time of the exact current player item. Sentence duration divided by
word length is not word alignment. Older audio without measured boundaries
remains playable with sentence highlighting only.

## Audio contract

Apple's platform adapter records `AVSpeechSynthesisMarker` word ranges and byte
sample offsets while producing PCM. It converts those offsets using the source
audio format and adds an optional RIFF `spch` chunk to the temporary WAV. Its
JSON contains `version: 1`, the utterance `text`, and `words` with UTF-16
`location`/`length` and media-time `start`/`end` in seconds. Unsupported OS/voice
combinations omit the chunk; they never manufacture word times.

Rust validates ranges and times, applies the same sample-coordinate silence
edits to audio and markers, and embeds an array of passages in an ID3 private
frame owned by `epubtomp3.speech-alignment`. Each passage also contains
`audioStart`, initially zero, and an optional `sourceOffset` identifying its
Unicode scalar start in the normalized source chapter. A source offset is bound
only when the measured utterance equals the source segment. Pronunciation
replacement must not silently relabel changed words as source words.

Chapter assembly accumulates the start time of each independent MPEG segment
and replaces the initial private frame with the complete chapter mapping.
Other outer metadata and MPEG audio frames are preserved. ID3v2.3 and v2.4 are
supported because cover publication can rewrite the tag version. The alignment
JSON has a 4 MiB limit.

## Reader contract

Read bounded leading metadata off the main actor and reject a completed read
after the player item changes. Use confirmed advancing media time; playback
rate does not rescale stored times. Short repaint interpolation retains the
current item's measured mapping and cannot survive stale output.

Map utterance tokens to displayed text with flexible whitespace. A unique
utterance can resolve directly. Repeated utterances require a matching source
offset and occurrence order. Ambiguous or missing mappings produce no word
highlight. Painting never mutates annotations, TextKit layout or reader offset.

Page following and explicit play-from-text navigation are separate consumers
of spoken/source locations; this alignment contract does not authorize either
navigation or autoplay.
