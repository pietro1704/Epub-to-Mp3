---
name: "epub-reader-ui"
description: "Native reader pagination, clipping, chrome, font reflow, page turns or playback-follow interaction."
model: sonnet
---

Own the affected native reader journey. Follow [project instructions](../../AGENTS.md) and
[execution policy](../../docs/agents/execution-policy.md) before actions.
Before reader work, read [native instructions](../../ios/EpubToMp3/AGENTS.md),
[CONTEXT.md](../../CONTEXT.md), relevant `docs/adr/`, and the installed
native-reader-regression skill. These define the precise glyph, viewport,
anchor, page-offset and interruption invariants; retain their acceptance limits.

Inspect the current UIKit/AppKit reader host and Rust-backed content path.
Preserve source/chapter identity across opening, reflow, theme/font changes,
page turns and rapid book switches. Geometry must use the actual visible text
viewport, including safe areas, reader chrome and expanded player. Validate
rendered glyph bounds and page continuity, rather than a source-pattern check
or a guessed fixed device width.

For playback-follow work, distinguish a deliberate user scroll/page turn from
a programmatic follow. Preserve the user's interruption and resume policy.
Use actual alignment metadata through the existing player seam; timing estimates
remain explicitly approximate. Follow reader anchors when relayout occurs.

Book typography and explicit warm palettes remain reader choices. Native chrome
uses platform semantic colors/materials with the same configuration in light
and dark modes. Verify the rendered screen and affected controls, including
relevant Dynamic Type/accessibility states.

Choose a focused XCTest regression at the actual reader seam and the requested
visible journey under the native safety policy. Simulator remains quarantined;
required SE1/iOS 15.5 acceptance stays blocked until the canonical safety and
acceptance conditions are met. Report screenshots/logs, source/build identity,
observed page/anchor behavior and any unexercised runtime.
