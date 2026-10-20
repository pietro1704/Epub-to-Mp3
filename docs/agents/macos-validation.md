# Focused macOS validation

Use `mise run mac:validate -- MODE --derived-data PATH`. Select the smallest
mode that proves the requested behavior. `inspect` is the default; no mode
implicitly escalates into another. Execution permissions and the shared native
safety gate remain defined in [execution policy](execution-policy.md).

| Mode | Work performed | Compilation |
| --- | --- | --- |
| `inspect` | Read source/toolchain identity and an existing build receipt | None |
| `package` | Copy the embedded FFI into a disposable fixture, run the actual ONNX bundler and verify signatures and unchanged originals | None |
| `build` | Generate the project and incrementally build the macOS app in the explicit existing DerivedData directory | Guarded, one job; no Rust task dependency |
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

## Required PR gate

`mise run pr:gate:policy -- --repo OWNER/REPO` verifies the server requires only
`PR gate`, bound to the GitHub Actions app, with an up-to-date base and administrator
enforcement. Explicit `--apply` changes only the required-check policy while
preserving other protections. Initial creation uses GitHub's full protection
endpoint, checks that the baseline has not changed, and verifies the result.
Keep an external before/after snapshot when applying repository settings.

The guarded merge helper checks that policy immediately before a requested
merge as well as checking exact-head CI results. Read-only eligibility inspection
does not require administration permissions. Do not infer that `gh pr merge
--auto` waits for CI unless server enforcement has been verified. Only observe
the task's required gate when monitoring is authorized; optional post-merge
checks and publishers are separate.
