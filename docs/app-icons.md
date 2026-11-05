# App icons

The approved identity is an open ivory book with a coral cover, a round indigo
headband and lavender cushions. The canonical artwork is
`ios/EpubToMp3/EpubToMp3/AppIcon.icon`: three unmasked SVG layers and an opaque
background configured by Icon Composer. The operating system supplies the
Liquid Glass lighting, mask and appearance changes. Paper stays opaque so the
open book remains legible. No Apple hardware image or text is embedded.

Apple's current [app-icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons)
and [Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
describe default, dark, clear light/dark and tinted light/dark appearances.
Rendered previews alone do not establish validation on an installed iOS 27 app.

## Reproduce and verify

Use the installed Icon Composer from Xcode 26.3 without changing global
`xcode-select`. The renderer runs through the native/storage guard; it does not
compile Rust, install dependencies or start Simulator.

```sh
mise exec -- ruby scripts/export_app_icons.rb --render-apple
mise exec -- ruby scripts/check_app_icons.rb
mise exec -- ruby scripts/test_linux_app_launcher.rb
```

The first command renders the Apple masters, records source/tool/payload
identity, then exports static resources with installed ImageMagick. It requires
the existing `magick` binary and performs no tool installation. Without
`--render-apple`, it reuses the checked-in matching masters. `--check` verifies
source identity and output hashes without modifying assets. The two historical
Python entry points delegate to this same exporter instead of drawing another
design. Commit generated resources together with their source and manifests.

## Platform wiring

| Client                   | Resource and configuration                                                                                                                         |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native iPhone/iPad/macOS | `AppIcon.icon` and `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon` in Debug/Release. Xcode 26 uses the composer document.                             |
| Legacy Apple toolchain   | Dedicated `AppIcons.xcassets/AppIcon.appiconset`; iOS PNGs are full-bleed RGB with no alpha. The previously excluded color catalog stays excluded. |
| Windows Flutter          | Multi-resolution `runner/resources/app_icon.ico`, already bound to `IDI_APP_ICON` by the executable/window resources.                              |
| Linux Flutter            | Bundled `data/app-icon.png` for the GTK window and `install-launcher.sh` for desktop menus/Wayland identity.                                       |
| Web                      | PNG/ICO favicon, Apple touch icon and `site.webmanifest`, with 192/512 images. This does not add offline support.                                  |
| Android Flutter          | Existing launcher identifier, all legacy densities, adaptive background/foreground for API 26+, and monochrome artwork for API 33+.                |

After extracting the Linux bundle into its final location, run its
`./install-launcher.sh`. It installs only this application's entry under
`${XDG_DATA_HOME:-$HOME/.local/share}/applications`, using absolute, escaped
paths. Run it again if moving the bundle. It does not start the application.

Android compilation remains paused; source preparation does not resume it.
Linux builds/runtime acceptance belong on Arch and Windows acceptance needs a
Windows host. Preserve those boundaries when reporting validation. Native reader
acceptance remains a separate campaign.
