# Glyph-aware paginated text layout

**Status:** Accepted

## Context

Paginated TextKit content can visually extend beyond a line fragment through
descenders, diacritics, emoji, attachments, and font metrics. Calculating page
offsets from generic content height or filtering only complete lines allowed a
partial glyph at a viewport edge and produced false-green clipping probes.

## Decision

Make `ReaderPaginatedTextLayout` the deep module for pagination decisions. Its
result owns content height, canonical page offsets, protected text fragments,
and validation data. Reader presentation applies that result rather than
repeating TextKit geometry or coordinate conversion.

A protected fragment conservatively includes both the line-fragment rectangle
and rendered glyph bounds. A page begins only at a protected-fragment boundary.
The layout reserves trailing content height needed to reach the final canonical
page start; it must not append a generic maximum scroll offset that can fall
inside a fragment.

If one protected fragment exceeds a page capacity, report an oversized-fragment
condition and choose a non-clipping fallback. A visual overflow mask is a
defense-in-depth treatment, never proof that a partial page is valid.

## Consequences

- Every rendered glyph is wholly visible on its page or moves to the next one.
- The UI probe examines all visible protected fragments, including partial
  candidates, and reports clipping as a failure.
- Unit and UI tests validate the same pagination decision through one seam.
- Keep the module concrete while TextKit is the sole adapter.
