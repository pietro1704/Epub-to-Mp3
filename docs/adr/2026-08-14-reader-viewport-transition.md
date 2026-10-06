# Reader viewport transition ownership

**Status:** Accepted

## Context

Showing or hiding reader chrome changes navigation, page-indicator, mini-player
and text-viewport geometry. Historically the reader content controller, its
intermediate host, and the root container each performed part of the same
transition. That exposed ordering constraints, transient geometry, duplicate
preparation, stale completions, flicker, blank gaps, clipped text, and reading
position drift.

## Decision

Use one concrete `ReaderViewportTransition` module as the seam for a chrome
transition. It owns anchor capture, transition generation, restart/idempotence,
final geometry commit, and stale-completion rejection. The root presentation
owner coordinates one layout transaction; reader content and intermediate hosts
are adapters that provide or apply their geometry.

Capture the active text surface's raw `contentOffset` before geometry changes.
Chrome transitions restore that exact offset after the final viewport commits.
They never restore from paginated offsets, progress cache, or a fractional
position. Canonical paginated offsets remain exclusive to explicit page turns.

## Consequences

- TextKit layout, page offsets, scrolling clamps, indicator state, and clipping
  checks run only against committed geometry.
- A later transition generation wins over a stale animation completion.
- Tests cross the transition seam through final viewport, anchor, generation,
  and clipping behavior instead of constraint ordering.
- Keep this module concrete. A protocol would be a hypothetical seam until a
  second real transition adapter exists.
