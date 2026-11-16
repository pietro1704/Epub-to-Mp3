# Reader chrome overlays a fixed text viewport

Status: Accepted. Refines the geometry assumption in the
[viewport transition ADR](2026-08-14-reader-viewport-transition.md).

## Context

Resizing the text viewport when showing bars requires pagination and offset
restoration, exposing intermediate frames and flicker. The approved
[Apple experience specification](../apple-native-experience-spec.md) chooses
the chrome-free layout as the permanent reading geometry on Apple platforms.

## Decision

Top and bottom chrome overlay the reader with native materials. Their visibility
changes neither the text viewport nor page boundaries. The reader maintains its
physical-safe-area geometry throughout the reading session. On iOS the status
bar remains hidden while the reader owns the screen, preventing its appearance
from changing that geometry on devices without a sensor housing.

The existing transition module still rejects stale completions and preserves
the exact captured raw offset. Typography, orientation and window-size changes
remain legitimate geometry changes. Page indicators are overlays rather than
pagination-budget reservations.

## Consequences

Visible controls may temporarily cover text beneath their native material,
as explicitly chosen by the product specification. Hiding chrome reveals that
same text in place. AppKit center clicks toggle its overlay chrome; native
selection remains authoritative while selecting text.
