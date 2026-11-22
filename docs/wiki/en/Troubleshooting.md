# Troubleshooting

Identify the adapter, source revision and artifact before selecting a diagnostic.
Preserve the original error/log and use the smallest check at the failing seam.
Read [execution policy](../../agents/execution-policy.md) for platform and safety limits.

- Browser: inspect generated WASM exports, TTS assets, browser storage support and
  explicit model installation/checksum state. A missing model does not authorize
  downloading one or switching to HTTP/Edge. Native browser speech cannot export MP3.
- Apple: inspect embedded FFI/ONNX packaging, architecture/platform and signatures;
  use `mac:validate` inspection/packaging before a justified rebuild. Follow native
  app logs and the exact build receipt.
- Flutter: inspect registered Android/desktop adapter and packaged native-library
  identity. Keep Android paused and use authorized Arch work for its platform.
- Optional server: inspect the Rust server/container revision, configured port,
  paths and logs.

Report the actual active fallback voice and explicit job preferences when Piper
fails. Keep Piper primary and use bounded recovery according to shared policy.
Do not start a benchmark, install models or clear user caches as an inferred fix.

Upload limits and HTTP error behavior belong to the selected adapter/server;
verify the current config before recommending legacy environment overrides.
For security findings, reproduce safely, inspect confinement/sanitization and
use [SECURITY.md](../../../SECURITY.md). Do not dismiss alerts or close issues
without the applicable authorization and evidence.

Simulator execution has no host guard since 2026-11-22; required SE1/iOS 15.2
acceptance stays pending. After a new host panic, report it and preserve the
evidence per the execution policy. Do not reboot a service/host or change
runtime/hardware to bypass a failure.
