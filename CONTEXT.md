# Ubiquitous Language

## Repository trust surface

The collection of repository-facing automation, documentation, hooks, and
governance that contributors rely on to make and review changes safely.

## Evidence gate

The reviewable proof required before an issue may be closed: applicable local
validation, CI evidence for the exact commit, and any platform-specific
validation that the change requires.

## Wiki publication contract

The explicit safety boundary for synchronizing versioned documentation to the
external GitHub Wiki: preflight, displayed external diff, confirmation, and
recoverable failure behavior.

## Product runtime change

A change to user-facing application behavior, such as the macOS embedded
runtime. It is not a repository trust-surface change and requires product
validation on its own delivery path.

## Progressive playback

Playback of audiobook chapters as their audio becomes available during a
conversion, without waiting for the complete book.

## Offline listening cache

The durable local collection of audio chapters that have been played or
explicitly downloaded. It is retained so playback remains available offline,
including when a listener completes a book through progressive playback without
requesting a separate full download. It is protected from automatic TTL and LRU
eviction; only the listener removes it.

A chapter enters this cache when playback of its first streamed segment becomes
audible; its incoming segments are assembled into the chapter's final audio
file. If conversion is interrupted after that point, the durable-retention
intent persists until a valid final file is available or the listener removes
the download.

## Rebuildable performance cache

Derived reader text, normalized PDF pages, partial audio buffers, and completed
conversion artifacts that reduce latency but can be reconstructed. It has its
own bounded LRU-and-TTL budget and never evicts Offline listening cache content.

## Playback-first resource policy

The rule that reading, a pending navigation, and audible playback take priority
over conversion throughput. Conversion yields under interaction, low-power,
memory-pressure, or thermal conditions, then resumes aggressive use only after
the listener-visible path is stable.

## Warm book open

Reopening an imported book whose reader content and playback state have already
been prepared. A warm open restores readable content, the saved reading
position, and usable audio controls without reparsing the source document or
reconstructing the playback session.

Warm opens persist across app relaunches until the listener removes the book.
They are an Apple-client contract for iPhone, iPad, and macOS. The target is a
perceptually instant open: readable content and audio controls within 200 ms.

## Cold book open

The first open of an imported book, when the source document has not yet been
prepared for the reader. Cold-open work may continue in the background after
the reader becomes usable, but it must establish the assets required by later
warm opens.

## Performance program

A cross-client effort to improve observable application speed through explicit
latency budgets. It sequences the Apple client and conversion backend before
the web and Flutter clients, and prioritizes perceived readiness and playback
stability. Conversion may use available CPU and memory aggressively only while
it does not degrade reading or playback responsiveness.

## Latency observation

A monotonic, correlated record of one listener-visible transition: the
initiating gesture, the relevant ready state, and the elapsed time between
them. The same vocabulary applies across clients; for streaming playback it
keeps audio queued and audio audible as distinct ready states.

## Navigation seek

Playback controls that seek a fixed interval within the current chapter and
navigate to the previous or next chapter at its boundaries.

The forward and backward intervals are independently configurable as 15, 30,
45, or 60 seconds. The selected values apply consistently to the mini player,
expanded player, system widget and Lock Screen controls.

Both intervals default to 15 seconds and persist independently across app
launches.

## Pending navigation

A requested seek or chapter transition whose target audio is not yet available
during progressive playback. The request is retained, the target becomes the
highest conversion priority, and playback starts automatically when its first
segment is available.

## Chrome-stable reader viewport

Showing or hiding reader chrome changes only the viewport height. It must preserve
the reader's exact `contentOffset` for the active text surface; it must not round
that offset to a paginated boundary or replace it from the paginated-offset cache.
Those boundaries depend on viewport height and cause repeated chrome toggles to
move the book backward or forward. During a chrome transition, the raw viewport
offset is the source of truth. Pagination boundaries remain for explicit page turns
only, and glyph-aware layout must ensure no partially rendered line is shown.

## Reader text viewport

The final visible text presentation for one committed reader geometry. It
preserves the reading anchor while exposing page, clipping, and fallback facts
for the active text surface.
