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
`clear_cache`, `force_reprocess` and `max_performance` are accepted as false but
explicitly rejected as true in this tracer; their effective semantics are pending.
Provider support does not imply an installed, ready offline model.

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
