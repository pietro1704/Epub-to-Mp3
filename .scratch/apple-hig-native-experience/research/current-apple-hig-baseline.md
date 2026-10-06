# Current Apple HIG Baseline

Scope: native UIKit/AppKit reader and player, with iOS/iPadOS 26 as the visual target and supported-version fallbacks. Sources below are Apple Developer documentation only.

## Requirements

### Navigation and platform structure

- Use tab bars only for top-level navigation, not actions; keep them available across sections so location remains clear. Put actions in a toolbar. On iPhone, the tab bar floats at the bottom over content. [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- Use a navigation bar/toolbar for the reader’s current context, navigation, and reader actions. Keep leading navigation/sidebar controls at the leading edge and actions at the trailing edge. [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- Use a split view for hierarchy on iPad regular width and macOS; preserve the selected item in each navigation pane. Do not force a multi-column layout in iPhone compact width. [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)
- Treat macOS as a distinct desktop experience: resizable/hideable windows, full screen, menu commands, keyboard shortcuts, precise pointing, and configurable toolbars are expected. Avoid placing critical controls at the bottom of a Mac window. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

### Reader, player, and content

- Keep reading content as the primary layer. Controls and navigation must be visually separate from content; use transient, deliberately minimal reader chrome for focused reading rather than inventing competing content cards. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Design principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)
- Use a sheet for scoped reader tasks (for example, contents, settings, or a footnote when it needs focused interaction). It must provide the platform-appropriate Close/Cancel/Done affordance; a back button is for hierarchy, not dismissal. [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- Represent player state with standard controls, accessible names, and visible state changes. Use familiar SF Symbols where they communicate the action; icon-only controls require an accessible label and, on macOS, should expose a tooltip. [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

### Typography, adaptation, accessibility

- Use system text styles and system fonts where possible. On iOS/iPadOS, support Dynamic Type at all sizes without hiding meaningful content or creating avoidable truncation; scale meaningful icons too. For long reading passages, use adequate leading rather than tight leading. [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Audit VoiceOver semantics, contrast, Reduce Transparency, increased contrast, and all supported text sizes. Apple’s baseline says custom text should be at least 17 pt default / 11 pt minimum on iOS/iPadOS and 13 pt / 10 pt on macOS. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Use Auto Layout and safe/content layout guides; adapt at every iPad window size and defer compact transformations until the full layout no longer fits. Do not hard-code device geometry or rely on fixed z-order/height workarounds. [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [UITabBarController.contentLayoutGuide](https://developer.apple.com/documentation/uikit/uitabbarcontroller)

## iOS 26 and current-platform opportunities

- Prefer standard UIKit/AppKit controls and navigation containers: they adopt Liquid Glass appearance and behavior automatically. Liquid Glass belongs to the functional navigation/control layer, not the reader content layer; use it sparingly and use clear glass only above visually rich content. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials), [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- On iOS/iPadOS 26, a mini player should be modeled as the tab bar’s supported bottom accessory when the architecture permits, rather than as an independently positioned view. The system supports a bottom accessory and system-driven tab-bar minimization on scroll. [UITabBarController](https://developer.apple.com/documentation/uikit/uitabbarcontroller), [Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)
- Custom iOS 26 glass is an enhancement only when a standard component cannot express the control. Use `UIGlassEffect`/`UIGlassContainerEffect` only for that narrow case; preserve interaction and accessibility semantics. [UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)
- On modern macOS, use `NSGlassEffectView` only when a standard AppKit component cannot provide the appropriate control/navigation treatment. It is a glass container, not a reader-content background. [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- An iPad tab-bar/sidebar adaptive presentation is optional but appropriate for an app with stable top-level destinations; it must keep navigation logical at narrow widths. [Layout](https://developer.apple.com/design/human-interface-guidelines/layout), [Split views](https://developer.apple.com/design/human-interface-guidelines/split-views)

## Supported-version fallbacks

- Guard iOS/iPadOS 26-only APIs such as `UIGlassEffect`, tab-bar bottom accessories, and minimize behavior with availability checks. On earlier supported systems, retain the same navigation hierarchy and semantics using standard `UITabBarController`, navigation/toolbar APIs, safe-area/content layout guides, and standard blur/materials; do not imitate Liquid Glass with custom effects. [UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect), [UITabBarController](https://developer.apple.com/documentation/uikit/uitabbarcontroller), [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- Guard modern AppKit glass APIs similarly. Earlier macOS versions use standard `NSToolbar`, `NSSplitViewController`, system materials, menu commands, and keyboard equivalents. Platform-specific layouts may differ, but reading, player, accessibility, and navigation behaviors must remain equivalent. [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

## Decision-relevant baseline

1. iPhone reader: standard navigation/toolbar chrome, standard tab navigation, content-first immersive mode, and a system-native mini-player attachment where availability permits.
2. iPad: adaptive tab/sidebar or split navigation only when width allows; never compromise reader legibility to keep columns visible.
3. Mac: native toolbar, sidebar/split-view behavior, keyboard/menu access, resizable/full-screen reader, and no iPhone-style bottom-critical controls.
4. Across all Apple surfaces: semantics, Dynamic Type where available, contrast/transparency adaptation, VoiceOver, and safe-area/content-layout correctness are acceptance criteria, not polish.
