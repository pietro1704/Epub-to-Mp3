# Native Apple Surface Inventory

Type: research
Status: resolved
Claimed by: native app architecture specialist
Blocked by:

## Question

What native iOS, iPadOS, and macOS surfaces exist today, which controllers own each one, and which concrete UI/UX deviations or architectural constraints must be resolved before strict HIG conformance can be planned? Separate platform-specific behavior from shared services.

## Comments

- Created while charting the Native Apple HIG Experience map.

## Answer

The surface and ownership inventory is recorded in [Native Apple Surface Inventory](../research/native-apple-surface-inventory.md). The first implementation priority is the reader/root/mini-player composition on iOS and iPadOS, followed by macOS toolbar/menu/sidebar behavior; UIKit and AppKit layouts remain separate.
