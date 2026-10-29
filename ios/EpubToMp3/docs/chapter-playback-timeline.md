# Chapter playback timeline

The player clock describes the whole audible chapter. Buffered chunks and
elapsed audio are never used as the chapter's total duration.

When a reader requests listening, it supplies estimates from complete chapter
speech text (reader text when speech text is unavailable), using the existing
200 words-per-minute baseline. Chapter identifiers stay on the zero-based
reader axis. A prepared-reader snapshot can provide only its loaded chapter;
other chapters remain unknown until their source metadata is available.
Unknown totals display a dash and disable the expanded-player slider rather
than presenting a partial buffer as a complete chapter.

`ChapterPlaybackTimeline` owns duration selection and remaining-time arithmetic.
An explicit completed-chapter duration takes precedence over an estimate even
when it is shorter. Otherwise the estimate remains independent of queue length.
Retained segment durations become a measured total only after completion is
confirmed and the complete contiguous chapter has known durations. Chapter
index-base metadata prevents another completed chapter from supplying that total.

Starting from a reader page keeps the chapter estimate and an approximate
chapter-relative starting offset. The generated suffix is never labelled as a
measured whole chapter. This offset remains approximate until full-chapter audio
or trustworthy source timing exists. Book teardown clears estimates and offsets;
chapter activation selects only that chapter's values. Cancelled/replaced source
opens cannot install estimates in another session.

The expanded player retains its existing time convention: elapsed position is
media time; remaining time is wall time at the selected playback rate. The
slider always uses media time. Estimated remaining time shows `≈` and has a
localized accessibility description; measured remaining time omits that marker.
These values are playback time, separate from conversion progress and ETA.

Fast regressions run with `mise run apple:foundation:test`. Native regressions
in `ChapterStreamingTimelineTests` and `ReaderListeningSessionTests` cover the
segment/session seams. Complete native compilation, UI execution and iPhone
acceptance remain deferred to the user's final validation campaign. No visible
journey or red-before native execution is claimed while that campaign is deferred.
Simulator quarantine remains in force.

Seeking into unavailable chunks preserves the selected chapter time and the
offset inside its containing chunk. See [unavailable-audio seeking](unavailable-audio-seek.md).
