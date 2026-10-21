# Architecture

Shared conversion belongs in `crates/converter-core/`: parsing, structure/text,
provider/model policy, progress, cancellation, persistence and artifacts.
`converter-ffi` exposes the native C ABI; `converter-cli` is a direct entry point;
`converter-wasm` exposes browser-safe bindings. Native-only dependencies are
conditionally compiled; the full native process/network pipeline is not a browser API.

| Surface | Source entry | Adapter responsibility |
| --- | --- | --- |
| Apple | `ios/EpubToMp3/EpubToMp3/Features/` | UIKit/AppKit, local files, media and FFI |
| Web | `web/src/services/BrowserConversionClient.ts` | Browser I/O/Piper/storage around Rust sessions |
| Flutter | `flutter_app/lib/main.dart`, `lib/services/embedded_converter.dart` | Registered Android native channel and Linux/Windows FFI |
| Optional server | `crates/converter-server/src/main.rs` | Hosted HTTP compatibility contract |
| Legacy | `python_app/`, `hf_app.py` | Compatibility fixtures and migration reference |

Apple does not require Python or an HTTP sidecar for embedded conversion.
Browser conversion does not silently select the retained HTTP adapter. Flutter
startup registers embedded converters; retained Python bridge/assets do not prove
that production calls them. Check actual callers before removing legacy material.

Paths, schemas and persistence depend on the adapter and configuration; do not
reuse old Python `.jobs/`/`.uploads/` defaults as universal platform paths.
Use [runtime navigation](../../agents/runtime-navigation.md),
[CONTEXT.md](../../../CONTEXT.md) and relevant ADRs for detailed ownership.
Source wiring alone is not a passing migration or runtime acceptance report.
