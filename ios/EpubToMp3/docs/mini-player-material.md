# Mini-player material ownership

The same mini-player content has two hosts:

- The floating reader/compatibility overlay owns one app material capsule.
- The native `UITabAccessory` on supported SDK/runtime combinations owns the
  surrounding material itself. Its content must not draw a second inset capsule.

`usesSystemManagedBottomInset` identifies the system-accessory hosting mode.
In that mode the internal material view stays in the layout hierarchy for
content alignment and height, but is hidden. The controls and 44-point touch
areas are unchanged. The floating overlay continues to use its adaptive
material in both light and dark appearances.

This addresses a concrete nested-material path consistent with the reported
duplicated side bubbles on Library, Settings and Convert. The reported device
appearance is not yet independently reproduced; final iPhone acceptance must
check all tabs and transitions between the reader overlay and tab accessory.
The system accessory remains guarded by SDK/runtime availability, preserving
iOS 15.5 and the Xcode 16.4 build path.

Apple references consulted on 2026-10-27:

- [Materials HIG](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Tab bars HIG](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- [Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)

Apple recommends restrained material use and avoiding overlapping glass layers;
standard tab accessories provide their own system presentation.

`MiniPlayerSurfaceOwnershipTests` exercises material ownership in both
appearances and retains geometry/control-size assertions. UIKit execution and
visible device validation are deferred to the user's final campaign; syntax
checks and unrelated Foundation checks are not visual acceptance.
