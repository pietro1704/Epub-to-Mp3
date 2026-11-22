# Focused macOS validation

Use `mise run mac:validate -- MODE --derived-data PATH`. Select the smallest
mode that proves the requested behavior. `inspect` is the default; no mode
implicitly escalates into another. Execution permissions and the shared native
safety gate remain defined in [execution policy](execution-policy.md).

| Mode | Work performed | Compilation |
| --- | --- | --- |
| `inspect` | Read source/toolchain identity and an existing build receipt | None |
| `package` | Copy the embedded FFI into a disposable fixture, run the actual ONNX bundler and verify signatures and unchanged originals | None |
| `build` | Generate the project and incrementally build the macOS app in the selected DerivedData directory | Guarded, one job; no Rust task dependency |
| `gui` | Check the matching receipt, signature and native preflight, then open the existing app normally | None |

For a linked checkout with the usable native cache, pass `--checkout PATH`.
Packaging requires that checkout's bundler to match the current validator's
version. The command reads existing FFI/ORT artifacts; it never installs models
or runtime dependencies. A missing input is a failure, not a request to build it.

```sh
mise run mac:validate -- inspect --derived-data /path/to/existing/DerivedData
mise run mac:validate -- package --derived-data /path/to/existing/DerivedData
mise run mac:validate -- build --derived-data /path/to/existing/DerivedData
mise run mac:validate -- gui --derived-data /path/to/existing/DerivedData
```

An older Xcode artifact without a validator receipt is reported as unknown;
the command does not invent its provenance or rebuild it automatically. A
successful explicit build writes a receipt tied to production sources/resources,
Cargo/FFI, configuration, toolchain, relevant flags and product hashes. Tests and
instruction edits alone do not invalidate that identity. Manual Xcode validation
may use Xcode's own build/run path within the execution policy; receipt refusal
is not evidence that an existing app is defective.

Explicit Debug validation builds use local ad-hoc signing with no entitlements,
so GUI signature checks do not require a provisioning profile. This local build
does not validate sandbox or app-group capabilities. Release builds retain the
project signing configuration; the receipt records the selected signing policy.

For signing or linking regressions, start with `package` and real platform
tools. Preserve the failing output and compare with the corrected script before
expanding to compilation or UI. The Faber macOS workflow repeats this check after
its existing native build, reusing the same artifact on Intel and ARM hosts.
`mise run mac:validate:test` runs executable boundary fixtures without compiling.

`-only-testing` narrows XCTest execution, but Xcode may still compile the entire
test target. Prefer the app build for a manual app journey and add focused tests
at the owning seam; choose when to execute them according to the user request.
Separate packaging, preparation/build, test execution and visible-app evidence.
For a GUI journey, bring the app frontmost, exercise normal flows, retain its
identity/screenshots/logs, and verify shutdown when finished. Opening the window
alone does not establish playback or conversion acceptance.

## Fast local Debug test loop

For local Mac XCTest iteration, `mise run mac:test:local -- -only-testing:ID ...`
builds once and runs every selected suite in one guarded `xcodebuild` (Debug,
`EpubToMp3Mac`, one job). It first runs `converter-ffi:build:local` (not for
`test-without-building`), which writes
`target/local-dev/release/libconverter_ffi.dylib`: the release profile with
local `--config` overrides in its own target directory: workspace crates at
opt-level 0, incremental, 16 codegen units and no LTO; dependencies keep
opt-level 3 and one codegen unit.
A content stamp beside it skips cargo when the Rust inputs are unchanged, also
across worktrees, and touches files whose content differs from that record so
cargo cannot treat an edit with an older mtime than the shared output as fresh
(observed: such a converter-core edit was skipped by cargo). A Debug-only post-build step embeds that
dylib; it refuses other configurations and restores the release bytes on the
next build without the setting. Release, packaging, CI, `mac:build` and
`mac:validate` keep `target/release` and `[profile.release]` unchanged, and a
local-dev dylib is never a release or acceptance artifact. The copy phase still
needs some `target/release` dylib; reuse a retained package (below) instead of
compiling when it is missing. Opt-in test settings such as
`EPUB2MP3_PIPER_TEST_MODEL_ROOT=PATH` are accepted; compiler flags are not.

Measured on this Intel i5-8259U (4 cores, 8 GiB) through the guarded tasks,
one job, wall seconds (evidence in the local build-speed report):

| Step | Release route | Local route |
| --- | --- | --- |
| Cold Rust build (empty target directory) | 660 | 929 (one-time, shared by worktrees) |
| No-op Rust task | 13 | 13 (stamp reuse, cargo skipped) |
| converter-core edit | 111 (cargo 98) | 32 (cargo 14) |
| converter-ffi edit | 30 (cargo 18.5) | 8.5 (cargo 3, candidate run) |
| First Rust build from a new worktree | 128 | stamp reuse when inputs match (not timed) |
| 10 focused tests incl. Faber inference, warm | 23 (`xcodebuild` only) | 36 (whole `mac:test:local`) |

