# Native `converter-ffi` artifacts

`converter-ffi` is the stable C ABI used by native embedding layers. This
orchestration builds only the Rust library; it does not touch Flutter or native
UI projects.

## Target mapping and output paths

Run `mise run converter-ffi:targets` to print this table:

| Logical name | Rust target | Release artifact |
| --- | --- | --- |
| `android-arm64` | `aarch64-linux-android` | `target/aarch64-linux-android/release/libconverter_ffi.so` |
| `android-armv7` | `armv7-linux-androideabi` | `target/armv7-linux-androideabi/release/libconverter_ffi.so` |
| `android-x64` | `x86_64-linux-android` | `target/x86_64-linux-android/release/libconverter_ffi.so` |
| `android-x86` | `i686-linux-android` | `target/i686-linux-android/release/libconverter_ffi.so` |
| `ios-device` | `aarch64-apple-ios` | `target/aarch64-apple-ios/release/libconverter_ffi.dylib` |
| `ios-simulator-arm64` | `aarch64-apple-ios-sim` | `target/aarch64-apple-ios-sim/release/libconverter_ffi.dylib` |
| `ios-simulator-x64` | `x86_64-apple-ios` | `target/x86_64-apple-ios/release/libconverter_ffi.dylib` |

The build uses `cargo build --release --target <target> -p converter-ffi`.
Pass logical names as arguments to build a subset, for example:

```bash
mise run converter-ffi:build -- android-arm64 ios-device
```

With no names, all mappings are checked and built. The task requires `cargo`,
`rustup`, and every requested Rust target to already be installed. It never
runs `rustup target add`, downloads toolchains, configures Android NDK/linkers,
or installs Apple SDKs. Missing prerequisites fail before any build with the
manual remediation command.

`converter-ffi:validate` is host-only and checks target mapping plus exact
artifact naming without requiring mobile SDKs or targets. `--dry-run` checks
installed-target prerequisites and prints the cargo commands without building.
