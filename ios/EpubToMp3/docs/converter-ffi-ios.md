# Apple converter-ffi boundary

`ConverterFFIAdapter` loads the bundled Rust dylib and calls the C ABI for
metadata, conversion and model capabilities. `RustConversionCoordinator` owns
client orchestration; the shared Rust core owns conversion and artifacts.
There is no HTTP/Python fallback. Dylibs and XCFrameworks are not checked in.

Build and verify physical-iOS artifacts through `converter-ffi:ios-device` and
`converter-ffi:ios-device:verify`. Device runs use `docs/device-benchmark.md`;
`apple:foundation:ffi:test` tests the real host Rust dylib with native XCTest.

## Explicit options

Existing conversion symbols retain their signatures and Edge defaults. Explicit
options require both `converter_conversion_options_validate_json_v1` (C bool)
and `converter_session_convert_job_options_json_v1` (owned C string result).
The latter takes session, output path, job ID, options JSON, inclusive start/end,
progress callback, chapter callback and context, in that order.

Example: `{"schema_version":1,"engine":"edge","voice":"pt-BR-FranciscaNeural","language":"pt-BR"}`.
Schema is required, unknown fields fail, and voice/language remain literal.
`clear_cache` refreshes only selected derived chapter text. `force_reprocess`
regenerates only selected audio through validated same-volume staging, preserving
prior audio on failure. `max_performance` permits parallel selected chapters
within configured/platform resource caps. All three flags default to false.
Explicit Piper requires `models_root` (absolute), `model_id` (one namespace
component), and relative `model_path`/`model_config_path` within that installed
namespace. Rust rejects traversal, missing files and symlink escapes, then checks
actual runtime initialization/readiness before book/output work. Edge/auto reject
model fields. Model paths are request-local, not process environment overrides;
initialization and synthesis share a transaction lock. A missing linked runtime
fails clearly; this interface does not install models or enable optional engines.

Rust validation precedes book/output access. Missing symbols never cause explicit
options to fall back to an unconfigured ABI. Only `(-1,-1)` means whole book;
nonnegative start / `-1` end means through the actual last chapter. Invalid
sentinels and ranges fail closed.

## Ownership and callbacks

Sessions and returned strings use their matching free functions. Callback JSON
is borrowed only during the callback; Swift copies it into `Data`. Its callback
box lives for the entire C call. The Rust shutdown gate drains running callbacks
and disables late worker clones before returning, protecting borrowed context
after timeout. Do not reenter the same gate or wait for ABI return in a callback.
This is a foreign-context lifetime guarantee, not full worker cancellation.

Host tests do not establish physical packaging, full conversion, model readiness,
frontend routing or playback behavior. Remaining gates are recorded in
`docs/plans/2026-10-08-app-quality-performance.md`.

## Apple build destinations

Rust remains bundled in `EpubToMp3.app/Frameworks/libconverter_ffi.dylib` and runs
in the Swift app process. A separate compiler artifact is not a separate product.
Physical iOS uses `aarch64-apple-ios/release`; Simulator uses the host architecture
(`x86_64-apple-ios` or `aarch64-apple-ios-sim`), Debug or Release matching Xcode.
The packaging phase validates Mach-O architecture, Apple platform and ABI before
copying/signing. macOS keeps its existing separate native artifact route.

`mise run converter-ffi:ios-simulator` builds Debug with one job under the shared
lease, refusing a booted Simulator. `mise run converter-ffi:ios-packaging:test`
exercises real artifact rejection and isolated signed bundling, without launching
Simulator. These do not prove app startup or native UI behavior.

For this Intel Mac/iOS 16 runtime, build with the selected Xcode 26 toolchain,
then reuse that build with the installed Xcode 16.4 test controller via a per-command
`DEVELOPER_DIR=/Applications/Xcode-16.4.0.app/Contents/Developer`. Do not change global
Xcode selection or open Xcode GUI. Two native smoke tests passed using this route.
The native smoke task requires explicit low-resource opt-in and a Simulator UUID;
startup grace defaults to zero, caps at 180 s, and does not disable thermal/memory
or operation-deadline stops. The global quality/performance goal is not complete.
