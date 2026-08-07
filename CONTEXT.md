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
requesting a separate full download.

A chapter enters this cache when playback of its first streamed segment starts;
its incoming segments are assembled into the chapter's final audio file.

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
