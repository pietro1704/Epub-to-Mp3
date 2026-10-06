## Destination

Define the decisions and implementation route for the native Apple apps to follow the current Apple Human Interface Guidelines, with iOS 26 as the primary experience and native fallbacks for the supported older OS versions.

## Notes

- Scope: all native iOS, iPadOS, and macOS screens. Flutter, web, and backend are outside this map.
- Preserve product capabilities; when the current interaction conflicts with the HIG, adapt the interaction rather than remove the feature.
- Use platform-specific UIKit/AppKit layouts and interaction patterns. Share only data and services.
- Adopt modern system APIs and materials when available; do not imitate unavailable system effects manually.
- Accessibility and adaptation are acceptance criteria: Dynamic Type, VoiceOver, contrast, iPad multitasking and rotation, and macOS keyboard/shortcut behavior.
- Each implementation decision requires automated coverage where practical plus real-device iPhone and macOS visual verification.

## Decisions so far

- [Current Apple HIG Baseline](issues/01-current-apple-hig-baseline.md) — adopt standard platform navigation, content-first reader chrome, availability-gated iOS 26 enhancements, and accessibility/adaptation as acceptance criteria.
- [Native Apple Surface Inventory](issues/02-native-apple-surface-inventory.md) — preserve separate UIKit/AppKit composition; prioritize reader/root/mini-player risk before lower-impact surfaces.

## Not yet specified

- The iOS 26 and current macOS HIG requirements that materially change this product's shell, navigation, materials, controls, and reader behavior.
- The complete inventory of native screens and existing deviations from those requirements.
- The compatibility matrix for modern APIs and native fallbacks across supported OS versions.
- Reader-specific decisions for immersive reading, links and footnotes, pagination, typography, themes, selection, and accessibility.
- Library, conversion, player, and settings interaction models after the shared HIG baseline is known.
- Validation artifacts and a release checklist for visual, accessibility, and adaptive-layout acceptance.

## Out of scope

- Flutter/Android, web, backend, and conversion-engine work unless an Apple-client contract is shown to require a separately approved change.
