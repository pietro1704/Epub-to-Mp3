# Desktop, mobile and releases

Apple clients use native UIKit/AppKit plus embedded Rust FFI. Start with the
[Apple guide](../../../ios/EpubToMp3/README.md) and
[macOS validation](../../agents/macos-validation.md). The full `mac:build` task
builds embedded FFI prerequisites; the standalone Rust HTTP server is not an
Apple application dependency.

Flutter owns Linux/Windows/Android with registered native Rust adapters. Follow
[the Flutter guide](../../../flutter_app/README.md); do not infer a
remote-server requirement from retained compatibility files. Linux Flutter and
Android/Samsung work belongs on Arch; Android remains paused until resumed.
Windows packaging requires the matching toolchain.

All Mac compilation uses guarded tasks. Simulator execution has no host guard
since 2026-11-22;
required SE1/iOS 15.2 reader acceptance stays pending and cannot be replaced by a
physical device or another runtime. A native build, unit test or source registration
does not establish visible reader, conversion or audio acceptance.

Release workflows and artifacts must be checked at their exact revision. Read
`.github/workflows/release-desktop.yml` and relevant platform workflows rather
than assuming every tag publishes every platform. Signing,
architecture, runtime dependencies and model assets require artifact evidence.
Release/tag creation, store/TestFlight publishing and deployment need separate
authorization; a documentation update triggers none of them.

Version and tag flow: the product version is committed (`Cargo.toml`, `Cargo.lock`,
`ruby_app/rails_gateway/VERSION`, `CHANGELOG.md`). After a validated merge to
master, `release-pr.yml` plans the next version from the Conventional Commits since
the last tag and opens a `chore(release): vX.Y.Z` pull request (it needs the
`RELEASE_PR_TOKEN` secret and never merges anything itself; the normal trusted
merge path or a person merges it). Merging that pull request lets `auto-release.yml`
create the tag and a GitHub release with generated notes. It builds no artifacts:
`release-desktop.yml` stays a separate manual run for a published tag. Whether this
chain may publish without a human step is the owner's decision.
