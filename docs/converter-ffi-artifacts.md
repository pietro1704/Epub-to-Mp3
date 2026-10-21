# Native `converter-ffi` artifacts

`converter-ffi` is the native C ABI over shared Rust conversion. Artifact paths
identify expected outputs, not verified platform/runtime compatibility. Consult
[runtime navigation](agents/runtime-navigation.md) and the
[execution policy](agents/execution-policy.md) before building.

## Current task ownership

`mise.toml` owns task behavior. `converter-ffi:build` now builds the **host**
library with its ONNX Runtime dependency. It does not accept the old multi-target
subset recipe. Dedicated Apple tasks include `converter-ffi:ios-device`,
`converter-ffi:ios-simulator`, `converter-ffi:ios-device:verify` and
`converter-ffi:ios-packaging:test`. Android tasks include
`converter-ffi:android-install` and `android:runtime-audit`; inspect their
prerequisites and platform ownership before use. Android work remains paused.

The retained `scripts/build_converter_ffi.py` maps logical targets below.
`converter-ffi:targets` lists that map; `converter-ffi:validate` checks the host
mapping. Both currently invoke Python, whose local execution remains deferred
to CI by policy. The script's `--dry-run` checks installed-target prerequisites
and prints commands; it is not a build or artifact audit. Never invoke its direct
compiler path to bypass native guards.

| Logical name | Rust target | Expected release artifact |
| --- | --- | --- |
| `android-arm64` | `aarch64-linux-android` | `target/aarch64-linux-android/release/libconverter_ffi.so` |
| `android-armv7` | `armv7-linux-androideabi` | `target/armv7-linux-androideabi/release/libconverter_ffi.so` |
| `android-x64` | `x86_64-linux-android` | `target/x86_64-linux-android/release/libconverter_ffi.so` |
| `android-x86` | `i686-linux-android` | `target/i686-linux-android/release/libconverter_ffi.so` |
| `ios-device` | `aarch64-apple-ios` | `target/aarch64-apple-ios/release/libconverter_ffi.dylib` |
| `ios-simulator-arm64` | `aarch64-apple-ios-sim` | `target/aarch64-apple-ios-sim/release/libconverter_ffi.dylib` |
| `ios-simulator-x64` | `x86_64-apple-ios` | `target/x86_64-apple-ios/release/libconverter_ffi.dylib` |

Mapping does not establish that every target is built, supported by current
packaging or equipped with SDKs/linkers. Toolchain/target installation requires
explicit scope. Verify architecture, SDK platform, exported ABI, dependent runtime
and signing at packaging seams. Simulator compilation does not authorize its
execution; quarantine and pending SE1/iOS 15.5 acceptance remain in force.
