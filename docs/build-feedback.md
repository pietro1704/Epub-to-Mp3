# Incremental build feedback

The Apple CLI development workflow retains the existing compiler settings and
resource guards. Debug uses incremental Swift compilation, `-Onone` and one
compiler job. Release optimization, toolchain routing and Simulator quarantine
are unchanged.

## Avoiding repeated packaging work

- ONNX packaging preserves an existing macOS library only when its bytes match
  the verified source and its ad-hoc signature passes the real `codesign` check.
  Certificate signing retains the full copy/sign path. Missing or corrupted
  destinations are replaced; invalid source artifacts fail before replacement.
- eSpeak packaging compares the complete resource tree by content before skipping
  a copy. Changes with identical timestamps and sizes still trigger copying.
- The four Xcode script phases hide environment-variable dumps. Their commands
  and dependency-analysis settings remain unchanged. XcodeGen caching is not
  enabled: a cache hit can omit a newly available library reference.

The eSpeak script participates in native package source identity. A previously
retained package may be rejected after this change; never relax identity checks
to reuse it. Preserve the authenticated packages and receipts for later review.

## Verification without compilation

Run `mise run mac:validate:test`. Packaging fixtures use installed macOS tools and
retained Intel FFI/ONNX artifacts, without downloading or compiling dependencies.
The XcodeGen regression compares generated project descriptors and permits only
the environment-log setting to differ. Unavailable platform tools/artifacts
produce explicit skips rather than fabricated runtime evidence.

On this Intel Mac, the original packaging scripts failed both repeated-work
regressions; the corrected scripts passed. Actual app build, startup performance
and visible application acceptance remain deferred. These checks establish
packaging behavior, not an end-to-end speed improvement.

Machine-local `mise.local.toml` can set `[settings] auto_install = false` to prevent
implicit tool installation during CLI work. Provision missing tools explicitly
on their owning platform. This local policy is excluded from Git.

The root `mise.toml` selects Android SDK `11.0` only on Linux. Mac project
commands skip that tool request; existing SDK installations are retained.
The executable task-wiring regression checks mise's actual tool selection on
the current platform without installing tools.

## Incremental TypeScript checks

TypeScript keeps separate compiler metadata for the complete source check and
the production build under `web/node_modules/.cache/typescript/`. Production
builds keep their existing test-file exclusions. Dependency cleanup may remove
this reproducible metadata; the compiler recreates it on the next check.

`npm run test -- --maxWorkers=2 src/test/TypeScriptIncrementalCache.test.ts`
from `web` exercises the installed compiler with copies of the actual project
configurations. It verifies separate cache identities, reuse on unchanged input,
same-length source edits, recovery from type errors and interrupted metadata
publication. This establishes compiler-cache behavior; app startup remains a
separate measurement.
