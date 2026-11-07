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
| Git LFS | Missing local CI transport prerequisite | 3.8.1, prebuilt Aqua installation |
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

## Ruby dependency delivery

| Surface | Before | Selected |
| --- | --- | --- |
| Rails gateway | 8.1.4 | 8.1.4.1 |
| Minitest | 6.0.6 | 6.1.0 |
| Client Prism | 1.9.0 | 2.1.0, including published Intel platform gems |
| Bundler lockfile version | 4.0.20 | 4.0.24 |

Both lockfiles retain checksums and their supported platforms. The client's
declared Ruby minimum is corrected to 3.2, required by Minitest 6 and Bundler 4;
verification uses the retained Ruby 4.0.7. The Rails dependency graph retains
Prism 1.9.0 because `rubocop-ast` 1.50.0 requires `prism ~> 1.7`.

Client tests passed on Mac and Arch (two cases each); Rails request and sanitizer
tests passed on Arch (six cases, 15 assertions). Arch used an isolated frozen
bundle and all three manifest/lockfile hashes matched the delivery inputs.
Local host preflight passed all 28 suites. No Ruby tool or native gem was compiled
on Mac for this delivery; gateway dependency installation and tests ran on Arch.

## Host runtime and legacy Python selection

| Surface | Before | Selected |
| --- | --- | --- |
| Main Python | 3.12.10 | 3.14.10 |
| Optional Coqui Python | Moving 3.11 alias | 3.11.18, explicit `coqui` environment |
| Rust | Moving `stable` alias | 1.99.1, matching the existing Docker compiler |
| Legacy pypdf | 6.21.4 | 7.0.0 |
| FastAPI | 0.162.0 | 0.162.1 |
| pandas | 3.1.0 | 3.1.1 |
| Pydantic | 2.14.2 | 2.14.3 |
| CI Ruff | 0.6.9 | 0.17.4, matching the hook |

The root and `python_app/` default use Python 3.14.10. NumPy 2.5 requires Python
3.12 or newer, so the old unconditional child-directory Python 3.11 override is
removed. `python_app/mise.coqui.toml` selects Python 3.11.18 and `.venv-coqui`
only with `mise -E coqui`. TTS 0.22 requires Python below 3.12 and pandas below 2;
that isolated dependency graph retains NumPy 1.26.4's ABI (`numpy <2`).
Numba 0.68.1 and llvmlite 0.50.0 already support this interpreter and remain pinned.
Install its optional libraries from `python_app/` with
`mise -E coqui exec -- python -m pip install -r ../requirements-coqui.txt`.
Model installation remains an explicit separate action.

Published Intel install-only binaries for both Python versions were confirmed in
python-build-standalone release `20261026`. mise tool compilation is explicitly
disabled. Rust compiler queries and target builders now honor the project pin,
and fixed CI Python/Ruby/Rust versions match the selected toolchains.

Existing virtualenvs can retain their old interpreter after a tool pin changes.
The isolated local host environment was recreated and verified as Python 3.14.10;
its old environment was retained as a backup. CI cache keys include the Python
version, creation uses the selected base interpreter, and runtime tests compare
the actual interpreter with the manifest. Optional Coqui numerical imports and
dependency-resolution dry runs belong to full CI; no inference/model-download
acceptance is implied by the configuration checks.

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
  CPython 3.14. The selected main environment is 3.14.10; optional Coqui `TTS`
  requires Python below 3.12 and uses the explicit 3.11.18 environment.
  Legacy Python resolution and tests belong in CI.
- Flutter 3.47.9 / Dart 3.13.7 were validated on Arch in an isolated checkout:
  560 tests passed, eight opt-in tests skipped, and final analysis found no
  issues. Riverpod 3, Freezed 4, file_picker 13 and XML 7 required API and
  generated-model adaptations. The typography sheet retains a Material ancestor
  for the updated slider widgets. Generated sources use the generator's formatter.
  `flutter_html` 3.0.0 imports an internal `html` function removed in 0.15.7;
  retain `html` 0.15.6 until that renderer supports the public API.
  The 31-file generated/source package was hash-matched on Mac; no Flutter SDK
  or Dart execution was needed on Mac. Local host preflight passed all 28 suites.
  Android toolchain migration and actual Linux application acceptance remain
  separate Arch checks; these results cover analysis and unit/widget behavior.
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