Xcode `build-for-testing` for `EpubToMp3Mac` (Debug): 212 cold, 9 warm, 14
after one Swift edit; four focused suites with `test`: 9. `xcodegen generate`
takes about 2.5 seconds and does not slow the next warm build (8.6 vs 13.3),
so it is not skipped.

Do not delete the shared `target/`: a cold release `converter-ffi` build takes
about 11 minutes and every worktree shares it. `mise run clean:build` removes
only superseded Xcode DerivedData and keeps `target/`.

## Lease status, host readings and the flight recorder

Read the lease and the host once before a guarded build or test:

```sh
mise run native:status
```

It prints the lease holder, every process that keeps the lease file open (a
browser or daemon left behind by an earlier job shows here), the current
readings, `notes` (load, memory pressure, thermal limits, a foreign compiler,
swap or the compressor above their thresholds; they are information only, since
Pietro removed the host guards on 2026-11-22, and never refuse or delay a job)
and the flight recorder path. A job starts at once unless the build lease is held.
Let one job queue for the lease instead of polling (whole seconds; any other
value fails; the default `0` refuses at once when the lease is busy):

```sh
EPUB_NATIVE_WAIT_SECONDS=900 mise run mac:test:local -- -only-testing:ID
```

Keep the log, the PID and the exit status of a long run in a persistent
directory under `.reports/`, never in `/tmp` or a session scratch directory: a
reboot empties both. Decide the outcome from the recorded exit status. A watcher
that only greps for `** BUILD` markers misses an `xcodebuild: error:` exit:
at 21:11 BRT on 2026-11-19 (00:11 UTC on 2026-11-20) an iOS `build-for-testing`
wrote an error result bundle and exited in under two seconds, and was reported
as compiling for 22 minutes. The same
command repeated later failed with `xcodebuild: error: Unable to find a
destination`: `mise exec` replaces a `DEVELOPER_DIR` set in front of it with the
Xcode 16.4 path. Select Xcode 26.3 for iOS with `IOS_DEVICE_ID`, as the
execution policy says.

After the run, read the last lines of the recorder file. Reference readings on
this host for one serial iOS `build-for-testing` (Xcode 26.3, `-jobs 1`, five
targets) with the usual background work, taken between 22:10 and 22:37 BRT on
2026-11-19 (01:10 to 01:37 UTC on 2026-11-20):

| Moment | 1-minute load | Swap in use | `CPU_Speed_Limit` |
| --- | --- | --- | --- |
| First run after the reboot, 1 min 41 s in | 7.12 | 315 MiB | 81 |
| Same run, 3 min 40 s in | 11.41 | 1551 MiB | 81 |
| 5 min 39 s after it was stopped | 3.79 | 331 MiB | 100 |
| Second run (resumed, 4 min 38 s in total), 2 min 45 s in | 4.24 | 1016 MiB | 100 |

A guarded step that Xcode starts from a build phase belongs to that build; a
compiler outside it is only listed as a note. Prepare Rust artifacts through
their guarded task before a manual Xcode build so the two do not compile at
once. Booted Simulators and `SimMetalHost` no longer matter to a build. None of
this is evidence about kernel or driver stability.

## Retained Intel FFI packages

After an authenticated producer download, the downloader retains the full
package and receipt under `target/native-prebuilt/converter-ffi-macos-intel`.
Before considering another build, reuse a source-matched package from this
checkout or its linked worktrees:

```sh
mise exec -- ruby scripts/native_job.rb build -- "$(mise which ruby)" scripts/download_converter_ffi_macos.rb --reuse-local
```

This command verifies the current Rust/native inputs, build recipe, payload
hashes, platform, architecture and ABI before installation. Identical installed
payloads remain untouched. It requires neither network access nor a GitHub token
and never falls back to compilation. Rejected packages remain available for
inspection. If none matches, audit the trusted master-only producer artifacts;
the producer shares the compiler/SDK-scoped Intel Cargo cache with Faber CI.
Swift and documentation edits alone do not invalidate an unchanged FFI package.

## Required PR gate

`mise run pr:gate:policy -- --repo OWNER/REPO` verifies the server requires only
`PR gate`, bound to the GitHub Actions app, with administrator enforcement
(an up-to-date base is not required since 2026-11-19). Explicit `--apply` changes only the required-check policy while
preserving other protections. Initial creation uses GitHub's full protection
endpoint, checks that the baseline has not changed, and verifies the result.
Keep an external before/after snapshot when applying repository settings.

The guarded merge helper checks that policy immediately before a requested
merge as well as checking exact-head CI results. Read-only eligibility inspection
does not require administration permissions. Do not infer that `gh pr merge
--auto` waits for CI unless server enforcement has been verified. Only observe
the task's required gate when monitoring is authorized; optional post-merge
checks and publishers are separate.
