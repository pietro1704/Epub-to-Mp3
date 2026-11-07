# Stable dependency audit — 2026-11-07

This dated audit separates the verified Web/host update from native and legacy
migrations that still need their own acceptance. [inventory.tsv](inventory.tsv)
records direct packages, declared constraints and the stable releases returned by
their official registries. A newer release in that inventory is a candidate,
not evidence that its migration passed.

## Web and host delivery

| Surface | Before | Selected |
| --- | --- | --- |
| mise CLI / Actions runtime | 2026.10.6 local / 2026.9.14 CI | 2026.11.3 |
| Node | `lts`, observed 24.19.0 | 26.13.0 |
| npm | `latest`, observed 12.0.2 | 12.2.2 |
| Project Codex CLI | `latest`, observed 0.167.0 | 0.167.0, pinned |
| git-cliff | `latest`, observed 2.13.1, Cargo installation | 2.14.2, prebuilt Aqua installation |
| wasm-bindgen CLI | 0.2.129, Cargo installation | 0.2.129, official prebuilt GitHub installation |
| Ninja | `latest`, observed 1.13.2 | 1.13.2, pinned |
| Vite | 8.3.5 | 8.3.6 |
| Playwright | 1.64.1 | 1.65.0 |
| jsdom | 30.1.3 | 31.0.0 |
| `@eslint/js` | 9.39.4 | 10.0.1 |
| CI Minitest bootstrap | 6.0.6 | 6.1.0 |

The Node release index lists a 27.0.0 alpha; it is excluded. Node 26.13.0 is the
newest stable release and satisfies the published engines of Vite, ESLint,
Vitest, jsdom and npm. The Web manifest declares that compatible major and the
exact npm package manager. Docker uses the same Node/npm versions and `npm ci`.

All workflow and composite-action `uses` references were audited against the
maintainer's latest stable release, retaining full commit SHAs. CodeQL's
`codeql-bundle-*` releases are distinct from its action releases: the selected
action is v4.39.3. The existing trusted automatic-merge workflow remains active.
The official JavaScript actions still declare `using: node24`; their embedded
runtime is separate from the project's Node 26 installation.

Pre-commit uses the stable Prettier and ESLint packages from the Web lockfile,
replacing the old Prettier alpha mirror and React Hooks canary. Ruff's hook uses
the stable v0.17.4 release. Updating the ESLint recommended rules required
preserving the caught policy error as `cause` in the browser fallback path.
Undici moves to 8.12.4 to satisfy jsdom 31's declared major, and the three
Minimatch overrides move to 11.0.5. The unused UUID override is removed.
The glob security regression now checks the new explicit `RangeError` when an
optimization exceeds its expansion budget, as well as successful bounded input.

Flutter is scoped to Linux and Windows. Java and Android SDK remain Linux-only.
The Apple project inherits the root Codex pin. No Flutter/Android installation
is needed for these Mac host/Web commands.

## Compatibility holds and follow-up gates

- TypeScript 7.0.2 was evaluated. Both installed TypeScript ESLint packages
  publish `typescript >=4.8.4 <6.1.0`; retain 6.0.3 until that integration
  supports a newer compiler. The other direct Web packages are at their latest
  stable releases admitted by the audited graph.
- Babel core 8.1.0 was evaluated. React Hooks ESLint still declares Babel core
  `^7.24.4`; its override remains on the compatible 7.29.6 line.
- wasm-bindgen 0.2.130 must upgrade the crate, js-sys/web-sys/futures, generated
  WASM and CLI together. This delivery retains the tested 0.2.129 schema and
  changes only its installation to a prebuilt binary. The runtime migration is
  prepared separately; its actual build and browser contracts remain pending.
- Rust 1.99.1 and newer crate releases, including major API changes, were
  inventoried. Updating the shared runtime requires Rust and affected client
  checks; no new converter-ffi artifact is certified by this audit.
- Ruby 4.0.9 is latest. mise's binary provider has no Intel Mac build. The
  official ruby-builder Intel archive was checksum-verified, but depends on
  GitHub runner paths and is not directly relocatable. This delivery keeps 4.0.7;
  further tool updates must use published compatible Intel binaries. The user's
  latest instruction excludes compiling mise tools from source.
- CocoaPods 1.17.0 was evaluated. Its native gem dependencies still require
  verified binaries on this Mac; retain 1.16.2 in
  this delivery. Its isolated installation attempt was stopped after implicit
  native extension compilation was discovered; it is not acceptance evidence.
- Python 3.15.2 is latest, but ONNX Runtime 1.31.1 publishes wheels only through
  CPython 3.14. The prepared main-environment candidate is 3.14.10. The optional
  Coqui `TTS` package requires Python below 3.12, so its separate candidate is
  3.11.18. Legacy Python resolution and tests belong in CI.
- Flutter 3.47.9 and newer Dart packages are being validated on Arch in an
  isolated checkout. Dart code generation and native builds are not Mac tasks.
  Android toolchain migration remains a separate Arch acceptance boundary.
- Preserve Xcode 26.3 for iPhone 16e and Xcode 16.4 for the existing Mac/legacy
  routes. No Xcode selection, Simulator runtime or physical-device action is
  part of this Web/host update.

Local evidence is retained in `.reports/stable-web-ci/`. Full local preflight,
Web tests, lint/typecheck/build, npm audits, workflow/schema/bootstrap checks and
the changelog dry run are the focused gates. CI and merge are separate observed
results; this document does not certify them. Old installations are removed only
after their replacement passes its gates and cross-project/process use is checked.

## Primary sources

- [Node release index](https://nodejs.org/dist/index.json)
- [mise releases](https://github.com/jdx/mise/releases/tag/v2026.11.3) and
  [verified GitHub backend](https://mise.jdx.dev/dev-tools/backends/github.html)
- [Official Codex CLI documentation](https://learn.chatgpt.com/docs/codex/cli)
- [npm registry](https://registry.npmjs.org/), with per-package URLs in the inventory
- [Rust stable distribution](https://static.rust-lang.org/dist/channel-rust-stable.toml)
  and [crates.io](https://crates.io/)
- [Python release API](https://www.python.org/api/v2/downloads/release/) and
  [PyPI JSON API](https://docs.pypi.org/api/json/)
- [Ruby 4.0.9](https://github.com/ruby/ruby/releases/tag/v4.0.9),
  [ruby-builder Intel archive](https://github.com/ruby/ruby-builder/releases/tag/ruby-4.0.9)
  and [RubyGems](https://rubygems.org/)
- [Flutter stable archive](https://docs.flutter.dev/install/archive),
  [Flutter stable ref](https://github.com/flutter/flutter/tree/3.47.9),
  [pub.dev API](https://pub.dev/help/api)
- [Android SDK repository](https://dl.google.com/android/repository/repository2-1.xml)
  and [Gradle releases](https://services.gradle.org/versions/current)

This audit copies version metadata and links only, not third-party implementation
code. Upstream projects and their distributed binaries retain their own licenses.
