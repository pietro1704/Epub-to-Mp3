# Paginated reader reserves the bars' space

Status: Accepted (owner request, 2026-11-23). Supersedes, for paginated layout only, the "chrome overlays the text"
consequence of the [chrome overlays ADR](2026-11-12-reader-chrome-overlays.md); the viewport-transition and
paginated-layout ADRs still apply.

## Context

With the chrome visible, the first and last text lines sat half behind the top bar and the mini player and were cut
(reported on the iPhone 16e). Overlaying was chosen so that toggling the bars never moves the text, but it let the
bars hide text. The owner asked for text that is ALWAYS below the top bar and above the mini player and never moves
when the chrome is shown or hidden.

## Decision

In paginated layout the text surface is a fixed viewport that reserves the bars' space permanently: its top edge is
the top bar's bottom edge (plus the existing content spacing) whether the bar is visible or not, and its bottom edge is
the mini player's top edge while the mini player exists (the same clearance the other screens use). Showing or hiding
the bars only fades them; the surface's frame, page boundaries and raw `contentOffset` do not change. Scrolling layout
keeps the overlay behaviour. The page indicator is a capsule whose colours contrast with the page (>= 4.5:1 in every
theme and appearance).

## Consequences

Hiding the chrome no longer reveals extra text lines at the screen edges; the reading area is slightly smaller than a
chrome-free page. Starting or stopping narration changes the bottom reserve once (the mini player appears or goes),
which is a legitimate geometry change handled by the existing viewport transition.
