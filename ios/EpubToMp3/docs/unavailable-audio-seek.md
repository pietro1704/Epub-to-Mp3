# Seeking into unavailable audio

The slider first resolves the selected chapter-relative time against retained,
contiguous audio, loading real segment durations before deciding availability.
Prepared audio keeps its precise in-segment seek. Missing ordinals never occupy
zero seconds, and only a confirmed chapter end permits a final endpoint.

For an active reader listening session, an unavailable slider destination now
permits an approximate text position. The selected time divided by the chapter
duration estimate supplies a text ratio to the existing Rust listening-position
API. Rust generates a new suffix near that position; playback starts at its
first chunk instead of generating the preceding chapter audio. The expanded
player marks this approximate elapsed position with `≈`. It is not a measured
source-to-audio timing map, and no fixed latency guarantee is implied.

`PendingPlaybackSeek` distinguishes chapter time, reader page and approximate
slider navigation. `ReaderListeningSession` accepts only the current request/job
identity and carries autoplay intent through asynchronous file access and job
replacement. Pausing during a restart remains authoritative. New seeks, stop,
book replacement and open failures cannot restore an obsolete request. Saved
reader page defaults never supply the slider destination.

Approximation is enabled only by the active listening coordinator. Other jobs
and transport skips retain exact pending seeks: they release paused queue
capacity so the producer can reach the containing chunk. Reader-page starts
also retain their approximate origin; a precise transport seek from such a
suffix restarts from chapter beginning when necessary.

Native regressions live in `AudioPlayerUnavailableSeekTests` and
`ReaderListeningSeekTests`. Required SE1/iOS 15.5 acceptance remains blocked by
Simulator quarantine; physical-device evidence is tracked separately.
