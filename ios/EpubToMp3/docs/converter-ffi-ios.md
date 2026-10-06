# iOS converter-ffi artifact hook

The iOS bridge is `ConverterFFIAdapter` and is intentionally inert unless CI
supplies a native artifact. No dylib or XCFramework is checked into the repo.

CI may provide the Rust release artifact described in
`docs/converter-ffi-artifacts.md` (the `ios-device` and simulator slices) and
copy a merged `converter_ffi.dylib` into the app bundle under the resource name
`converter_ffi.dylib`. The bridge discovers that resource through
`Bundle.main`; a build with no artifact throws
`EmbeddedConverterError.artifactUnavailable` and does not use HTTP fallback.

The current seam stops at artifact discovery. It does not bind or invoke the C
ABI yet, so a supplied artifact reports `artifactInvalid` rather than claiming
runtime conversion. CI must add the actual C-symbol binding and architecture-
appropriate packaging before enabling conversion.
