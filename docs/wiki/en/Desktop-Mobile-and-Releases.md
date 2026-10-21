# Desktop, mobile and releases

Apple clients use native UIKit/AppKit plus embedded Rust FFI. Start with the
[Apple guide](../../../ios/EpubToMp3/README.md) and
[macOS validation](../../agents/macos-validation.md). The full `mac:build` task
builds embedded FFI prerequisites; `sidecar:build` is a separate standalone-server
task and is not the Apple application dependency.

Flutter owns Linux/Windows/Android with registered native Rust adapters. Follow
[the Flutter guide](../../../flutter_app/README.md); do not infer a system-Python
or remote-server requirement from retained compatibility files. Linux Flutter and
Android/Samsung work belongs on Arch; Android remains paused until resumed.
Windows packaging requires the matching toolchain.

All Mac compilation uses guarded tasks. Simulator execution remains quarantined;
required SE1/iOS 15.5 reader acceptance stays pending and cannot be replaced by a
physical device or another runtime. A native build, unit test or source registration
does not establish visible reader, conversion or audio acceptance.

Release workflows and artifacts must be checked at their exact revision. Read
`.github/workflows/release-desktop.yml` and relevant platform workflows rather
than assuming every tag publishes every platform or bundles Python. Signing,
architecture, runtime dependencies and model assets require artifact evidence.
Release/tag creation, store/TestFlight publishing and deployment need separate
authorization; a documentation update triggers none of them.
