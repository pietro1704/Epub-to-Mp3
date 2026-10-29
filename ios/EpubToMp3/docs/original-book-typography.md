# Original book typography

The native reader preserves publisher font family, size, inline emphasis,
paragraph alignment, indentation and spacing unless a reader control explicitly
overrides that property. Head `<style>` blocks and the root/body class, language
and style attributes remain part of native HTML import. Supplied chapter CSS
precedes embedded style blocks. UIKit/AppKit HTML import remains a supported
subset of EPUB CSS, rather than a browser layout engine.

Registered EPUB fonts can have a CSS alias different from their Core Text family.
`EpubFontAliases` resolves local `@font-face` resources to families extracted from
the current book's font directory, then rewrites stylesheet and inline family
lists. It preserves remaining fallback families and `!important`; missing,
remote, encrypted/obfuscated or unsupported font files use native fallbacks.
This does not download fonts, copy private app assets or redistribute book fonts.
Cold Mac opens now extract/register the book fonts, and both Mac and iOS warm
rendering use the retained font directory.

Font-size controls remain explicit overrides. Publisher headings are no longer
silently capped against the unrelated reader default size. Alignment and line
spacing have independent persisted override flags. Existing saved controls
migrate as explicit choices, including values equal to the old defaults. Original
reset clears the flags while preserving the control values. Cache signature v4
includes both paragraph override flags so old normalized archives cannot replace
publisher typography. Theme color adaptation continues to protect readability.

The native viewport and glyph-aware paginator still own clipping prevention and
oversized-fragment fallback. They must be exercised with large headings,
negative indents, small text, embedded font metrics and chrome transitions during
final acceptance; preserving the source style is not proof of non-clipping.

Fast Foundation XCTest covers source document extraction, local alias selection,
fallbacks, Unicode/case, CSS priority, inline text preservation and override
migration/reset. Native `EpubOriginalTypographyTests` exercises attributed fonts,
paragraph geometry, explicit override/reset and actual installed-font metadata.
UIKit compilation/execution and seeded-reader screenshots remain pending the
final campaign. Required SE1/iOS 15.5 Simulator acceptance remains quarantined.
