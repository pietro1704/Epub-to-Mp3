# Reader font catalog

The catalog preserves the existing `serif`, `sans` and `mono` preference keys
(Times New Roman, Helvetica Neue and Menlo). Original disables only the font
family override. Explicit size, spacing, theme and emphasis choices remain
independent and publisher styling stays authoritative elsewhere.

Reference choices include Athelas, Avenir Next, Canela, Charter, Georgia, Iowan,
Palatino, Proxima Nova, Publico, San Francisco, New York, Seravek and Times New
Roman. Iowan resolves `Iowan Old Style`; Publico resolves `Publico Text`.
Availability is queried from the current process. Missing named fonts are not
new choices; a saved missing request remains visible as unavailable and renders
with the system serif fallback without rewriting preferences. New York and
San Francisco use public system font descriptor designs rather than private
font names. Both attributed EPUB and plain-text fallbacks use that resolver.
Prepared chapter identity includes the resolved face for explicit overrides.

UIKit rows and AppKit menus preview the actual resolved face. The font controls
never download a font or copy Apple Books resources. Font files remain OS-owned;
EPUB-embedded resources remain scoped to their source book.

Apple's [system font catalog](https://developer.apple.com/fonts/system-fonts/)
distinguishes installed, document-support and downloadable fonts; its current
listing is not proof of availability on iOS 15.5. The public
[system design API](https://developer.apple.com/documentation/uikit/uifontdescriptor/withdesign(_:))
supports the deployment target. Apple's [downloadable font licenses](https://developer.apple.com/fonts/)
are not permission to bundle those design resources in the app.

Runtime font tests verify actual family identities, requested sizes and Portuguese
glyph coverage through Core Text. Attributed emphasis and preference-reset tests
belong to the native suite. Visible reader clipping, relaunch and font menu
acceptance remain part of the final native campaign; SE1/iOS 15.5 is quarantined.
