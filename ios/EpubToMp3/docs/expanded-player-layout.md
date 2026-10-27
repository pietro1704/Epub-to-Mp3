# Expanded player viewport

The expanded iOS player has no scroll container. `FullPlayerLayoutView` owns
measurement and final frames; `FullPlayerContent` installs the controls and
`FullPlayerScreenController` supplies playback state.

Portrait retains the cover, metadata, progress, transport, volume and secondary
control order and four-point spacing. The cover receives the remaining space
at its existing 2:3 aspect ratio, shrinking before controls or metadata. In
wide, short viewports (at least 480 points wide), metadata and cover reflow to
the leading column and controls occupy the trailing column with at least 260
points for five transport buttons. A decorative cover can disappear if no
space remains; controls never gain a scroll dependency.

Long metadata uses two title lines, one author line and two chapter/active-voice
lines, with tail truncation. Complete label strings remain available to
VoiceOver. Dynamic Type scales from native text styles with maximum sizes of
38/24/20 points for title/author/chapter, 20 for timestamps/rate. These bounds
keep the approved no-scroll design usable in compact landscape and large text
settings. The close, scrub, transport and secondary controls retain 44-point
minimum touch areas. Missing author text can be hidden without a conflicting
required minimum label height.

## Verification

`FullPlayerFittingTests` exercises long metadata at 390×844, 320×568 and
568×320, largest accessibility text, orientation/metadata replacement, touch
sizes, cover ratio and the absence of a scrolling surface. Existing player
configuration coverage uses the new viewport boundary. These are native UIKit
unit tests, authored for the agreed final native campaign. Syntax parsing and
Foundation tests do not establish that their geometry passes at runtime.

Final acceptance checks the iPhone 16e in portrait/landscape and with VoiceOver,
long metadata, Dynamic Type, player transitions and playback updates. The
seeded-reader/macOS contract remains applicable; required SE1/iOS 15.5 runtime
acceptance remains blocked by the Simulator quarantine.

Reference: [Apple HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout),
[Typography](https://developer.apple.com/design/human-interface-guidelines/typography),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
and [systemLayoutSizeFitting](https://developer.apple.com/documentation/uikit/uiview/systemlayoutsizefitting(_:withhorizontalfittingpriority:verticalfittingpriority:)).
